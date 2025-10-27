-module(hg_limiter).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
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

-export_type([turnover_limit_value/0]).

-export([get_turnover_limits/2]).
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

%% Very specific errors to crutch around
-define(OPERATION_NOT_FOUND, {invalid_request, [<<"OperationNotFound">>]}).

-spec get_turnover_limits(turnover_terms_container(), strict | lenient) -> [turnover_limit()].

get_turnover_limits(#domain_ShopConfig{turnover_limits = undefined}, _Mode) ->
    [];
get_turnover_limits(#domain_ShopConfig{turnover_limits = Limits}, Mode) ->
    ordsets:to_list(filter_existing_turnover_limits(Limits, Mode));
get_turnover_limits(#domain_PaymentsProvisionTerms{turnover_limits = undefined}, _Mode) ->
    [];
get_turnover_limits(#domain_PaymentsProvisionTerms{turnover_limits = {value, Limits}}, Mode) ->
    filter_existing_turnover_limits(Limits, Mode);
get_turnover_limits(#domain_PaymentsProvisionTerms{turnover_limits = Ambiguous}, _Mode) ->
    error({misconfiguration, {'Could not reduce selector to a value', Ambiguous}}).

-define(ref(LimitID), #domain_LimitConfigRef{id = LimitID}).
-define(LIMIT_NOT_FOUND(Revision, LimitRef), {object_not_found, {Revision, {limit_config, LimitRef}}}).

filter_existing_turnover_limits(Limits, Mode) ->
    %% When mode is strict and limit-config does not exist it raises a
    %% misconfiguration error.
    %% Otherwise it filters out non existent one.
    lists:filter(
        fun(#domain_TurnoverLimit{ref = ?ref(ID), domain_revision = Ver}) ->
            try
                _ = hg_domain:get(Ver, {limit_config, ?ref(ID)}),
                true
            catch
                error:?LIMIT_NOT_FOUND(_Revision, ?ref(_LimitID)) when Mode =:= lenient ->
                    false;
                error:?LIMIT_NOT_FOUND(Revision, ?ref(LimitID)) when Mode =:= strict ->
                    error({misconfiguration, {'Limit config not found', {Revision, LimitID}}})
            end
        end,
        Limits
    ).

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
    get_batch_limit_values(Context, TurnoverLimits, OperationIdSegments).

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
            IDs = [T#domain_TurnoverLimit.ref#domain_LimitConfigRef.id || T <- TurnoverLimits],
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
            IDs = [T#domain_TurnoverLimit.ref#domain_LimitConfigRef.id || T <- TurnoverLimits],
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
            ref = ?ref(LimitID),
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
    ok = batch_hold_limits(Context, TurnoverLimits, make_route_operation_segments(Invoice, Payment, Route, Iter)).

batch_hold_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_hold_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, _} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    _ = hg_limiter_client:hold_batch(LimitRequest, Context),
    ok.

-spec hold_shop_limits([turnover_limit()], party_config_ref(), shop_config_ref(), invoice(), payment()) -> ok.
hold_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    Context = gen_limit_shop_context(Invoice, Payment),
    ok = batch_hold_limits(
        Context, TurnoverLimits, make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment)
    ).

-spec hold_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
hold_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    ok = batch_hold_limits(Context, TurnoverLimits, make_refund_operation_segments(Invoice, Payment, Refund)).

make_refund_operation_segments(Invoice, Payment, Refund) ->
    [
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        {refund_session, get_refund_id(Refund)}
    ].

-spec commit_payment_limits([turnover_limit()], invoice(), payment(), route(), pos_integer(), cash() | undefined) -> ok.
commit_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, CapturedCash) ->
    Context = gen_limit_context(Invoice, Payment, Route, CapturedCash),
    OperationIdSegments = make_route_operation_segments(Invoice, Payment, Route, Iter),
    ok = batch_commit_limits(Context, TurnoverLimits, OperationIdSegments).

-spec commit_shop_limits([turnover_limit()], party_config_ref(), shop_config_ref(), invoice(), payment()) -> ok.
commit_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment) ->
    Context = gen_limit_shop_context(Invoice, Payment),
    OperationIdSegments = make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment),
    ok = batch_commit_limits(Context, TurnoverLimits, OperationIdSegments).

-spec commit_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
commit_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    OperationIdSegments = make_refund_operation_segments(Invoice, Payment, Refund),
    ok = batch_commit_limits(Context, TurnoverLimits, OperationIdSegments).

batch_commit_limits(_Context, [], _OperationIdSegments) ->
    ok;
batch_commit_limits(Context, TurnoverLimits, OperationIdSegments) ->
    {LimitRequest, TurnoverLimitsMap} = prepare_limit_request(TurnoverLimits, OperationIdSegments),
    ok = hg_limiter_client:commit_batch(LimitRequest, Context),
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
        hg_limiter_client:get_batch(LimitRequest, Context)
    ).

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
    OperationIdSegments = make_route_operation_segments(Invoice, Payment, Route, Iter),
    ok = batch_rollback_limits(Context, TurnoverLimits, OperationIdSegments, Flags).

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
    OperationIdSegments = make_shop_operation_segments(PartyConfigRef, ShopConfigRef, Invoice, Payment),
    ok = batch_rollback_limits(Context, TurnoverLimits, OperationIdSegments, Flags).

-spec rollback_refund_limits([turnover_limit()], invoice(), payment(), refund(), route()) -> ok.
rollback_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route) ->
    Context = gen_limit_refund_context(Invoice, Payment, Refund, Route),
    OperationIdSegments = make_refund_operation_segments(Invoice, Payment, Refund),
    ok = batch_rollback_limits(Context, TurnoverLimits, OperationIdSegments, []).

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

convert_to_limit_route(#domain_PaymentRoute{provider = Provider, terminal = Terminal}) ->
    #base_Route{
        provider = Provider,
        terminal = Terminal
    }.

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

prepare_limit_request(TurnoverLimits, IdSegments) ->
    {TurnoverLimitsIdList, LimitChanges} = lists:unzip(
        lists:map(
            fun(TurnoverLimit = #domain_TurnoverLimit{ref = ?ref(LimitID), domain_revision = DomainRevision}) ->
                {{LimitID, TurnoverLimit}, #limiter_LimitChange{id = LimitID, version = DomainRevision}}
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
