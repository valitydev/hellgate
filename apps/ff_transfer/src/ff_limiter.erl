-module(ff_limiter).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").

-type turnover_selector() :: dmsl_domain_thrift:'TurnoverLimitSelector'().
-type turnover_limit() :: dmsl_domain_thrift:'TurnoverLimit'().
-type turnover_limit_upper_boundary() :: dmsl_domain_thrift:'Amount'().
-type domain_withdrawal() :: dmsl_wthd_domain_thrift:'Withdrawal'().
-type withdrawal() :: ff_withdrawal:withdrawal_state().
-type route() :: ff_withdrawal_routing:route().

-type limit() :: limproto_limiter_thrift:'Limit'().
-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_version() :: limproto_limiter_thrift:'Version'().
-type limit_change() :: limproto_limiter_thrift:'LimitChange'().
-type limit_amount() :: dmsl_domain_thrift:'Amount'().
-type context() :: limproto_limiter_thrift:'LimitContext'().
-type clock() :: limproto_limiter_thrift:'Clock'().
-type request() :: limproto_limiter_thrift:'LimitRequest'().

-export([get_turnover_limits/1]).
-export([check_limits/4]).
-export([marshal_withdrawal/1]).

-export([hold_withdrawal_limits/4]).
-export([commit_withdrawal_limits/4]).
-export([rollback_withdrawal_limits/4]).

-spec get_turnover_limits(turnover_selector() | undefined) -> [turnover_limit()].
get_turnover_limits(undefined) ->
    [];
get_turnover_limits({value, Limits}) ->
    Limits;
get_turnover_limits(Ambiguous) ->
    error({misconfiguration, {'Could not reduce selector to a value', Ambiguous}}).

-spec check_limits([turnover_limit()], withdrawal(), route(), pos_integer()) ->
    {ok, [limit()]}
    | {error, {overflow, [{limit_id(), limit_amount(), turnover_limit_upper_boundary()}]}}.
check_limits(TurnoverLimits, Withdrawal, Route, Iter) ->
    Clock = get_latest_clock(),
    Context = gen_limit_context(Route, Withdrawal),
    LimitValues = collect_limit_values(
        Clock, Context, TurnoverLimits, make_operation_segments(Withdrawal, Route, Iter)
    ),
    case lists:foldl(fun(LimitValue, Acc) -> check_limits_(LimitValue, Acc) end, {[], []}, LimitValues) of
        {Limits, ErrorList} when length(ErrorList) =:= 0 ->
            {ok, Limits};
        {_, ErrorList} ->
            {error, {overflow, ErrorList}}
    end.

make_operation_segments(Withdrawal, _Route = #{terminal_id := TerminalID, provider_id := ProviderID}, Iter) ->
    [
        genlib:to_binary(ProviderID),
        genlib:to_binary(TerminalID),
        ff_withdrawal:id(Withdrawal)
        | case Iter of
            1 -> [];
            N when N > 1 -> [genlib:to_binary(Iter)]
        end
    ].

collect_limit_values(Clock, Context, TurnoverLimits, OperationIdSegments) ->
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    get_legacy_limit_values(Clock, Context, LegacyTurnoverLimits) ++
        get_batch_limit_values(Context, BatchTurnoverLimits, OperationIdSegments).

get_legacy_limit_values(Clock, Context, TurnoverLimits) ->
    lists:foldl(
        fun(TurnoverLimit, Acc) ->
            #domain_TurnoverLimit{id = LimitID, domain_revision = DomainRevision, upper_boundary = UpperBoundary} =
                TurnoverLimit,
            Limit = get(LimitID, DomainRevision, Clock, Context),
            LimitValue = #{
                id => LimitID,
                boundary => UpperBoundary,
                limit => Limit
            },
            [LimitValue | Acc]
        end,
        [],
        TurnoverLimits
    ).

get_batch_limit_values(_Context, [], _OperationIdSegments) ->
    [];
get_batch_limit_values(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, TurnoverLimitsMap} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    lists:map(
        fun(Limit = #limiter_Limit{id = LimitID}) ->
            #domain_TurnoverLimit{upper_boundary = UpperBoundary} = maps:get(LimitID, TurnoverLimitsMap),
            #{
                id => LimitID,
                boundary => UpperBoundary,
                limit => Limit
            }
        end,
        get_batch(LimitRequest, Context)
    ).

