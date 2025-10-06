-module(hg_limiter).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").

-type turnover_terms_container() :: dmsl_domain_thrift:'PaymentsProvisionTerms'() | dmsl_domain_thrift:'ShopConfig'().
-type turnover_limit() :: dmsl_domain_thrift:'TurnoverLimit'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type route() :: hg_route:payment_route().
-type refund() :: hg_invoice_payment:domain_refund().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type handling_flag() :: ignore_business_error | ignore_not_found.
-type turnover_limit_value() :: dmsl_payproc_thrift:'TurnoverLimitValue'().
-type party_config_ref() :: dmsl_domain_thrift:'PartyConfigRef'().
-type shop_config_ref() :: dmsl_domain_thrift:'ShopConfigRef'().

-type change_queue() :: [hg_limiter_client:limit_change()].

-export_type([turnover_limit_value/0]).

-export([get_turnover_limits/1]).
-export([check_limits/5]).
-export([check_shop_limits/5]).
-export([hold_payment_limits/5]).
-export([hold_shop_limits/5]).
-export([hold_refund_limits/5]).
-export([commit_payment_limits/6]).
-export([commit_shop_limits/5]).
-export([commit_refund_limits/5]).
-export([rollback_payment_limits/6]).
-export([rollback_shop_limits/6]).
-export([rollback_refund_limits/5]).
-export([get_limit_values/5]).

-define(route(ProviderRef, TerminalRef), #domain_PaymentRoute{
    provider = ProviderRef,
    terminal = TerminalRef
}).

-define(party(PartyID), #domain_Party{
    id = PartyID
}).

-define(shop(ShopID), #domain_Shop{
    id = ShopID
}).

