-module(hg_limiter).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").

-type turnover_selector() :: dmsl_domain_thrift:'TurnoverLimitSelector'().
-type turnover_limit() :: dmsl_domain_thrift:'TurnoverLimit'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type route() :: hg_route:payment_route().
-type refund() :: hg_invoice_payment:domain_refund().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type handling_flag() :: ignore_business_error | ignore_not_found.
-type turnover_limit_value() :: dmsl_payproc_thrift:'TurnoverLimitValue'().
-type party() :: hg_party:party().
-type shop() :: dmsl_domain_thrift:'Shop'().

-type change_queue() :: [hg_limiter_client:limit_change()].

-export_type([turnover_limit_value/0]).

-export([get_turnover_limits/1]).
-export([check_limits/4]).
-export([check_shop_limits/3]).
-export([hold_payment_limits/5]).
-export([hold_shop_limits/5]).
-export([hold_refund_limits/5]).
-export([commit_payment_limits/6]).
-export([commit_shop_limits/5]).
-export([commit_refund_limits/5]).
-export([rollback_payment_limits/6]).
-export([rollback_shop_limits/6]).
-export([rollback_refund_limits/5]).
-export([get_limit_values/4]).

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

-spec get_turnover_limits(turnover_selector() | undefined) -> [turnover_limit()].
get_turnover_limits(undefined) ->
    [];
get_turnover_limits({value, Limits}) ->
    Limits;
get_turnover_limits(Ambiguous) ->
    error({misconfiguration, {'Could not reduce selector to a value', Ambiguous}}).

-spec get_limit_values([turnover_limit()], invoice(), payment(), route()) -> [turnover_limit_value()].
get_limit_values(TurnoverLimits, Invoice, Payment, Route) ->
    Context = gen_limit_context(Invoice, Payment, Route),
    lists:foldl(
        fun(TurnoverLimit, Acc) ->
            #domain_TurnoverLimit{id = LimitID, domain_revision = Version} = TurnoverLimit,
            Clock = get_latest_clock(),
            Limit = hg_limiter_client:get(LimitID, Version, Clock, Context),
            #limiter_Limit{
                amount = LimiterAmount
            } = Limit,
            [#payproc_TurnoverLimitValue{limit = TurnoverLimit, value = LimiterAmount} | Acc]
        end,
        [],
        TurnoverLimits
    ).

-spec check_limits([turnover_limit()], invoice(), payment(), route()) ->
    {ok, [turnover_limit_value()]}
    | {error, {limit_overflow, [binary()], [turnover_limit_value()]}}.
