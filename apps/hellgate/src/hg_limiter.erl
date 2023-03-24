-module(hg_limiter).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").

-type turnover_selector() :: dmsl_domain_thrift:'TurnoverLimitSelector'().
-type turnover_limit() :: dmsl_domain_thrift:'TurnoverLimit'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type route() :: hg_routing:payment_route().
-type refund() :: hg_invoice_payment:domain_refund().
-type cash() :: dmsl_domain_thrift:'Cash'().

-export([get_turnover_limits/1]).
-export([check_limits/4]).
-export([hold_payment_limits/5]).
-export([hold_refund_limits/5]).
-export([commit_payment_limits/6]).
-export([commit_refund_limits/5]).
-export([rollback_payment_limits/5]).
-export([rollback_refund_limits/5]).

-define(route(ProviderRef, TerminalRef), #domain_PaymentRoute{
    provider = ProviderRef,
    terminal = TerminalRef
}).

-spec get_turnover_limits(turnover_selector() | undefined) -> [turnover_limit()].
get_turnover_limits(undefined) ->
    [];
get_turnover_limits({value, Limits}) ->
    Limits;
get_turnover_limits(Ambiguous) ->
    error({misconfiguration, {'Could not reduce selector to a value', Ambiguous}}).

-spec check_limits([turnover_limit()], invoice(), payment(), route()) ->
    {ok, [hg_limiter_client:limit()]}
    | {error, {limit_overflow, [binary()]}}.
check_limits(TurnoverLimits, Invoice, Payment, Route) ->
    Context = gen_limit_context(Invoice, Payment, Route),
    try
        check_limits_(TurnoverLimits, Context, [])
    catch
        throw:limit_overflow ->
            IDs = [T#domain_TurnoverLimit.id || T <- TurnoverLimits],
            {error, {limit_overflow, IDs}}
    end.

check_limits_([], _, Limits) ->
    {ok, Limits};
check_limits_([T | TurnoverLimits], Context, Acc) ->
    #domain_TurnoverLimit{id = LimitID, domain_revision = Version} = T,
    Clock = get_latest_clock(),
    Limit = hg_limiter_client:get(LimitID, Version, Clock, Context),
    #limiter_Limit{
        amount = LimiterAmount
    } = Limit,
    UpperBoundary = T#domain_TurnoverLimit.upper_boundary,
    case LimiterAmount =< UpperBoundary of
        true ->
            check_limits_(TurnoverLimits, Context, [Limit | Acc]);
        false ->
            logger:info("Limit with id ~p overflowed, amount ~p upper boundary ~p", [
                LimitID,
                LimiterAmount,
                UpperBoundary
            ]),
            throw(limit_overflow)
    end.

-spec hold_payment_limits([turnover_limit()], route(), pos_integer(), invoice(), payment()) -> ok.
hold_payment_limits(TurnoverLimits, Route, Iter, Invoice, Payment) ->
    ChangeID = construct_payment_change_id(Route, Iter, Invoice, Payment),
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeID),
    Context = gen_limit_context(Invoice, Payment, Route),
    hold(LimitChanges, get_latest_clock(), Context).

-spec hold_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
hold_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    ChangeID = construct_refund_change_id(Invoice, Payment, Refund),
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeID),
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    hold(LimitChanges, get_latest_clock(), Context).

-spec commit_payment_limits([turnover_limit()], route(), pos_integer(), invoice(), payment(), cash() | undefined) -> ok.
commit_payment_limits(TurnoverLimits, Route, Iter, Invoice, Payment, CapturedCash) ->
    ChangeID = construct_payment_change_id(Route, Iter, Invoice, Payment),
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeID),
    Context = gen_limit_context(Invoice, Payment, Route, CapturedCash),
    commit(LimitChanges, get_latest_clock(), Context).

-spec commit_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
commit_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    ChangeID = construct_refund_change_id(Invoice, Payment, Refund),
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeID),
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    commit(LimitChanges, get_latest_clock(), Context).

-spec rollback_payment_limits([turnover_limit()], route(), pos_integer(), invoice(), payment()) -> ok.
rollback_payment_limits(TurnoverLimits, Route, Iter, Invoice, Payment) ->
    ChangeID = construct_payment_change_id(Route, Iter, Invoice, Payment),
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeID),
    Context = gen_limit_context(Invoice, Payment, Route),
    rollback(LimitChanges, get_latest_clock(), Context).

-spec rollback_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
rollback_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    ChangeID = construct_refund_change_id(Invoice, Payment, Refund),
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeID),
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    rollback(LimitChanges, get_latest_clock(), Context).

-spec hold([hg_limiter_client:limit_change()], hg_limiter_client:clock(), hg_limiter_client:context()) -> ok.
hold(LimitChanges, Clock, Context) ->
    process_changes(LimitChanges, fun hg_limiter_client:hold/3, Clock, Context).

-spec commit([hg_limiter_client:limit_change()], hg_limiter_client:clock(), hg_limiter_client:context()) -> ok.
commit(LimitChanges, Clock, Context) ->
    process_changes(LimitChanges, fun hg_limiter_client:commit/3, Clock, Context).

-spec rollback([hg_limiter_client:limit_change()], hg_limiter_client:clock(), hg_limiter_client:context()) -> ok.
rollback(LimitChanges, Clock, Context) ->
    process_changes(LimitChanges, fun hg_limiter_client:rollback/3, Clock, Context).

process_changes(LimitChanges, WithFun, Clock, Context) ->
    lists:foreach(
        fun(LimitChange) -> WithFun(LimitChange, Clock, Context) end,
        LimitChanges
    ).

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

gen_limit_changes(Limits, ChangeID) ->
    [
        #limiter_LimitChange{
            id = ID,
            change_id = hg_utils:construct_complex_id([<<"limiter">>, ID, ChangeID]),
            version = Version
        }
     || #domain_TurnoverLimit{id = ID, domain_revision = Version} <- Limits
    ].

construct_payment_change_id(?route(ProviderRef, TerminalRef), Iter, Invoice, Payment) ->
    hg_utils:construct_complex_id([
        genlib:to_binary(get_provider_id(ProviderRef)),
        genlib:to_binary(get_terminal_id(TerminalRef)),
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        integer_to_binary(Iter)
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