%% Very specific errors to crutch around
-define(POSTING_PLAN_NOT_FOUND(ID), #base_InvalidRequest{errors = [<<"Posting plan not found: ", ID/binary>>]}).
-define(OPERATION_NOT_FOUND, {invalid_request, [<<"OperationNotFound">>]}).

-spec get_turnover_limits(turnover_terms_container()) -> [turnover_limit()].

get_turnover_limits(#domain_ShopConfig{turnover_limits = undefined}) ->
    [];
get_turnover_limits(#domain_ShopConfig{turnover_limits = Limits}) ->
    ok = assert_turnover_limits_exist_in_domain(Limits),
    ordsets:to_list(Limits);
get_turnover_limits(#domain_PaymentsProvisionTerms{turnover_limits = undefined}) ->
    [];
get_turnover_limits(#domain_PaymentsProvisionTerms{turnover_limits = {value, Limits}}) ->
    ok = assert_turnover_limits_exist_in_domain(Limits),
    Limits;
get_turnover_limits(#domain_PaymentsProvisionTerms{turnover_limits = Ambiguous}) ->
    error({misconfiguration, {'Could not reduce selector to a value', Ambiguous}}).

assert_turnover_limits_exist_in_domain(Limits) ->
    try
        _ = [
            hg_domain:get(Ver, {limit_config, #domain_LimitConfigRef{id = ID}})
         || #domain_TurnoverLimit{id = ID, domain_revision = Ver} <- Limits,
            Ver =/= undefined
        ],
        ok
    catch
        error:{object_not_found, {Revision, {limit_config, #domain_LimitConfigRef{id = LimitID}}}} ->
            error({misconfiguration, {'Limit config not found', {Revision, LimitID}}})
    end.

-spec get_limit_values([turnover_limit()], invoice(), payment(), route(), pos_integer()) -> [turnover_limit_value()].
get_limit_values(TurnoverLimits, Invoice, Payment, Route, Iter) ->
    Context = gen_limit_context(Invoice, Payment, Route),
    get_limit_values(Context, TurnoverLimits, make_route_operation_segments(Invoice, Payment, Route, Iter)).

make_route_operation_segments(Invoice, Payment, ?route(ProviderRef, TerminalRef), Iter) ->
    [
        genlib:to_binary(get_provider_id(ProviderRef)),
        genlib:to_binary(get_terminal_id(TerminalRef)),
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        integer_to_binary(Iter)
    ].

get_limit_values(Context, TurnoverLimits, OperationIdSegments) ->
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    get_legacy_limit_values(Context, LegacyTurnoverLimits) ++
        get_batch_limit_values(Context, BatchTurnoverLimits, OperationIdSegments).

get_legacy_limit_values(Context, TurnoverLimits) ->
    lists:foldl(
        fun(TurnoverLimit, Acc) ->
            #domain_TurnoverLimit{id = LimitID, domain_revision = Version} = TurnoverLimit,
            Clock = get_latest_clock(),
            Limit = hg_limiter_client:get(LimitID, Version, Clock, Context),
            #limiter_Limit{amount = LimiterAmount} = Limit,
            [#payproc_TurnoverLimitValue{limit = TurnoverLimit, value = LimiterAmount} | Acc]
        end,
        [],
        TurnoverLimits
    ).

get_batch_limit_values(_Context, [], _OperationIdSegments) ->
    [];
get_batch_limit_values(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, TurnoverLimitsMap} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    lists:map(
        fun(#limiter_Limit{id = Id, amount = Amount}) ->
            #payproc_TurnoverLimitValue{limit = maps:get(Id, TurnoverLimitsMap), value = Amount}
        end,
        hg_limiter_client:get_batch(LimitRequest, Context)
    ).

-spec check_limits([turnover_limit()], invoice(), payment(), route(), pos_integer()) ->
    {ok, [turnover_limit_value()]}
    | {error, {limit_overflow, [binary()], [turnover_limit_value()]}}.
check_limits(TurnoverLimits, Invoice, Payment, Route, Iter) ->
    Context = gen_limit_context(Invoice, Payment, Route),
    Limits = get_limit_values(Context, TurnoverLimits, make_route_operation_segments(Invoice, Payment, Route, Iter)),
    try
        ok = check_limits_(Limits, Context),
        {ok, Limits}
    catch
        throw:limit_overflow ->
            IDs = [T#domain_TurnoverLimit.id || T <- TurnoverLimits],
            {error, {limit_overflow, IDs, Limits}}
    end.

-spec check_shop_limits([turnover_limit()], party_config_ref(), shop_config_ref(), invoice(), payment()) ->
    ok
    | {error, {limit_overflow, [binary()]}}.
check_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    Context = gen_limit_shop_context(Invoice, Payment),
    Limits = get_limit_values(
        Context, TurnoverLimits, make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment)
    ),
    try
        check_limits_(Limits, Context)
    catch
        throw:limit_overflow ->
            IDs = [T#domain_TurnoverLimit.id || T <- TurnoverLimits],
            {error, {limit_overflow, IDs}}
    end.

make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    [
        PartyConfigRef,
        ShopConfigRef,
        get_invoice_id(Invoice),
        get_payment_id(Payment)
    ].

check_limits_([], _) ->
    ok;
check_limits_([TurnoverLimitValue | TLVs], Context) ->
    #payproc_TurnoverLimitValue{
        limit = #domain_TurnoverLimit{
            id = LimitID,
            upper_boundary = UpperBoundary
        },
        value = LimiterAmount
    } = TurnoverLimitValue,
    case LimiterAmount =< UpperBoundary of
        true ->
            check_limits_(TLVs, Context);
        false ->
            logger:notice("Limit with id ~p overflowed, amount ~p upper boundary ~p", [
                LimitID,
                LimiterAmount,
                UpperBoundary
            ]),
            throw(limit_overflow)
    end.

-spec hold_payment_limits([turnover_limit()], invoice(), payment(), route(), pos_integer()) -> ok.
hold_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter) ->
    Context = gen_limit_context(Invoice, Payment, Route),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_hold_payment_limits(Context, LegacyTurnoverLimits, Invoice, Payment, Route, Iter),
    ok = batch_hold_limits(Context, BatchTurnoverLimits, make_route_operation_segments(Invoice, Payment, Route, Iter)).

legacy_hold_payment_limits(Context, TurnoverLimits, Invoice, Payment, Route, Iter) ->
    ChangeIDs = [construct_payment_change_id(Route, Iter, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    hold(LimitChanges, get_latest_clock(), Context).

batch_hold_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_hold_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    _ = hg_limiter_client:hold_batch(LimitRequest, Context),
    ok.

-spec hold_shop_limits([turnover_limit()], party_config_ref(), shop_config_ref(), invoice(), payment()) -> ok.
hold_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    Context = gen_limit_shop_context(Invoice, Payment),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_hold_shop_limits(Context, LegacyTurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment),
    ok = batch_hold_limits(
        Context, BatchTurnoverLimits, make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment)
    ).

legacy_hold_shop_limits(Context, TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    ChangeIDs = [construct_shop_change_id(PartyConfigRef, ShopConfigRef, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    hold(LimitChanges, get_latest_clock(), Context).

-spec hold_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
hold_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_hold_refund_limits(Context, LegacyTurnoverLimits, Invoice, Payment, Refund),
    ok = batch_hold_limits(Context, BatchTurnoverLimits, make_refund_operation_segments(Invoice, Payment, Refund)).

make_refund_operation_segments(Invoice, Payment, Refund) ->
    [
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        {refund_session, get_refund_id(Refund)}
    ].

legacy_hold_refund_limits(Context, TurnoverLimits, Invoice, Payment, Refund) ->
    ChangeIDs = [construct_refund_change_id(Invoice, Payment, Refund)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    hold(LimitChanges, get_latest_clock(), Context).

-spec commit_payment_limits([turnover_limit()], invoice(), payment(), route(), pos_integer(), cash() | undefined) -> ok.
commit_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, CapturedCash) ->
    Context = gen_limit_context(Invoice, Payment, Route, CapturedCash),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    Clock = get_latest_clock(),
    ok = legacy_commit_payment_limits(Clock, Context, LegacyTurnoverLimits, Invoice, Payment, Route, Iter),
    OperationIdSegments = make_route_operation_segments(Invoice, Payment, Route, Iter),
    ok = batch_commit_limits(Context, BatchTurnoverLimits, OperationIdSegments),
    ok = log_limit_changes(TurnoverLimits, Clock, Context).

batch_commit_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_commit_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    hg_limiter_client:commit_batch(LimitRequest, Context).

legacy_commit_payment_limits(Clock, Context, TurnoverLimits, Invoice, Payment, Route, Iter) ->
    ChangeIDs = [
        construct_payment_change_id(Route, Iter, Invoice, Payment),
        construct_payment_change_id(Route, Iter, Invoice, Payment, legacy)
    ],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    commit(LimitChanges, Clock, Context).

-spec commit_shop_limits([turnover_limit()], party_config_ref(), shop_config_ref(), invoice(), payment()) -> ok.
commit_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    Context = gen_limit_shop_context(Invoice, Payment),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    Clock = get_latest_clock(),
    ok = legacy_commit_shop_limits(
        Clock, Context, LegacyTurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment
    ),
    OperationIdSegments = make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment),
    ok = batch_commit_limits(Context, BatchTurnoverLimits, OperationIdSegments),
    ok = log_limit_changes(TurnoverLimits, Clock, Context).

legacy_commit_shop_limits(Clock, Context, TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    ChangeIDs = [construct_shop_change_id(PartyConfigRef, ShopConfigRef, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    ok = commit(LimitChanges, Clock, Context).

-spec commit_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
commit_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    Clock = get_latest_clock(),
    ok = legacy_commit_refund_limits(Clock, Context, LegacyTurnoverLimits, Invoice, Payment, Refund),
    OperationIdSegments = make_refund_operation_segments(Invoice, Payment, Refund),
    ok = batch_commit_limits(Context, BatchTurnoverLimits, OperationIdSegments),
    ok = log_limit_changes(TurnoverLimits, Clock, Context).

legacy_commit_refund_limits(Clock, Context, TurnoverLimits, Invoice, Payment, Refund) ->
    ChangeIDs = [construct_refund_change_id(Invoice, Payment, Refund)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    commit(LimitChanges, Clock, Context).

%% @doc This function supports flags that can change reaction behaviour to
%%      limiter response:
%%
%%      - `ignore_business_error` -- prevents error raise upon misconfiguration
%%      failures in limiter config
%%
%%      - `ignore_not_found` -- does not raise error if limiter won't be able to
%%      find according posting plan in accountant service
-spec rollback_payment_limits([turnover_limit()], invoice(), payment(), route(), pos_integer(), [handling_flag()]) ->
    ok.
rollback_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, Flags) ->
    Context = gen_limit_context(Invoice, Payment, Route),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_rollback_payment_limits(Context, LegacyTurnoverLimits, Invoice, Payment, Route, Iter, Flags),
    OperationIdSegments = make_route_operation_segments(Invoice, Payment, Route, Iter),
    ok = batch_rollback_limits(Context, BatchTurnoverLimits, OperationIdSegments, Flags).

batch_rollback_limits(_Context, [], _OperationIdSegments, _Flags) ->
    ok;
batch_rollback_limits(Context, TurnoverLimits, OperationIdSegments, Flags) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    IgnoreError = lists:member(ignore_not_found, Flags) orelse lists:member(ignore_business_error, Flags),
    try
        ok = hg_limiter_client:rollback_batch(LimitRequest, Context)
    catch
        error:(?OPERATION_NOT_FOUND) when IgnoreError =:= true ->
            ok
    end.

legacy_rollback_payment_limits(Context, TurnoverLimits, Invoice, Payment, Route, Iter, Flags) ->
    ChangeIDs = [
        construct_payment_change_id(Route, Iter, Invoice, Payment),
        construct_payment_change_id(Route, Iter, Invoice, Payment, legacy)
    ],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    rollback(LimitChanges, get_latest_clock(), Context, Flags).

-spec rollback_shop_limits(
    [turnover_limit()],
    party_config_ref(),
    shop_config_ref(),
    invoice(),
    payment(),
    [handling_flag()]
) -> ok.
rollback_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment, Flags) ->
    Context = gen_limit_shop_context(Invoice, Payment),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_rollback_shop_limits(
        Context, LegacyTurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment, Flags
    ),
    OperationIdSegments = make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment),
    ok = batch_rollback_limits(Context, BatchTurnoverLimits, OperationIdSegments, Flags).

legacy_rollback_shop_limits(Context, TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment, Flags) ->
    ChangeIDs = [construct_shop_change_id(PartyConfigRef, ShopConfigRef, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    rollback(LimitChanges, get_latest_clock(), Context, Flags).

-spec rollback_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
rollback_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    {LegacyTurnoverLimits, BatchTurnoverLimits} = split_turnover_limits_by_available_limiter_api(TurnoverLimits),
    ok = legacy_rollback_refund_limits(Context, LegacyTurnoverLimits, Invoice, Payment, Refund),
    OperationIdSegments = make_refund_operation_segments(Invoice, Payment, Refund),
    ok = batch_rollback_limits(Context, BatchTurnoverLimits, OperationIdSegments, []).

legacy_rollback_refund_limits(Context, TurnoverLimits, Invoice, Payment, Refund) ->
    ChangeIDs = [construct_refund_change_id(Invoice, Payment, Refund)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    rollback(LimitChanges, get_latest_clock(), Context, []).

-spec hold([change_queue()], hg_limiter_client:clock(), hg_limiter_client:context()) -> ok.
hold(LimitChanges, Clock, Context) ->
    process_changes(LimitChanges, fun hg_limiter_client:hold/3, Clock, Context, []).

-spec commit([change_queue()], hg_limiter_client:clock(), hg_limiter_client:context()) -> ok.
commit(LimitChanges, Clock, Context) ->
    process_changes(LimitChanges, fun hg_limiter_client:commit/3, Clock, Context, []).

-spec rollback([change_queue()], hg_limiter_client:clock(), hg_limiter_client:context(), [handling_flag()]) -> ok.
rollback(LimitChanges, Clock, Context, Flags) ->
    process_changes(LimitChanges, fun hg_limiter_client:rollback/3, Clock, Context, Flags).

process_changes(LimitChangesQueues, WithFun, Clock, Context, Flags) ->
    lists:foreach(
        fun(LimitChangesQueue) ->
            process_changes_try_wrap(LimitChangesQueue, WithFun, Clock, Context, Flags)
        end,
        LimitChangesQueues
    ).

process_changes_try_wrap([LimitChange], WithFun, Clock, Context, Flags) ->
    IgnoreNotFound = lists:member(ignore_not_found, Flags),
    #limiter_LimitChange{change_id = ChangeID} = LimitChange,
    try
        WithFun(LimitChange, Clock, Context)
    catch
        error:(?POSTING_PLAN_NOT_FOUND(ChangeID)) when IgnoreNotFound =:= true ->
            %% See `limproto_limiter_thrift:'Clock'/0`
            {latest, #limiter_LatestClock{}}
    end;
process_changes_try_wrap([LimitChange | OtherLimitChanges], WithFun, Clock, Context, Flags) ->
    IgnoreBusinessError = lists:member(ignore_business_error, Flags),
    #limiter_LimitChange{change_id = ChangeID} = LimitChange,
    try
        WithFun(LimitChange, Clock, Context)
    catch
        error:(?POSTING_PLAN_NOT_FOUND(ChangeID)) ->
            process_changes_try_wrap(OtherLimitChanges, WithFun, Clock, Context, Flags);
        Class:Reason:Stacktrace ->
            handle_caught_exception(Class, Reason, Stacktrace, IgnoreBusinessError)
    end.

handle_caught_exception(error, #limiter_LimitNotFound{}, _Stacktrace, true) -> ok;
handle_caught_exception(error, #limiter_InvalidOperationCurrency{}, _Stacktrace, true) -> ok;
handle_caught_exception(error, #limiter_OperationContextNotSupported{}, _Stacktrace, true) -> ok;
handle_caught_exception(error, #limiter_PaymentToolNotSupported{}, _Stacktrace, true) -> ok;
handle_caught_exception(Class, Reason, Stacktrace, _IgnoreBusinessError) -> erlang:raise(Class, Reason, Stacktrace).

gen_limit_context(Invoice, Payment, Route) ->
    gen_limit_context(Invoice, Payment, Route, undefined).

gen_limit_context(Invoice, Payment, Route, CapturedCash) ->
    PaymentCtx = #context_payproc_InvoicePayment{
        payment = Payment#domain_InvoicePayment{
            status = {captured, #domain_InvoicePaymentCaptured{cost = CapturedCash}}
        },
        route = convert_to_limit_route(Route)
    },
    #limiter_LimitContext{
        payment_processing = #context_payproc_Context{
            op = {invoice_payment, #context_payproc_OperationInvoicePayment{}},
            invoice = #context_payproc_Invoice{
                invoice = Invoice,
                payment = PaymentCtx
            }
        }
    }.

gen_limit_shop_context(Invoice, Payment) ->
    #limiter_LimitContext{
        payment_processing = #context_payproc_Context{
            op = {invoice_payment, #context_payproc_OperationInvoicePayment{}},
            invoice = #context_payproc_Invoice{
                invoice = Invoice,
                payment = #context_payproc_InvoicePayment{
                    payment = Payment
                }
            }
        }
    }.

gen_limit_refund_context(Invoice, Payment, Refund, Route) ->
    PaymentCtx = #context_payproc_InvoicePayment{
        payment = Payment,
        refund = Refund,
        route = convert_to_limit_route(Route)
    },
    #limiter_LimitContext{
        payment_processing = #context_payproc_Context{
            op = {invoice_payment_refund, #context_payproc_OperationInvoicePaymentRefund{}},
            invoice = #context_payproc_Invoice{
                invoice = Invoice,
                payment = PaymentCtx
            }
        }
    }.

-spec gen_limit_changes([turnover_limit()], [binary()]) -> [change_queue()].
gen_limit_changes(Limits, ChangeIDs) ->
    %% It produces lists like
    %%  [
    %%      [#limiter_LimitChange{...}, #limiter_LimitChange{...}],
    %%      [#limiter_LimitChange{...}],
    %%      ...
    %% ]
    [[gen_limit_change(Limit, ChangeID) || ChangeID <- ChangeIDs] || Limit <- Limits].

gen_limit_change(#domain_TurnoverLimit{id = ID, domain_revision = Version}, ChangeID) ->
    #limiter_LimitChange{
        id = ID,
        change_id = hg_utils:construct_complex_id([<<"limiter">>, ID, ChangeID]),
        version = Version
    }.

construct_payment_change_id(Route, Iter, Invoice, Payment) ->
    construct_payment_change_id(Route, Iter, Invoice, Payment, normal).

construct_payment_change_id(?route(ProviderRef, TerminalRef), _Iter, Invoice, Payment, legacy) ->
    hg_utils:construct_complex_id([
        genlib:to_binary(get_provider_id(ProviderRef)),
        genlib:to_binary(get_terminal_id(TerminalRef)),
        get_invoice_id(Invoice),
        get_payment_id(Payment)
    ]);
construct_payment_change_id(?route(ProviderRef, TerminalRef), Iter, Invoice, Payment, normal) ->
    hg_utils:construct_complex_id([
        genlib:to_binary(get_provider_id(ProviderRef)),
        genlib:to_binary(get_terminal_id(TerminalRef)),
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        integer_to_binary(Iter)
    ]).

construct_shop_change_id(PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    hg_utils:construct_complex_id([
        PartyConfigRef,
        ShopConfigRef,
        get_invoice_id(Invoice),
        get_payment_id(Payment)
    ]).

construct_refund_change_id(Invoice, Payment, Refund) ->
    hg_utils:construct_complex_id([
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        {refund_session, get_refund_id(Refund)}
    ]).

get_provider_id(#domain_ProviderRef{id = ID}) ->
    ID.

get_terminal_id(#domain_TerminalRef{id = ID}) ->
    ID.

get_invoice_id(#domain_Invoice{id = ID}) ->
    ID.

get_payment_id(#domain_InvoicePayment{id = ID}) ->
    ID.

get_refund_id(#domain_InvoicePaymentRefund{id = ID}) ->
    ID.

get_latest_clock() ->
    {latest, #limiter_LatestClock{}}.

convert_to_limit_route(#domain_PaymentRoute{provider = Provider, terminal = Terminal}) ->
    #base_Route{
        provider = Provider,
        terminal = Terminal
    }.

log_limit_changes(TurnoverLimits, Clock, Context) ->
    Attrs = mk_limit_log_attributes(Context),
    lists:foreach(
        fun(#domain_TurnoverLimit{id = ID, upper_boundary = UpperBoundary, domain_revision = DomainRevision}) ->
            #limiter_Limit{amount = LimitAmount} = hg_limiter_client:get(ID, DomainRevision, Clock, Context),
            ok = logger:log(notice, "Limit change commited", [], #{
                limit => Attrs#{config_id => ID, boundary => UpperBoundary, amount => LimitAmount}
            })
        end,
        TurnoverLimits
    ).

mk_limit_log_attributes(#limiter_LimitContext{
    payment_processing = #context_payproc_Context{op = Op, invoice = CtxInvoice}
}) ->
    #context_payproc_Invoice{
        invoice = #domain_Invoice{party_ref = PartyConfigRef, shop_ref = ShopConfigRef},
        payment = #context_payproc_InvoicePayment{
            payment = Payment,
            refund = Refund,
            route = Route
        }
    } = CtxInvoice,
    #domain_Cash{amount = Amount, currency = Currency} =
        case Op of
            {invoice_payment, #context_payproc_OperationInvoicePayment{}} ->
                Payment#domain_InvoicePayment.cost;
            {invoice_payment_refund, #context_payproc_OperationInvoicePaymentRefund{}} ->
                Refund#domain_InvoicePaymentRefund.cash
        end,
    #{
        config_id => undefined,
        %% Limit boundary amount
        boundary => undefined,
        %% Current amount with accounted change
        amount => undefined,
        route => maybe_route_context(Route),
        party_config_ref => PartyConfigRef,
        shop_config_ref => ShopConfigRef,
        change => #{
            amount => Amount,
            currency => Currency#domain_CurrencyRef.symbolic_code
        }
    }.

maybe_route_context(undefined) ->
    undefined;
maybe_route_context(#base_Route{provider = Provider, terminal = Terminal}) ->
    #{
        provider_id => Provider#domain_ProviderRef.id,
        terminal_id => Terminal#domain_TerminalRef.id
    }.

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
    hg_utils:construct_complex_id([<<"limiter">>, <<"batch-request">>] ++ IdSegments).