check_limits(TurnoverLimits, Invoice, Payment, Route) ->
    Context = gen_limit_context(Invoice, Payment, Route),
    {ok, Limits} = gather_limits(TurnoverLimits, Context, []),
    try
        ok = check_limits_(Limits, Context),
        {ok, Limits}
    catch
        throw:limit_overflow ->
            IDs = [T#domain_TurnoverLimit.id || T <- TurnoverLimits],
            {error, {limit_overflow, IDs, Limits}}
    end.

-spec check_shop_limits([turnover_limit()], invoice(), payment()) ->
    ok
    | {error, {limit_overflow, [binary()]}}.
check_shop_limits(TurnoverLimits, Invoice, Payment) ->
    Context = gen_limit_shop_context(Invoice, Payment),
    {ok, Limits} = gather_limits(TurnoverLimits, Context, []),
    try
        ok = check_limits_(Limits, Context),
        ok
    catch
        throw:limit_overflow ->
            IDs = [T#domain_TurnoverLimit.id || T <- TurnoverLimits],
            {error, {limit_overflow, IDs}}
    end.

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

gather_limits([], _Context, Acc) ->
    {ok, Acc};
gather_limits([T | TurnoverLimits], Context, Acc) ->
    #domain_TurnoverLimit{id = LimitID, domain_revision = Version} = T,
    Clock = get_latest_clock(),
    #limiter_Limit{amount = Amount} = hg_limiter_client:get(LimitID, Version, Clock, Context),
    TurnoverLimitValue = #payproc_TurnoverLimitValue{limit = T, value = Amount},
    gather_limits(TurnoverLimits, Context, [TurnoverLimitValue | Acc]).

-spec hold_payment_limits([turnover_limit()], route(), pos_integer(), invoice(), payment()) -> ok.
hold_payment_limits(TurnoverLimits, Route, Iter, Invoice, Payment) ->
    ChangeIDs = [construct_payment_change_id(Route, Iter, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_context(Invoice, Payment, Route),
    hold(LimitChanges, get_latest_clock(), Context).

-spec hold_shop_limits([turnover_limit()], party(), shop(), invoice(), payment()) -> ok.
hold_shop_limits(TurnoverLimits, Party, Shop, Invoice, Payment) ->
    ChangeIDs = [construct_shop_change_id(Party, Shop, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_shop_context(Invoice, Payment),
    hold(LimitChanges, get_latest_clock(), Context).

-spec hold_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
hold_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    ChangeIDs = [construct_refund_change_id(Invoice, Payment, Refund)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    hold(LimitChanges, get_latest_clock(), Context).

-spec commit_payment_limits([turnover_limit()], route(), pos_integer(), invoice(), payment(), cash() | undefined) -> ok.
commit_payment_limits(TurnoverLimits, Route, Iter, Invoice, Payment, CapturedCash) ->
    ChangeIDs = [
        construct_payment_change_id(Route, Iter, Invoice, Payment),
        construct_payment_change_id(Route, Iter, Invoice, Payment, legacy)
    ],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_context(Invoice, Payment, Route, CapturedCash),
    Clock = get_latest_clock(),
    ok = commit(LimitChanges, Clock, Context),
    ok = log_limit_changes(TurnoverLimits, Clock, Context).

-spec commit_shop_limits([turnover_limit()], party(), shop(), invoice(), payment()) -> ok.
commit_shop_limits(TurnoverLimits, Party, Shop, Invoice, Payment) ->
    ChangeIDs = [construct_shop_change_id(Party, Shop, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_shop_context(Invoice, Payment),
    Clock = get_latest_clock(),
    ok = commit(LimitChanges, Clock, Context),
    ok = log_limit_changes(TurnoverLimits, Clock, Context),
    ok.

-spec commit_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
commit_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    ChangeIDs = [construct_refund_change_id(Invoice, Payment, Refund)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    Clock = get_latest_clock(),
    ok = commit(LimitChanges, Clock, Context),
    ok = log_limit_changes(TurnoverLimits, Clock, Context).

%% @doc This function supports flags that can change reaction behaviour to
%%      limiter response:
%%
%%      - `ignore_business_error` -- prevents error raise upon misconfiguration
%%      failures in limiter config
%%
%%      - `ignore_not_found` -- does not raise error if limiter won't be able to
%%      find according posting plan in accountant service
-spec rollback_payment_limits([turnover_limit()], route(), pos_integer(), invoice(), payment(), [handling_flag()]) ->
    ok.
rollback_payment_limits(TurnoverLimits, Route, Iter, Invoice, Payment, Flags) ->
    ChangeIDs = [
        construct_payment_change_id(Route, Iter, Invoice, Payment),
        construct_payment_change_id(Route, Iter, Invoice, Payment, legacy)
    ],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_context(Invoice, Payment, Route),
    rollback(LimitChanges, get_latest_clock(), Context, Flags).

-spec rollback_shop_limits([turnover_limit()], party(), shop(), invoice(), payment(), [handling_flag()]) ->
    ok.
rollback_shop_limits(TurnoverLimits, Party, Shop, Invoice, Payment, Flags) ->
    ChangeIDs = [construct_shop_change_id(Party, Shop, Invoice, Payment)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_shop_context(Invoice, Payment),
    rollback(LimitChanges, get_latest_clock(), Context, Flags).

-spec rollback_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
rollback_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    ChangeIDs = [construct_refund_change_id(Invoice, Payment, Refund)],
    LimitChanges = gen_limit_changes(TurnoverLimits, ChangeIDs),
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
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

%% Very specific error to crutch around
-define(POSTING_PLAN_NOT_FOUND(ID), #base_InvalidRequest{errors = [<<"Posting plan not found: ", ID/binary>>]}).

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

construct_shop_change_id(?party(PartyID), ?shop(ShopID), Invoice, Payment) ->
    hg_utils:construct_complex_id([
        PartyID,
        ShopID,
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
        invoice = #domain_Invoice{owner_id = PartyID, shop_id = ShopID},
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
        party_id => PartyID,
        shop_id => ShopID,
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
