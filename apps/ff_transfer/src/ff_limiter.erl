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
-type limit_amount() :: dmsl_domain_thrift:'Amount'().
-type context() :: limproto_limiter_thrift:'LimitContext'().
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
    Context = gen_limit_context(Route, Withdrawal),
    LimitValues = get_batch_limit_values(Context, TurnoverLimits, make_operation_segments(Withdrawal, Route, Iter)),
    case lists:foldl(fun(LimitValue, Acc) -> check_limits_(LimitValue, Acc) end, {[], []}, LimitValues) of
        {Limits, ErrorList} when length(ErrorList) =:= 0 ->
            {ok, Limits};
        {_, ErrorList} ->
            {error, {overflow, ErrorList}}
    end.

make_operation_segments(Withdrawal, #{terminal_id := TerminalID, provider_id := ProviderID} = _Route, Iter) ->
    [
        genlib:to_binary(ProviderID),
        genlib:to_binary(TerminalID),
        ff_withdrawal:id(Withdrawal)
        | case Iter of
            1 -> [];
            N when N > 1 -> [genlib:to_binary(Iter)]
        end
    ].

get_batch_limit_values(_Context, [], _OperationIdSegments) ->
    [];
get_batch_limit_values(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, TurnoverLimitsMap} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    lists:map(
        fun(#limiter_Limit{id = LimitID} = Limit) ->
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
    ok = batch_hold_limits(Context, TurnoverLimits, make_operation_segments(Withdrawal, Route, Iter)).

batch_hold_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_hold_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    _ = hold_batch(LimitRequest, Context),
    ok.

-spec commit_withdrawal_limits([turnover_limit()], withdrawal(), route(), pos_integer()) -> ok.
commit_withdrawal_limits(TurnoverLimits, Withdrawal, Route, Iter) ->
    Context = gen_limit_context(Route, Withdrawal),
    OperationIdSegments = make_operation_segments(Withdrawal, Route, Iter),
    ok = batch_commit_limits(Context, TurnoverLimits, OperationIdSegments).

batch_commit_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_commit_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, TurnoverLimitsMap} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    ok = commit_batch(LimitRequest, Context),
    Attrs = mk_limit_log_attributes(Context),
    lists:foreach(
        fun(#limiter_Limit{id = LimitID, amount = LimitAmount}) ->
            #domain_TurnoverLimit{upper_boundary = UpperBoundary} = maps:get(LimitID, TurnoverLimitsMap),
            ok = logger:log(notice, "Limit change commited", [], #{
                limit => Attrs#{
                    config_id => LimitID,
                    boundary => UpperBoundary,
                    amount => LimitAmount
                }
            })
        end,
        get_batch(LimitRequest, Context)
    ).

-spec rollback_withdrawal_limits([turnover_limit()], withdrawal(), route(), pos_integer()) -> ok.
rollback_withdrawal_limits(TurnoverLimits, Withdrawal, Route, Iter) ->
    Context = gen_limit_context(Route, Withdrawal),
    OperationIdSegments = make_operation_segments(Withdrawal, Route, Iter),
    ok = batch_rollback_limits(Context, TurnoverLimits, OperationIdSegments).

batch_rollback_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_rollback_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    ok = rollback_batch(LimitRequest, Context).

-define(LIM(ID), #domain_LimitConfigRef{id = ID}).

prepare_limit_request(TurnoverLimits, IdSegments) ->
    {TurnoverLimitsIdList, LimitChanges} = lists:unzip(
        lists:map(
            fun(#domain_TurnoverLimit{ref = ?LIM(ID), domain_revision = DomainRevision} = TurnoverLimit) ->
                {{ID, TurnoverLimit}, #limiter_LimitChange{id = ID, version = DomainRevision}}
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

-spec construct_complex_id([binary()]) -> binary().
construct_complex_id(IDs) ->
    genlib_string:join($., IDs).

-spec marshal_withdrawal(withdrawal()) -> domain_withdrawal().
marshal_withdrawal(Withdrawal) ->
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = ff_withdrawal:params(Withdrawal),
    DomainRevision = ff_withdrawal:final_domain_revision(Withdrawal),
    PartyID = ff_withdrawal:party_id(Withdrawal),
    {ok, Wallet} = ff_party:get_wallet(
        WalletID,
        #domain_PartyConfigRef{id = PartyID},
        DomainRevision
    ),
    {AccountID, Currency} = ff_party:get_wallet_account(Wallet),
    WalletRealm = ff_party:get_wallet_realm(Wallet, DomainRevision),
    WalletAccount = ff_account:build(PartyID, WalletRealm, AccountID, Currency),

    {ok, DestinationMachine} = ff_destination_machine:get(DestinationID),
    Destination = ff_destination_machine:destination(DestinationMachine),
    DestinationAccount = ff_destination:account(Destination),

    Resource = ff_withdrawal:destination_resource(Withdrawal),
    MarshaledResource = ff_adapter_withdrawal_codec:marshal(resource, Resource),
    AuthData = ff_destination:auth_data(Destination),
    MarshaledAuthData = ff_adapter_withdrawal_codec:maybe_marshal(auth_data, AuthData),
    #wthd_domain_Withdrawal{
        created_at = ff_codec:marshal(timestamp_ms, ff_withdrawal:created_at(Withdrawal)),
        body = ff_dmsl_codec:marshal(cash, ff_withdrawal:body(Withdrawal)),
        destination = MarshaledResource,
        auth_data = MarshaledAuthData,
        %% TODO: change proto
        sender = #domain_PartyConfigRef{id = ff_account:party_id(WalletAccount)},
        receiver = #domain_PartyConfigRef{id = ff_account:party_id(DestinationAccount)}
    }.

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