check_limits_(#{id := LimitID, boundary := UpperBoundary, limit := Limit}, {Limits, Errors}) ->
    #limiter_Limit{amount = LimitAmount} = Limit,
    case LimitAmount =< UpperBoundary of
        true ->
            {[Limit | Limits], Errors};
        false ->
            {Limits, [{LimitID, LimitAmount, UpperBoundary} | Errors]}
    end.

-spec hold_withdrawal_limits([turnover_limit()], withdrawal(), route(), pos_integer()) -> ok | no_return().
hold_withdrawal_limits(TurnoverLimits, Withdrawal, Route, Iter) ->
    Context = gen_limit_context(Route, Withdrawal),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_hold_withdrawal_limits(Context, LegacyTurnoverLimits, Withdrawal, Route, Iter),
    ok = batch_hold_limits(Context, BatchTurnoverLimits, make_operation_segments(Withdrawal, Route, Iter)).

legacy_hold_withdrawal_limits(Context, TurnoverLimits, Withdrawal, Route, Iter) ->
    LimitChanges = gen_limit_changes(TurnoverLimits, Route, Withdrawal, Iter),
    hold(LimitChanges, get_latest_clock(), Context).

batch_hold_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_hold_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    _ = hold_batch(LimitRequest, Context),
    ok.

-spec commit_withdrawal_limits([turnover_limit()], withdrawal(), route(), pos_integer()) -> ok.
commit_withdrawal_limits(TurnoverLimits, Withdrawal, Route, Iter) ->
    Context = gen_limit_context(Route, Withdrawal),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    Clock = get_latest_clock(),
    ok = legacy_commit_withdrawal_limits(Context, LegacyTurnoverLimits, Withdrawal, Route, Iter),
    OperationIdSegments = make_operation_segments(Withdrawal, Route, Iter),
    ok = batch_commit_limits(Context, BatchTurnoverLimits, OperationIdSegments),
    ok = log_limit_changes(TurnoverLimits, Clock, Context, Withdrawal, Route, Iter).

legacy_commit_withdrawal_limits(Context, TurnoverLimits, Withdrawal, Route, Iter) ->
    LimitChanges = gen_limit_changes(TurnoverLimits, Route, Withdrawal, Iter),
    Clock = get_latest_clock(),
    ok = commit(LimitChanges, Clock, Context).

batch_commit_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_commit_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    _ = commit_batch(LimitRequest, Context),
    ok.

-spec rollback_withdrawal_limits([turnover_limit()], withdrawal(), route(), pos_integer()) -> ok.
rollback_withdrawal_limits(TurnoverLimits, Withdrawal, Route, Iter) ->
    Context = gen_limit_context(Route, Withdrawal),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_rollback_withdrawal_limits(Context, LegacyTurnoverLimits, Withdrawal, Route, Iter),
    OperationIdSegments = make_operation_segments(Withdrawal, Route, Iter),
    ok = batch_rollback_limits(Context, BatchTurnoverLimits, OperationIdSegments).

legacy_rollback_withdrawal_limits(Context, TurnoverLimits, Withdrawal, Route, Iter) ->
    LimitChanges = gen_limit_changes(TurnoverLimits, Route, Withdrawal, Iter),
    rollback(LimitChanges, get_latest_clock(), Context).

batch_rollback_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_rollback_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    rollback_batch(LimitRequest, Context).

split_turnover_limits_by_available_limiter_api(TurnoverLimits) ->
    lists:partition(fun(#domain_TurnoverLimit{domain_revision = V}) -> V =:= undefined end, TurnoverLimits).

prepare_limit_request(TurnoverLimits, IdSegments) ->
    {TurnoverLimitsIdList, LimitChanges} = lists:unzip(
        lists:map(
            fun(TurnoverLimit = #domain_TurnoverLimit{id = Id, domain_revision = DomainRevision}) ->
                {{Id, TurnoverLimit}, #limiter_LimitChange{id = Id, version = DomainRevision}}
            end,
            TurnoverLimits
        )
    ),
    OperationId = make_operation_id(IdSegments),
    LimitRequest = #limiter_LimitRequest{operation_id = OperationId, limit_changes = LimitChanges},
    TurnoverLimitsMap = maps:from_list(TurnoverLimitsIdList),
    {LimitRequest, TurnoverLimitsMap}.

make_operation_id(IdSegments) ->
    construct_complex_id([<<"limiter">>, <<"batch-request">>] ++ IdSegments).

-spec hold([limit_change()], clock(), context()) -> ok | no_return().
hold(LimitChanges, Clock, Context) ->
    lists:foreach(
        fun(LimitChange) ->
            call_hold(LimitChange, Clock, Context)
        end,
        LimitChanges
    ).

-spec commit([limit_change()], clock(), context()) -> ok.
commit(LimitChanges, Clock, Context) ->
    lists:foreach(
        fun(LimitChange) ->
            call_commit(LimitChange, Clock, Context)
        end,
        LimitChanges
    ).

-spec rollback([limit_change()], clock(), context()) -> ok.
rollback(LimitChanges, Clock, Context) ->
    lists:foreach(
        fun(LimitChange) ->
            call_rollback(LimitChange, Clock, Context)
        end,
        LimitChanges
    ).

gen_limit_context(#{provider_id := ProviderID, terminal_id := TerminalID}, Withdrawal) ->
    #{wallet_id := WalletID} = ff_withdrawal:params(Withdrawal),
    MarshaledWithdrawal = marshal_withdrawal(Withdrawal),
    #limiter_LimitContext{
        withdrawal_processing = #context_withdrawal_Context{
            op = {withdrawal, #context_withdrawal_OperationWithdrawal{}},
            withdrawal = #context_withdrawal_Withdrawal{
                withdrawal = MarshaledWithdrawal,
                route = #base_Route{
                    provider = #domain_ProviderRef{id = ProviderID},
                    terminal = #domain_TerminalRef{id = TerminalID}
                },
                wallet_id = WalletID
            }
        }
    }.

gen_limit_changes(TurnoverLimits, Route, Withdrawal, Iter) ->
    [
        #limiter_LimitChange{
            id = ID,
            change_id = construct_limit_change_id(ID, Route, Withdrawal, Iter),
            version = Version
        }
     || #domain_TurnoverLimit{id = ID, domain_revision = Version} <- TurnoverLimits
    ].

construct_limit_change_id(LimitID, #{terminal_id := TerminalID, provider_id := ProviderID}, Withdrawal, Iter) ->
    ComplexID = construct_complex_id([
        LimitID,
        genlib:to_binary(ProviderID),
        genlib:to_binary(TerminalID),
        ff_withdrawal:id(Withdrawal)
        | case Iter of
            1 -> [];
            N when N > 1 -> [genlib:to_binary(Iter)]
        end
    ]),
    genlib_string:join($., [<<"limiter">>, ComplexID]).

get_latest_clock() ->
    {latest, #limiter_LatestClock{}}.

-spec construct_complex_id([binary()]) -> binary().
construct_complex_id(IDs) ->
    genlib_string:join($., IDs).

-spec marshal_withdrawal(withdrawal()) -> domain_withdrawal().
marshal_withdrawal(Withdrawal) ->
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = ff_withdrawal:params(Withdrawal),
    {ok, WalletMachine} = ff_wallet_machine:get(WalletID),
    Wallet = ff_wallet_machine:wallet(WalletMachine),
    WalletAccount = ff_wallet:account(Wallet),

    {ok, DestinationMachine} = ff_destination_machine:get(DestinationID),
    Destination = ff_destination_machine:destination(DestinationMachine),
    DestinationAccount = ff_destination:account(Destination),

    {ok, SenderSt} = ff_identity_machine:get(ff_account:identity(WalletAccount)),
    {ok, ReceiverSt} = ff_identity_machine:get(ff_account:identity(DestinationAccount)),
    SenderIdentity = ff_identity_machine:identity(SenderSt),
    ReceiverIdentity = ff_identity_machine:identity(ReceiverSt),

    Resource = ff_withdrawal:destination_resource(Withdrawal),
    MarshaledResource = ff_adapter_withdrawal_codec:marshal(resource, Resource),
    #wthd_domain_Withdrawal{
        created_at = ff_codec:marshal(timestamp_ms, ff_withdrawal:created_at(Withdrawal)),
        body = ff_dmsl_codec:marshal(cash, ff_withdrawal:body(Withdrawal)),
        destination = MarshaledResource,
        sender = ff_adapter_withdrawal_codec:marshal(identity, #{
            id => ff_identity:id(SenderIdentity),
            owner_id => ff_identity:party(SenderIdentity)
        }),
        receiver = ff_adapter_withdrawal_codec:marshal(identity, #{
            id => ff_identity:id(ReceiverIdentity),
            owner_id => ff_identity:party(SenderIdentity)
        })
    }.

-spec get(limit_id(), limit_version(), clock(), context()) -> limit() | no_return().
get(LimitID, Version, Clock, Context) ->
    Args = {LimitID, Version, Clock, Context},
    case call('GetVersioned', Args) of
        {ok, Limit} ->
            Limit;
        {exception, #limiter_LimitNotFound{}} ->
            error({not_found, LimitID});
        {exception, #base_InvalidRequest{errors = Errors}} ->
            error({invalid_request, Errors})
    end.

-spec call_hold(limit_change(), clock(), context()) -> clock() | no_return().
call_hold(LimitChange, Clock, Context) ->
    Args = {LimitChange, Clock, Context},
    case call('Hold', Args) of
        {ok, ClockUpdated} ->
            ClockUpdated;
        {exception, Exception} ->
            error(Exception)
    end.

-spec call_commit(limit_change(), clock(), context()) -> clock().
call_commit(LimitChange, Clock, Context) ->
    Args = {LimitChange, Clock, Context},
    {ok, ClockUpdated} = call('Commit', Args),
    ClockUpdated.

-spec call_rollback(limit_change(), clock(), context()) -> clock().
call_rollback(LimitChange, Clock, Context) ->
    Args = {LimitChange, Clock, Context},
    case call('Rollback', Args) of
        {ok, ClockUpdated} -> ClockUpdated;
        %% Always ignore business exceptions on rollback and compatibility return latest clock
        {exception, #limiter_InvalidOperationCurrency{}} -> {latest, #limiter_LatestClock{}};
        {exception, #limiter_OperationContextNotSupported{}} -> {latest, #limiter_LatestClock{}};
        {exception, #limiter_PaymentToolNotSupported{}} -> {latest, #limiter_LatestClock{}}
    end.

-spec get_batch(request(), context()) -> [limit()] | no_return().
get_batch(Request, Context) ->
    {ok, Limits} = call_w_request('GetBatch', Request, Context),
    Limits.

-spec hold_batch(request(), context()) -> [limit()] | no_return().
hold_batch(Request, Context) ->
    {ok, Limits} = call_w_request('HoldBatch', Request, Context),
    Limits.

-spec commit_batch(request(), context()) -> ok | no_return().
commit_batch(Request, Context) ->
    {ok, ok} = call_w_request('CommitBatch', Request, Context),
    ok.

-spec rollback_batch(request(), context()) -> ok | no_return().
rollback_batch(Request, Context) ->
    {ok, ok} = call_w_request('RollbackBatch', Request, Context),
    ok.

call(Func, Args) ->
    Service = {limproto_limiter_thrift, 'Limiter'},
    Request = {Service, Func, Args},
    ff_woody_client:call(limiter, Request).

log_limit_changes(TurnoverLimits, Clock, Context, Withdrawal, Route, Iter) ->
    LimitValues = collect_limit_values(
        Clock, Context, TurnoverLimits, make_operation_segments(Withdrawal, Route, Iter)
    ),
    Attrs = mk_limit_log_attributes(Context),
    lists:foreach(
        fun(#{id := ID, boundary := UpperBoundary, limit := #limiter_Limit{amount = LimitAmount}}) ->
            ok = logger:log(notice, "Limit change commited", [], #{
                limit => Attrs#{config_id => ID, boundary => UpperBoundary, amount => LimitAmount}
            })
        end,
        LimitValues
    ).

mk_limit_log_attributes(#limiter_LimitContext{
    withdrawal_processing = #context_withdrawal_Context{withdrawal = Wthd}
}) ->
    #context_withdrawal_Withdrawal{
        withdrawal = #wthd_domain_Withdrawal{
            body = #domain_Cash{amount = Amount, currency = Currency}
        },
        wallet_id = WalletID,
        route = #base_Route{provider = Provider, terminal = Terminal}
    } = Wthd,
    #{
        config_id => undefined,
        %% Limit boundary amount
        boundary => undefined,
        %% Current amount with accounted change
        amount => undefined,
        route => #{
            provider_id => Provider#domain_ProviderRef.id,
            terminal_id => Terminal#domain_TerminalRef.id
        },
        wallet_id => WalletID,
        change => #{
            amount => Amount,
            currency => Currency#domain_CurrencyRef.symbolic_code
        }
    }.

call_w_request(Function, Request, Context) ->
    case call(Function, {Request, Context}) of
        {exception, #limiter_LimitNotFound{}} ->
            error(not_found);
        {exception, #base_InvalidRequest{errors = Errors}} ->
            error({invalid_request, Errors});
        {exception, Exception} ->
            %% NOTE Uniform handling of more specific exceptions:
            %% LimitChangeNotFound
            %% InvalidOperationCurrency
            %% OperationContextNotSupported
            %% PaymentToolNotSupported
            error(Exception);
        {ok, _} = Result ->
            Result
    end.
