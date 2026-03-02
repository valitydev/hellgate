%%% Invoice payment submachine
%%%
%%% TODO
%%%  - make proper submachine interface
%%%     - `init` should provide `next` or `done` to the caller
%%%  - handle idempotent callbacks uniformly
%%%     - get rid of matches against session status
%%%  - tag machine with the provider trx
%%%     - distinguish between trx tags and callback tags
%%%     - tag namespaces
%%%  - think about safe clamping of timers returned by some proxy
%%%  - why don't user interaction events imprint anything on the state?
%%%  - adjustments look and behave very much like claims over payments
%%%  - payment status transition are caused by the fact that some session
%%%    finishes, which could have happened in the past, not just now

-module(hg_invoice_payment).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").
-include_lib("hellgate/include/allocation.hrl").

-include("hg_invoice_payment.hrl").

%% API

%% St accessors

-export([get_payment/1]).
-export([get_refunds/1]).
-export([get_refunds_count/1]).
-export([get_chargebacks/1]).
-export([get_chargeback_state/2]).
-export([get_refund/2]).
-export([get_refund_state/2]).
-export([get_route/1]).
-export([get_iter/1]).
-export([get_adjustments/1]).
-export([get_allocation/1]).
-export([get_adjustment/2]).
-export([get_trx/1]).
-export([get_session/2]).

-export([get_final_cashflow/1]).
-export([get_sessions/1]).

-export([get_payment_revision/1]).
-export([get_remaining_payment_balance/1]).
-export([get_activity/1]).
-export([get_opts/1]).
-export([get_invoice/1]).
-export([get_origin/1]).
-export([get_risk_score/1]).

-export([construct_payment_info/2]).
-export([set_repair_scenario/2]).

%% Business logic

-export([capture/5]).
-export([cancel/2]).
-export([refund/3]).

-export([manual_refund/3]).

-export([create_adjustment/4]).

-export([create_chargeback/3]).
-export([cancel_chargeback/3]).
-export([reject_chargeback/3]).
-export([accept_chargeback/3]).
-export([reopen_chargeback/3]).

-export([get_provider_terminal_terms/3]).
-export([calculate_cashflow/3]).

-export([create_session_event_context/3]).
-export([add_session/3]).
-export([accrue_status_timing/3]).
-export([get_limit_values/2]).

%% Machine like

-export([init/3]).

-export([process_signal/3]).
-export([process_call/3]).
-export([process_timeout/3]).

-export([merge_change/3]).
-export([collapse_changes/3]).

-export([get_log_params/2]).
-export([validate_transition/4]).
-export([construct_payer/1]).

-export([construct_payment_plan_id/1]).
-export([construct_payment_plan_id/2]).

-export([get_payer_payment_tool/1]).
-export([get_payment_payer/1]).
-export([get_recurrent_token/1]).
-export([get_payment_state/2]).

%% Internal helper functions (exported for use by extracted modules)
-export([get_target/1]).
-export([get_target_type/1]).
-export([get_invoice_id/1]).
-export([get_payment_id/1]).
-export([try_get_refund_state/2]).
-export([rollback_payment_limits/4]).
-export([rollback_payment_cashflow/1]).
-export([maybe_notify_fault_detector/4]).
-export([process_failure/5]).
-export([get_payment_cost/1]).
-export([set_cashflow/2]).
-export([get_captured_cost/2]).
-export([get_captured_allocation/1]).
-export([get_adjustment_status/1]).
-export([define_event_timestamp/1]).
-export([try_accrue_waiting_timing/2]).
-export([update_session/3]).
-export([create_refund_event_context/2]).
-export([hold_shop_limits/2]).
-export([check_shop_limits/2]).
-export([rollback_shop_limits/3]).
-export([commit_shop_limits/2]).
-export([rollback_broken_payment_limits/1]).
-export([hold_limit_routes/4]).
-export([get_merchant_payments_terms/4]).
-export([get_cashflow_plan/1]).
-export([get_route_cascade_behaviour/2]).
-export([is_route_cascade_available/4]).
-export([get_st_meta/1]).
-export([get_payment_flow/1]).
-export([get_payment_created_at/1]).
-export([get_candidate_routes/1]).
-export([get_cashflow/1]).
-export([commit_payment_limits/1]).
-export([commit_payment_cashflow/1]).
-export([get_shop/2]).
-export([get_chargeback_opts/1]).

%%

-export_type([payment_id/0]).
-export_type([st/0]).
-export_type([activity/0]).
-export_type([machine_result/0]).
-export_type([opts/0]).
-export_type([payment/0]).
-export_type([payment_status/0]).
-export_type([payment_status_type/0]).
-export_type([refund_id/0]).
-export_type([refund_state/0]).
-export_type([trx_info/0]).
-export_type([target/0]).
-export_type([session_target_type/0]).
-export_type([session/0]).
-export_type([adjustment/0]).
-export_type([capture_data/0]).
-export_type([failure/0]).
-export_type([domain_refund/0]).
-export_type([result/0]).
-export_type([change/0]).
-export_type([change_opts/0]).
-export_type([action/0]).
-export_type([events/0]).
-export_type([adjustment_id/0]).
-export_type([cashflow_context/0]).

-type activity() ::
    payment_activity()
    | {refund, refund_id()}
    | adjustment_activity()
    | chargeback_activity()
    | idle.

-type payment_activity() :: {payment, payment_step()}.

-type adjustment_activity() ::
    {adjustment_new, adjustment_id()}
    | {adjustment_pending, adjustment_id()}.

-type chargeback_activity() :: {chargeback, chargeback_id(), chargeback_activity_type()}.

-type chargeback_activity_type() :: hg_invoice_payment_chargeback:activity().

-type payment_step() ::
    new
    | shop_limit_initializing
    | shop_limit_failure
    | shop_limit_finalizing
    | risk_scoring
    | routing
    | routing_failure
    | cash_flow_building
    | processing_session
    | processing_accounter
    | processing_capture
    | processing_failure
    | updating_accounter
    | flow_waiting
    | finalizing_session
    | finalizing_accounter.

-type chargeback_state() :: hg_invoice_payment_chargeback:state().

-type refund_state() :: hg_invoice_payment_refund:t().
-type st() :: #st{}.

-type cash() :: dmsl_domain_thrift:'Cash'().
-type cart() :: dmsl_domain_thrift:'InvoiceCart'().
-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type party_config_ref() :: dmsl_domain_thrift:'PartyConfigRef'().
-type payer() :: dmsl_domain_thrift:'Payer'().
-type payer_params() :: dmsl_payproc_thrift:'PayerParams'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type payment_status() :: dmsl_domain_thrift:'InvoicePaymentStatus'().
-type payment_status_type() :: pending | processed | captured | cancelled | refunded | failed | charged_back.
-type domain_refund() :: dmsl_domain_thrift:'InvoicePaymentRefund'().
-type payment_refund() :: dmsl_payproc_thrift:'InvoicePaymentRefund'().
-type refund_id() :: dmsl_domain_thrift:'InvoicePaymentRefundID'().
-type refund_params() :: dmsl_payproc_thrift:'InvoicePaymentRefundParams'().
-type payment_chargeback() :: dmsl_payproc_thrift:'InvoicePaymentChargeback'().
-type chargeback() :: dmsl_domain_thrift:'InvoicePaymentChargeback'().
-type chargeback_id() :: hg_invoice_payment_chargeback:id().
-type adjustment() :: dmsl_domain_thrift:'InvoicePaymentAdjustment'().
-type adjustment_id() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentID'().
-type adjustment_params() :: dmsl_payproc_thrift:'InvoicePaymentAdjustmentParams'().
-type target() :: dmsl_domain_thrift:'TargetInvoicePaymentStatus'().
-type session_target_type() :: 'processed' | 'captured' | 'cancelled' | 'refunded'.
-type risk_score() :: hg_inspector:risk_score().
-type route() :: hg_route:payment_route().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().
-type trx_info() :: dmsl_domain_thrift:'TransactionInfo'().
-type tag() :: dmsl_proxy_provider_thrift:'CallbackTag'().
-type callback() :: dmsl_proxy_provider_thrift:'Callback'().
-type session_change() :: hg_session:change().
-type callback_response() :: dmsl_proxy_provider_thrift:'CallbackResponse'().
-type retry_strategy() :: hg_retry:strategy().
-type capture_data() :: dmsl_payproc_thrift:'InvoicePaymentCaptureData'().
-type payment_session() :: dmsl_payproc_thrift:'InvoicePaymentSession'().
-type failure() :: dmsl_domain_thrift:'OperationFailure'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type session() :: hg_session:t().
-type payment_plan_id() :: hg_accounting:plan_id().
-type route_limit_context() :: dmsl_payproc_thrift:'RouteLimitContext'().

-type opts() :: #{
    party => party(),
    party_config_ref => party_config_ref(),
    invoice => invoice(),
    timestamp => hg_datetime:timestamp()
}.

-type cashflow_context() :: #{
    provision_terms := dmsl_domain_thrift:'PaymentsProvisionTerms'(),
    route := route(),
    payment := payment(),
    timestamp := hg_datetime:timestamp(),
    varset := hg_varset:varset(),
    revision := hg_domain:revision(),
    merchant_terms =>
        dmsl_domain_thrift:'PaymentsServiceTerms'() | dmsl_domain_thrift:'PaymentRefundsServiceTerms'(),
    allocation => hg_allocation:allocation() | undefined
}.

%%

-include("domain.hrl").
-include("payment_events.hrl").

-type change() ::
    dmsl_payproc_thrift:'InvoicePaymentChangePayload'().

%%

-define(LOG_MD(Level, Format, Args), logger:log(Level, Format, Args, logger:get_process_metadata())).

-spec get_payment(st()) -> payment().
get_payment(#st{payment = Payment}) ->
    Payment.

-spec get_risk_score(st()) -> risk_score().
get_risk_score(#st{risk_score = RiskScore}) ->
    RiskScore.

-spec get_route(st()) -> route() | undefined.
get_route(#st{routes = []}) ->
    undefined;
get_route(#st{routes = [Route | _AttemptedRoutes]}) ->
    Route.

-spec get_iter(st()) -> pos_integer().
get_iter(#st{routes = AttemptedRoutes, new_cash_provided = true}) ->
    length(AttemptedRoutes) * 1000;
get_iter(#st{routes = AttemptedRoutes}) ->
    length(AttemptedRoutes).

-spec get_candidate_routes(st()) -> [route()].
get_candidate_routes(#st{candidate_routes = undefined}) ->
    [];
get_candidate_routes(#st{candidate_routes = Routes}) ->
    Routes.

-spec get_adjustments(st()) -> [adjustment()].
get_adjustments(#st{adjustments = As}) ->
    As.

-spec get_allocation(st()) -> hg_allocation:allocation() | undefined.
get_allocation(#st{allocation = Allocation}) ->
    Allocation.

-spec get_adjustment(adjustment_id(), st()) -> adjustment() | no_return().
get_adjustment(ID, St) ->
    case try_get_adjustment(ID, St) of
        Adjustment = #domain_InvoicePaymentAdjustment{} ->
            Adjustment;
        undefined ->
            throw(#payproc_InvoicePaymentAdjustmentNotFound{})
    end.

-spec get_chargeback_state(chargeback_id(), st()) -> chargeback_state() | no_return().
get_chargeback_state(ID, St) ->
    case try_get_chargeback_state(ID, St) of
        undefined ->
            throw(#payproc_InvoicePaymentChargebackNotFound{});
        ChargebackState ->
            ChargebackState
    end.

-spec get_chargebacks(st()) -> [payment_chargeback()].
get_chargebacks(#st{chargebacks = CBs}) ->
    [build_payment_chargeback(CB) || {_ID, CB} <- lists:sort(maps:to_list(CBs))].

build_payment_chargeback(ChargebackState) ->
    #payproc_InvoicePaymentChargeback{
        chargeback = hg_invoice_payment_chargeback:get(ChargebackState),
        cash_flow = hg_invoice_payment_chargeback:get_cash_flow(ChargebackState)
    }.

-spec get_sessions(st()) -> [payment_session()].
get_sessions(#st{sessions = S}) ->
    [
        #payproc_InvoicePaymentSession{
            target_status = TS,
            transaction_info = TR
        }
     || #{target := TS, trx := TR} <- lists:flatten(maps:values(S))
    ].

-spec get_refunds(st()) -> [payment_refund()].
get_refunds(#st{refunds = Rs}) ->
    RefundList = lists:map(
        fun(Refund) ->
            Sessions = hg_invoice_payment_refund:sessions(Refund),
            #payproc_InvoicePaymentRefund{
                refund = hg_invoice_payment_refund:refund(Refund),
                sessions = lists:map(fun convert_refund_sessions/1, Sessions),
                cash_flow = hg_invoice_payment_refund:cash_flow(Refund)
            }
        end,
        maps:values(Rs)
    ),
    lists:sort(
        fun(
            #payproc_InvoicePaymentRefund{refund = X},
            #payproc_InvoicePaymentRefund{refund = Y}
        ) ->
            Xid = X#domain_InvoicePaymentRefund.id,
            Yid = Y#domain_InvoicePaymentRefund.id,
            Xid =< Yid
        end,
        RefundList
    ).

-spec get_refunds_count(st()) -> non_neg_integer().
get_refunds_count(#st{refunds = Refunds}) ->
    maps:size(Refunds).

convert_refund_sessions(Session) ->
    #payproc_InvoiceRefundSession{
        transaction_info = hg_session:trx_info(Session)
    }.

-spec get_refund(refund_id(), st()) -> domain_refund() | no_return().
get_refund(ID, St) ->
    case try_get_refund_state(ID, St) of
        Refund when Refund =/= undefined ->
            hg_invoice_payment_refund:refund(Refund);
        undefined ->
            throw(#payproc_InvoicePaymentRefundNotFound{})
    end.

-spec get_refund_state(refund_id(), st()) -> hg_invoice_payment_refund:t() | no_return().
get_refund_state(ID, St) ->
    case try_get_refund_state(ID, St) of
        Refund when Refund =/= undefined ->
            Refund;
        undefined ->
            throw(#payproc_InvoicePaymentRefundNotFound{})
    end.

%%

-spec get_activity(st()) -> activity().
get_activity(#st{activity = Activity}) ->
    Activity.

-spec get_opts(st()) -> opts().
get_opts(#st{opts = Opts}) ->
    Opts.

-spec get_chargeback_opts(st()) -> hg_invoice_payment_chargeback:opts().
get_chargeback_opts(#st{opts = Opts} = St) ->
    maps:merge(Opts, #{payment_state => St}).

%%

-type event() :: dmsl_payproc_thrift:'InvoicePaymentChangePayload'().
-type action() :: hg_machine_action:t().
-type events() :: [event()].
-type result() :: {events(), action()}.
-type machine_result() :: {next | done, result()}.

-spec init(payment_id(), _, opts()) -> {st(), result()}.
init(PaymentID, PaymentParams, Opts) ->
    scoper:scope(
        payment,
        #{
            id => PaymentID
        },
        fun() ->
            init_(PaymentID, PaymentParams, Opts)
        end
    ).

-spec init_(payment_id(), _, opts()) -> {st(), result()}.
init_(PaymentID, Params, #{timestamp := CreatedAt} = Opts) ->
    #payproc_InvoicePaymentParams{
        payer = PayerParams,
        flow = FlowParams,
        payer_session_info = PayerSessionInfo,
        make_recurrent = MakeRecurrent,
        context = Context,
        external_id = ExternalID,
        processing_deadline = Deadline
    } = Params,
    Revision = hg_domain:head(),
    PartyConfigRef = get_party_config_ref(Opts),
    ShopObj = get_shop_obj(Opts, Revision),
    Invoice = get_invoice(Opts),
    Cost = #domain_Cash{currency = Currency} = get_invoice_cost(Invoice),
    {ok, Payer, VS0} = construct_payer(PayerParams),
    VS1 = collect_validation_varset_(PartyConfigRef, ShopObj, Currency, VS0),
    Payment1 = construct_payment(
        PaymentID,
        CreatedAt,
        Cost,
        Payer,
        FlowParams,
        PartyConfigRef,
        ShopObj,
        VS1,
        Revision,
        genlib:define(MakeRecurrent, false)
    ),
    Payment2 = Payment1#domain_InvoicePayment{
        payer_session_info = PayerSessionInfo,
        context = Context,
        external_id = ExternalID,
        processing_deadline = Deadline
    },
    Events = [?payment_started(Payment2)],
    {collapse_changes(Events, undefined, #{}), {Events, hg_machine_action:instant()}}.

-spec get_merchant_payments_terms(opts(), hg_domain:revision(), hg_datetime:timestamp(), hg_varset:varset()) ->
    dmsl_domain_thrift:'PaymentsServiceTerms'().
get_merchant_payments_terms(Opts, Revision, _Timestamp, VS) ->
    Shop = get_shop(Opts, Revision),
    TermSet = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS),
    TermSet#domain_TermSet.payments.

-spec get_provider_terminal_terms(route(), hg_varset:varset(), hg_domain:revision()) ->
    dmsl_domain_thrift:'PaymentsProvisionTerms'() | undefined.
get_provider_terminal_terms(Route, VS, Revision) ->
    hg_invoice_payment_cashflow:get_provider_terminal_terms(Route, VS, Revision).

-spec construct_payer(payer_params()) -> {ok, payer(), map()}.
construct_payer(PayerParams) ->
    hg_invoice_payment_construction:construct_payer(PayerParams).

construct_payment(
    PaymentID,
    CreatedAt,
    Cost,
    Payer,
    FlowParams,
    PartyConfigRef,
    ShopObj,
    VS0,
    Revision,
    MakeRecurrent
) ->
    hg_invoice_payment_construction:construct_payment(
        PaymentID,
        CreatedAt,
        Cost,
        Payer,
        FlowParams,
        PartyConfigRef,
        ShopObj,
        VS0,
        Revision,
        MakeRecurrent
    ).

reconstruct_payment_flow(Payment, VS) ->
    hg_invoice_payment_construction:reconstruct_payment_flow(Payment, VS).

collect_validation_varset(St, Opts) ->
    hg_invoice_payment_cashflow:collect_validation_varset(St, Opts).

collect_validation_varset(PartyConfigRef, ShopObj, Payment, VS) ->
    hg_invoice_payment_cashflow:collect_validation_varset(PartyConfigRef, ShopObj, Payment, VS).

collect_validation_varset_(PartyConfigRef, {#domain_ShopConfigRef{id = ShopConfigID}, Shop}, Currency, VS) ->
    #domain_ShopConfig{
        category = Category
    } = Shop,
    VS#{
        party_config_ref => PartyConfigRef,
        shop_id => ShopConfigID,
        category => Category,
        currency => Currency
    }.

%%

-spec construct_payment_plan_id(st()) -> payment_plan_id().
construct_payment_plan_id(#st{opts = Opts, payment = Payment} = St) ->
    Iter = get_iter(St),
    hg_invoice_payment_construction:construct_payment_plan_id(get_invoice(Opts), Payment, Iter, normal).

-spec construct_payment_plan_id(st(), legacy | normal) -> payment_plan_id().
construct_payment_plan_id(#st{opts = Opts, payment = Payment} = St, Mode) ->
    Iter = get_iter(St),
    hg_invoice_payment_construction:construct_payment_plan_id(get_invoice(Opts), Payment, Iter, Mode).

%%

-spec start_session(target()) -> events().
start_session(Target) ->
    hg_invoice_payment_session:start_session(Target).

start_capture(Reason, Cost, Cart, Allocation) ->
    hg_invoice_payment_session:start_capture(Reason, Cost, Cart, Allocation).

start_partial_capture(Reason, Cost, Cart, FinalCashflow, Allocation) ->
    hg_invoice_payment_session:start_partial_capture(Reason, Cost, Cart, FinalCashflow, Allocation).

-spec capture(st(), binary(), cash() | undefined, cart() | undefined, opts()) ->
    {ok, result()}.
capture(St, Reason, Cost, Cart, Opts) ->
    Payment = get_payment(St),
    _ = assert_capture_cost_currency(Cost, Payment),
    _ = assert_capture_cart(Cost, Cart),
    _ = assert_activity({payment, flow_waiting}, St),
    _ = assert_payment_flow(hold, Payment),
    Revision = get_payment_revision(St),
    Timestamp = get_payment_created_at(Payment),
    VS = collect_validation_varset(St, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, Timestamp, VS),
    case check_equal_capture_cost_amount(Cost, Payment) of
        true ->
            total_capture(St, Reason, Cart, undefined);
        false ->
            partial_capture(St, Reason, Cost, Cart, Opts, MerchantTerms, Timestamp, undefined)
    end.

maybe_allocation(undefined, _Cost, _MerchantTerms, _Revision, _Opts) ->
    undefined;
maybe_allocation(AllocationPrototype, Cost, MerchantTerms, Revision, Opts) ->
    #domain_PaymentsServiceTerms{
        allocations = AllocationSelector
    } = MerchantTerms,
    Party = get_party(Opts),
    Shop = get_shop(Opts, Revision),

    %% NOTE Allocation is currently not allowed.
    {error, allocation_not_allowed} =
        hg_allocation:calculate(AllocationPrototype, Party, Shop, Cost, AllocationSelector),
    throw(#payproc_AllocationNotAllowed{}).

total_capture(St, Reason, Cart, Allocation) ->
    Payment = get_payment(St),
    Cost = get_payment_cost(Payment),
    Changes = start_capture(Reason, Cost, Cart, Allocation),
    {ok, {Changes, hg_machine_action:instant()}}.

partial_capture(St0, Reason, Cost, Cart, Opts, MerchantTerms, Timestamp, Allocation) ->
    Payment = get_payment(St0),
    Payment2 = Payment#domain_InvoicePayment{cost = Cost},
    St = St0#st{payment = Payment2},
    Revision = get_payment_revision(St),
    VS = collect_validation_varset(St, Opts),
    ok = validate_merchant_hold_terms(MerchantTerms),
    Route = get_route(St),
    ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
    ok = validate_provider_holds_terms(ProviderTerms),
    Context = #{
        provision_terms => ProviderTerms,
        merchant_terms => MerchantTerms,
        route => Route,
        payment => Payment2,
        timestamp => Timestamp,
        varset => VS,
        revision => Revision,
        allocation => Allocation
    },
    FinalCashflow = calculate_cashflow(Context, Opts),
    Changes = start_partial_capture(Reason, Cost, Cart, FinalCashflow, Allocation),
    {ok, {Changes, hg_machine_action:instant()}}.

-spec cancel(st(), binary()) -> {ok, result()}.
cancel(St, Reason) ->
    Payment = get_payment(St),
    _ = assert_activity({payment, flow_waiting}, St),
    _ = assert_payment_flow(hold, Payment),
    Changes = start_session(?cancelled_with_reason(Reason)),
    {ok, {Changes, hg_machine_action:instant()}}.

assert_capture_cost_currency(Cost, Payment) ->
    hg_invoice_payment_validation:assert_capture_cost_currency(Cost, Payment).

%% Delegated to hg_invoice_payment_validation, kept for backward compatibility
-compile({nowarn_unused_function, [validate_processing_deadline/2]}).
validate_processing_deadline(Payment, TargetType) ->
    hg_invoice_payment_validation:validate_processing_deadline(Payment, TargetType).

assert_capture_cart(Cost, Cart) ->
    hg_invoice_payment_validation:assert_capture_cart(Cost, Cart).

check_equal_capture_cost_amount(undefined, _) ->
    true;
check_equal_capture_cost_amount(?cash(PassedAmount, _), #domain_InvoicePayment{cost = ?cash(Amount, _)}) when
    PassedAmount =:= Amount
->
    true;
check_equal_capture_cost_amount(?cash(PassedAmount, _), #domain_InvoicePayment{cost = ?cash(Amount, _)}) when
    PassedAmount < Amount
->
    false;
check_equal_capture_cost_amount(?cash(PassedAmount, _), #domain_InvoicePayment{cost = ?cash(Amount, _)}) ->
    throw(#payproc_AmountExceededCaptureBalance{
        payment_amount = Amount,
        passed_amount = PassedAmount
    }).

validate_merchant_hold_terms(Terms) ->
    hg_invoice_payment_validation:validate_merchant_hold_terms(Terms).

validate_provider_holds_terms(Terms) ->
    hg_invoice_payment_validation:validate_provider_holds_terms(Terms).

-spec create_chargeback(st(), opts(), hg_invoice_payment_chargeback:create_params()) -> {chargeback(), result()}.
create_chargeback(St, Opts, Params) ->
    _ = assert_no_pending_chargebacks(St),
    _ = validate_payment_status(captured, get_payment(St)),
    ChargebackID = get_chargeback_id(Params),
    CBOpts = Opts#{payment_state => St},
    {Chargeback, {Changes, Action}} = hg_invoice_payment_chargeback:create(CBOpts, Params),
    {Chargeback, {[?chargeback_ev(ChargebackID, C) || C <- Changes], Action}}.

-spec cancel_chargeback(chargeback_id(), st(), hg_invoice_payment_chargeback:cancel_params()) -> {ok, result()}.
cancel_chargeback(ChargebackID, St, Params) ->
    ChargebackState = get_chargeback_state(ChargebackID, St),
    {ok, {Changes, Action}} = hg_invoice_payment_chargeback:cancel(ChargebackState, Params),
    {ok, {[?chargeback_ev(ChargebackID, C) || C <- Changes], Action}}.

-spec reject_chargeback(chargeback_id(), st(), hg_invoice_payment_chargeback:reject_params()) -> {ok, result()}.
reject_chargeback(ChargebackID, St, Params) ->
    ChargebackState = get_chargeback_state(ChargebackID, St),
    {ok, {Changes, Action}} = hg_invoice_payment_chargeback:reject(ChargebackState, St, Params),
    {ok, {[?chargeback_ev(ChargebackID, C) || C <- Changes], Action}}.

-spec accept_chargeback(chargeback_id(), st(), hg_invoice_payment_chargeback:accept_params()) -> {ok, result()}.
accept_chargeback(ChargebackID, St, Params) ->
    ChargebackState = get_chargeback_state(ChargebackID, St),
    {ok, {Changes, Action}} = hg_invoice_payment_chargeback:accept(ChargebackState, St, Params),
    {ok, {[?chargeback_ev(ChargebackID, C) || C <- Changes], Action}}.

-spec reopen_chargeback(chargeback_id(), st(), hg_invoice_payment_chargeback:reopen_params()) -> {ok, result()}.
reopen_chargeback(ChargebackID, St, Params) ->
    _ = assert_no_pending_chargebacks(St),
    ChargebackState = get_chargeback_state(ChargebackID, St),
    {ok, {Changes, Action}} = hg_invoice_payment_chargeback:reopen(ChargebackState, St, Params),
    {ok, {[?chargeback_ev(ChargebackID, C) || C <- Changes], Action}}.

get_chargeback_id(#payproc_InvoicePaymentChargebackParams{id = ID}) ->
    ID.

validate_payment_status(Status, Payment) ->
    hg_invoice_payment_validation:validate_payment_status(Status, Payment).

-spec refund(refund_params(), st(), opts()) -> {domain_refund(), result()}.
refund(Params, St0, #{timestamp := CreatedAt} = Opts) ->
    St = St0#st{opts = Opts},
    Revision = hg_domain:head(),
    Payment = get_payment(St),
    VS = collect_validation_varset(St, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS),
    Refund = make_refund(Params, Payment, Revision, CreatedAt, St, Opts),
    MerchantRefundTerms = get_merchant_refunds_terms(MerchantTerms),
    FinalCashflow = make_refund_cashflow(
        Refund,
        Payment,
        Revision,
        St,
        Opts,
        MerchantRefundTerms,
        VS,
        CreatedAt
    ),
    Changes = hg_invoice_payment_refund:create(#{
        refund => Refund,
        cash_flow => FinalCashflow
    }),
    {Refund, {Changes, hg_machine_action:instant()}}.

-spec manual_refund(refund_params(), st(), opts()) -> {domain_refund(), result()}.
manual_refund(Params, St0, #{timestamp := CreatedAt} = Opts) ->
    St = St0#st{opts = Opts},
    Revision = hg_domain:head(),
    Payment = get_payment(St),
    VS = collect_validation_varset(St, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS),
    Refund = make_refund(Params, Payment, Revision, CreatedAt, St, Opts),
    MerchantRefundTerms = get_merchant_refunds_terms(MerchantTerms),
    FinalCashflow = make_refund_cashflow(
        Refund,
        Payment,
        Revision,
        St,
        Opts,
        MerchantRefundTerms,
        VS,
        CreatedAt
    ),
    TransactionInfo = Params#payproc_InvoicePaymentRefundParams.transaction_info,
    Changes = hg_invoice_payment_refund:create(#{
        refund => Refund,
        cash_flow => FinalCashflow,
        transaction_info => TransactionInfo
    }),
    {Refund, {Changes, hg_machine_action:instant()}}.

make_refund(Params, Payment, Revision, CreatedAt, St, Opts) ->
    _ = assert_no_pending_chargebacks(St),
    _ = assert_payment_status(captured, Payment),
    _ = assert_previous_refunds_finished(St),
    Cash = define_refund_cash(Params#payproc_InvoicePaymentRefundParams.cash, St),
    _ = assert_refund_cash(Cash, St),
    Cart = Params#payproc_InvoicePaymentRefundParams.cart,
    _ = assert_refund_cart(Params#payproc_InvoicePaymentRefundParams.cash, Cart, St),
    Timestamp = get_payment_created_at(Payment),
    VS = collect_validation_varset(St, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, Timestamp, VS),
    Allocation = maybe_allocation(
        Params#payproc_InvoicePaymentRefundParams.allocation,
        Cash,
        MerchantTerms,
        Revision,
        Opts
    ),
    ok = validate_allocation_refund(Allocation, St),
    MerchantRefundTerms = get_merchant_refunds_terms(MerchantTerms),
    Refund = #domain_InvoicePaymentRefund{
        id = Params#payproc_InvoicePaymentRefundParams.id,
        created_at = CreatedAt,
        domain_revision = Revision,
        status = ?refund_pending(),
        reason = Params#payproc_InvoicePaymentRefundParams.reason,
        cash = Cash,
        cart = Cart,
        external_id = Params#payproc_InvoicePaymentRefundParams.external_id,
        allocation = Allocation
    },
    ok = validate_refund(MerchantRefundTerms, Refund, Payment),
    Refund.

validate_allocation_refund(Allocation, St) ->
    hg_invoice_payment_validation:validate_allocation_refund(Allocation, St).

make_refund_cashflow(Refund, Payment, Revision, St, Opts, MerchantTerms, VS, Timestamp) ->
    hg_invoice_payment_cashflow:make_refund_cashflow(Refund, Payment, Revision, St, Opts, MerchantTerms, VS, Timestamp).

assert_refund_cash(Cash, St) ->
    hg_invoice_payment_validation:assert_refund_cash(Cash, St).

assert_previous_refunds_finished(St) ->
    hg_invoice_payment_validation:assert_previous_refunds_finished(St).

assert_refund_cart(RefundCash, Cart, St) ->
    hg_invoice_payment_validation:assert_refund_cart(RefundCash, Cart, St).

-spec get_remaining_payment_balance(st()) -> cash().
get_remaining_payment_balance(St) ->
    Chargebacks = [CB#payproc_InvoicePaymentChargeback.chargeback || CB <- get_chargebacks(St)],
    PaymentAmount = get_payment_cost(get_payment(St)),
    lists:foldl(
        fun
            (#payproc_InvoicePaymentRefund{refund = R}, Acc) ->
                case get_refund_status(R) of
                    ?refund_succeeded() ->
                        hg_cash:sub(Acc, get_refund_cash(R));
                    _ ->
                        Acc
                end;
            (#domain_InvoicePaymentChargeback{} = CB, Acc) ->
                case hg_invoice_payment_chargeback:get_status(CB) of
                    ?chargeback_status_accepted() ->
                        hg_cash:sub(Acc, hg_invoice_payment_chargeback:get_body(CB));
                    _ ->
                        Acc
                end
        end,
        PaymentAmount,
        get_refunds(St) ++ Chargebacks
    ).

get_merchant_refunds_terms(#domain_PaymentsServiceTerms{refunds = Terms}) when Terms /= undefined ->
    normalize_refund_terms(Terms);
get_merchant_refunds_terms(#domain_PaymentsServiceTerms{refunds = undefined}) ->
    throw(#payproc_OperationNotPermitted{}).

normalize_refund_terms(#domain_PaymentRefundsServiceTerms{} = Terms) ->
    Terms;
normalize_refund_terms({value, Terms}) ->
    normalize_refund_terms(Terms);
normalize_refund_terms(Other) ->
    error({misconfiguration, {'Unexpected refund terms', Other}}).

validate_refund(Terms, Refund, Payment) ->
    hg_invoice_payment_validation:validate_refund(Terms, Refund, Payment).

%%

-spec create_adjustment(hg_datetime:timestamp(), adjustment_params(), st(), opts()) -> {adjustment(), result()}.
create_adjustment(Timestamp, Params, St, Opts) ->
    hg_invoice_payment_adjustment:create_adjustment(Timestamp, Params, St, Opts).

-spec calculate_cashflow(cashflow_context(), opts()) -> final_cash_flow().
calculate_cashflow(Context, Opts) ->
    hg_invoice_payment_cashflow:calculate_cashflow(Context, Opts).

-spec calculate_cashflow(hg_payment_institution:t(), cashflow_context(), opts()) -> final_cash_flow().
calculate_cashflow(PaymentInstitution, Context, Opts) ->
    hg_invoice_payment_cashflow:calculate_cashflow(PaymentInstitution, Context, Opts).

assert_activity(Activity, St) ->
    hg_invoice_payment_validation:assert_activity(Activity, St).

assert_payment_status(Status, InvoicePayment) ->
    hg_invoice_payment_validation:assert_payment_status(Status, InvoicePayment).

assert_no_pending_chargebacks(PaymentState) ->
    hg_invoice_payment_validation:assert_no_pending_chargebacks(PaymentState).

assert_payment_flow(Flow, Payment) ->
    hg_invoice_payment_validation:assert_payment_flow(Flow, Payment).

-spec get_adjustment_status(adjustment()) -> dmsl_domain_thrift:'InvoicePaymentAdjustmentStatus'().
get_adjustment_status(#domain_InvoicePaymentAdjustment{status = Status}) ->
    Status.

%%

-spec process_signal(timeout, st(), opts()) -> machine_result().
process_signal(timeout, St, Options) ->
    hg_invoice_payment_processing:process_signal(timeout, St, Options).

-spec process_timeout(activity(), action(), st()) -> machine_result().
process_timeout(Activity, Action, St) ->
    hg_invoice_payment_processing:process_timeout(Activity, Action, St).

-spec process_call
    ({callback, tag(), callback()}, st(), opts()) -> {callback_response(), machine_result()};
    ({session_change, tag(), session_change()}, st(), opts()) -> {ok, machine_result()}.
process_call(Call, St, Options) ->
    hg_invoice_payment_processing:process_call(Call, St, Options).

route_args(St) ->
    hg_invoice_payment_routing:route_args(St).

build_routing_context(PaymentInstitution, VS, Revision, St) ->
    hg_invoice_payment_routing:build_routing_context(PaymentInstitution, VS, Revision, St).

%% NOTE See damsel payproc errors (proto/payment_processing_errors.thrift) for no route found

%%

-spec process_failure(activity(), [change()], action(), failure(), st()) -> machine_result().
process_failure(Activity, Events, Action, Failure, St) ->
    hg_invoice_payment_processing:process_failure(Activity, Events, Action, Failure, St).

-spec maybe_notify_fault_detector(activity(), session_target_type(), atom(), st()) -> ok.
maybe_notify_fault_detector({payment, processing_session}, processed, Status, St) ->
    ProviderRef = get_route_provider(get_route(St)),
    ProviderID = ProviderRef#domain_ProviderRef.id,
    PaymentID = get_payment_id(get_payment(St)),
    InvoiceID = get_invoice_id(get_invoice(get_opts(St))),
    ServiceType = provider_conversion,
    OperationID = hg_fault_detector_client:build_operation_id(ServiceType, [InvoiceID, PaymentID]),
    ServiceID = hg_fault_detector_client:build_service_id(ServiceType, ProviderID),
    hg_fault_detector_client:register_transaction(ServiceType, Status, ServiceID, OperationID);
maybe_notify_fault_detector(_Activity, _TargetType, _Status, _St) ->
    ok.

-compile(
    {nowarn_unused_function, [
        get_actual_retry_strategy/2,
        get_initial_retry_strategy/1,
        check_retry_possibility/3,
        check_failure_type/2,
        get_error_class/1,
        do_check_failure_type/1
    ]}
).
-spec get_actual_retry_strategy(target(), st()) -> retry_strategy().
get_actual_retry_strategy(Target, St) ->
    hg_invoice_payment_session:get_actual_retry_strategy(Target, St).

-spec get_initial_retry_strategy(session_target_type()) -> retry_strategy().
get_initial_retry_strategy(TargetType) ->
    hg_invoice_payment_session:get_initial_retry_strategy(TargetType).

-spec check_retry_possibility(Target, Failure, St) -> {retry, Timeout} | fatal when
    Failure :: failure(),
    Target :: target(),
    St :: st(),
    Timeout :: non_neg_integer().
check_retry_possibility(Target, Failure, St) ->
    hg_invoice_payment_session:check_retry_possibility(Target, Failure, St).

-spec check_failure_type(target(), failure()) -> transient | fatal.
check_failure_type(Target, Failure) ->
    hg_invoice_payment_session:check_failure_type(Target, Failure).

-spec get_error_class(target()) -> atom().
get_error_class(Target) ->
    hg_invoice_payment_session:get_error_class(Target).

-spec do_check_failure_type(failure()) -> transient | fatal.
do_check_failure_type(Failure) ->
    hg_invoice_payment_session:do_check_failure_type(Failure).

-compile({nowarn_unused_function, [set_timer/2]}).
set_timer(Timer, Action) ->
    hg_machine_action:set_timer(Timer, Action).

get_provider_payment_terms(St, Revision) ->
    Opts = get_opts(St),
    Route = get_route(St),
    Payment = get_payment(St),
    VS0 = reconstruct_payment_flow(Payment, #{}),
    VS1 = collect_validation_varset(get_party_config_ref(Opts), get_shop_obj(Opts, Revision), Payment, VS0),
    hg_routing:get_payment_terms(Route, VS1, Revision).

%% Shop limits

-spec hold_shop_limits(opts(), st()) -> ok.
hold_shop_limits(Opts, St) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    Invoice = get_invoice(Opts),
    PartyConfigRef = get_party_config_ref(Opts),
    {ShopConfigRef, Shop} = get_shop_obj(Opts, Revision),
    TurnoverLimits = get_shop_turnover_limits(Shop),
    ok = hg_limiter:hold_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment).

-spec commit_shop_limits(opts(), st()) -> ok.
commit_shop_limits(Opts, St) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    Invoice = get_invoice(Opts),
    PartyConfigRef = get_party_config_ref(Opts),
    {ShopConfigRef, Shop} = get_shop_obj(Opts, Revision),
    TurnoverLimits = get_shop_turnover_limits(Shop),
    ok = hg_limiter:commit_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment).

-spec check_shop_limits(opts(), st()) -> ok | {error, term()}.
check_shop_limits(Opts, St) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    Invoice = get_invoice(Opts),
    PartyConfigRef = get_party_config_ref(Opts),
    {ShopConfigRef, Shop} = get_shop_obj(Opts, Revision),
    TurnoverLimits = get_shop_turnover_limits(Shop),
    hg_limiter:check_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment).

-spec rollback_shop_limits(opts(), st(), list()) -> ok.
rollback_shop_limits(Opts, St, Flags) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    Invoice = get_invoice(Opts),
    PartyConfigRef = get_party_config_ref(Opts),
    {ShopConfigRef, Shop} = get_shop_obj(Opts, Revision),
    TurnoverLimits = get_shop_turnover_limits(Shop),
    ok = hg_limiter:rollback_shop_limits(
        TurnoverLimits,
        PartyConfigRef,
        ShopConfigRef,
        Invoice,
        Payment,
        Flags
    ).

get_shop_turnover_limits(ShopConfig) ->
    hg_limiter:get_turnover_limits(ShopConfig, strict).

%%

-spec hold_limit_routes([hg_route:t()], hg_varset:varset(), pos_integer(), st()) ->
    {[hg_route:t()], [hg_route:rejected_route()]}.
hold_limit_routes(Routes0, VS, Iter, St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    {Routes1, Rejected} = lists:foldl(
        fun(Route, {LimitHeldRoutes, RejectedRoutes} = Acc) ->
            PaymentRoute = hg_route:to_payment_route(Route),
            ProviderTerms = hg_routing:get_payment_terms(PaymentRoute, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms, strict),
            try
                ok = hg_limiter:hold_payment_limits(TurnoverLimits, Invoice, Payment, PaymentRoute, Iter),
                {[Route | LimitHeldRoutes], RejectedRoutes}
            catch
                error:(#limiter_LimitNotFound{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc);
                error:(#limiter_InvalidOperationCurrency{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc);
                error:(#limiter_OperationContextNotSupported{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc);
                error:(#limiter_PaymentToolNotSupported{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc)
            end
        end,
        {[], []},
        Routes0
    ),
    {lists:reverse(Routes1), Rejected}.

do_reject_route(LimiterError, Route, TurnoverLimits, {LimitHeldRoutes, RejectedRoutes}) ->
    LimitsIDs = [T#domain_TurnoverLimit.ref#domain_LimitConfigRef.id || T <- TurnoverLimits],
    RejectedRoute = hg_route:to_rejected_route(Route, {'LimitHoldError', LimitsIDs, LimiterError}),
    {LimitHeldRoutes, [RejectedRoute | RejectedRoutes]}.

-spec rollback_payment_limits([hg_route:payment_route()], non_neg_integer(), st(), list()) -> ok.
rollback_payment_limits(Routes, Iter, St, Flags) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    VS = get_varset(St, #{}),
    lists:foreach(
        fun(Route) ->
            ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms, strict),
            ok = hg_limiter:rollback_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, Flags)
        end,
        Routes
    ).

-spec rollback_broken_payment_limits(st()) -> ok.
rollback_broken_payment_limits(St) ->
    Opts = get_opts(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    LimitValues = get_limit_values_(St, lenient),
    Iter = maps:size(LimitValues),
    maps:fold(
        fun
            (_Route, [], Acc) ->
                Acc;
            (Route, Values, _Acc) ->
                TurnoverLimits =
                    lists:foldl(
                        fun(#payproc_TurnoverLimitValue{limit = TurnoverLimit}, Acc1) ->
                            [TurnoverLimit | Acc1]
                        end,
                        [],
                        Values
                    ),
                ok = hg_limiter:rollback_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, [
                    ignore_business_error
                ])
        end,
        ok,
        LimitValues
    ).

get_turnover_limits(ProviderTerms, Mode) ->
    hg_limiter:get_turnover_limits(ProviderTerms, Mode).

-spec commit_payment_limits(st()) -> ok.
commit_payment_limits(#st{capture_data = CaptureData} = St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    #payproc_InvoicePaymentCaptureData{cash = CapturedCash} = CaptureData,
    Invoice = get_invoice(Opts),
    Route = get_route(St),
    ProviderTerms = get_provider_payment_terms(St, Revision),
    TurnoverLimits = get_turnover_limits(ProviderTerms, strict),
    Iter = get_iter(St),
    hg_limiter:commit_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, CapturedCash).

-spec commit_payment_cashflow(st()) -> ok.
commit_payment_cashflow(St) ->
    Plan = get_cashflow_plan(St),
    _ = do_try_with_ids(
        [
            construct_payment_plan_id(St),
            construct_payment_plan_id(St, legacy)
        ],
        fun(ID) ->
            hg_accounting:commit(ID, Plan)
        end
    ),
    ok.

-spec rollback_payment_cashflow(st()) -> ok.
rollback_payment_cashflow(St) ->
    Plan = get_cashflow_plan(St),
    _ = do_try_with_ids(
        [
            construct_payment_plan_id(St),
            construct_payment_plan_id(St, legacy)
        ],
        fun(ID) ->
            hg_accounting:rollback(ID, Plan)
        end
    ),
    ok.

-spec do_try_with_ids([payment_plan_id()], fun((payment_plan_id()) -> T)) -> T | no_return().
do_try_with_ids([ID], Func) when is_function(Func, 1) ->
    Func(ID);
do_try_with_ids([ID | OtherIDs], Func) when is_function(Func, 1) ->
    try
        Func(ID)
    catch
        %% Very specific error to crutch around
        error:{accounting, #base_InvalidRequest{errors = [<<"Posting plan not found: ", ID/binary>>]}} ->
            do_try_with_ids(OtherIDs, Func)
    end.

-spec get_cashflow_plan(st()) -> [{integer(), hg_cashflow:final_cash_flow()}].
get_cashflow_plan(
    #st{
        partial_cash_flow = PartialCashFlow,
        new_cash_provided = true,
        new_cash_flow = NewCashFlow
    } = St
) when PartialCashFlow =/= undefined ->
    [
        {1, get_cashflow(St)},
        {2, hg_cashflow:revert(get_cashflow(St))},
        {3, PartialCashFlow},
        {4, hg_cashflow:revert(PartialCashFlow)},
        {5, NewCashFlow}
    ];
get_cashflow_plan(#st{new_cash_provided = true, new_cash_flow = NewCashFlow} = St) ->
    [
        {1, get_cashflow(St)},
        {2, hg_cashflow:revert(get_cashflow(St))},
        {3, NewCashFlow}
    ];
get_cashflow_plan(#st{partial_cash_flow = PartialCashFlow} = St) when PartialCashFlow =/= undefined ->
    [
        {1, get_cashflow(St)},
        {2, hg_cashflow:revert(get_cashflow(St))},
        {3, PartialCashFlow}
    ];
get_cashflow_plan(St) ->
    [{1, get_cashflow(St)}].

-spec set_repair_scenario(hg_invoice_repair:scenario(), st()) -> st().
set_repair_scenario(Scenario, St) ->
    St#st{repair_scenario = Scenario}.

%%

-type payment_info() :: dmsl_proxy_provider_thrift:'PaymentInfo'().

-spec construct_payment_info(st(), opts()) -> payment_info().
construct_payment_info(St, Opts) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    hg_invoice_payment_construction:construct_payment_info(
        get_activity(St),
        get_target(St),
        St,
        #proxy_provider_PaymentInfo{
            shop = hg_invoice_payment_construction:construct_proxy_shop(get_shop_obj(Opts, Revision)),
            invoice = hg_invoice_payment_construction:construct_proxy_invoice(get_invoice(Opts)),
            payment = hg_invoice_payment_construction:construct_proxy_payment(Payment, get_trx(St))
        }
    ).

%%

get_party(#{party := Party}) ->
    Party.

get_party_config_ref(#{party_config_ref := PartyConfigRef}) ->
    PartyConfigRef.

-spec get_shop(opts(), hg_domain:revision()) -> dmsl_domain_thrift:'ShopConfig'().
get_shop(Opts, Revision) ->
    {_, Shop} = get_shop_obj(Opts, Revision),
    Shop.

get_shop_obj(#{invoice := Invoice, party_config_ref := PartyConfigRef}, Revision) ->
    hg_party:get_shop(get_invoice_shop_config_ref(Invoice), PartyConfigRef, Revision).

-spec get_invoice(opts()) -> invoice().
get_invoice(#{invoice := Invoice}) ->
    Invoice.

-spec get_invoice_id(invoice()) -> invoice_id().
get_invoice_id(#domain_Invoice{id = ID}) ->
    ID.

get_invoice_cost(#domain_Invoice{cost = Cost}) ->
    Cost.

get_invoice_shop_config_ref(#domain_Invoice{shop_ref = ShopConfigRef}) ->
    ShopConfigRef.

-spec get_payment_id(payment()) -> payment_id().
get_payment_id(#domain_InvoicePayment{id = ID}) ->
    ID.

-spec get_payment_cost(payment()) -> dmsl_domain_thrift:'Cash'().
get_payment_cost(#domain_InvoicePayment{changed_cost = Cost}) when Cost =/= undefined ->
    Cost;
get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

-spec get_payment_flow(payment()) -> dmsl_domain_thrift:'InvoicePaymentFlow'().
get_payment_flow(#domain_InvoicePayment{flow = Flow}) ->
    Flow.

-spec get_payment_created_at(payment()) -> hg_datetime:timestamp().
get_payment_created_at(#domain_InvoicePayment{created_at = CreatedAt}) ->
    CreatedAt.

-spec get_payer_payment_tool(payer()) -> payment_tool().
get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource);
get_payer_payment_tool(?recurrent_payer(PaymentTool, _, _)) ->
    PaymentTool.

get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

get_varset(St, InitialValue) ->
    Opts = get_opts(St),
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    VS0 = reconstruct_payment_flow(Payment, InitialValue),
    VS1 = collect_validation_varset(get_party_config_ref(Opts), get_shop_obj(Opts, Revision), Payment, VS0),
    VS1.

%%

-type change_opts() :: #{
    timestamp => hg_datetime:timestamp(),
    validation => strict,
    invoice_id => invoice_id()
}.

-spec merge_change(change(), st() | undefined, change_opts()) -> st().
merge_change(Change, St, Opts) ->
    hg_invoice_payment_state:merge_change(Change, St, Opts).

get_routing_attempt_limit(St) ->
    hg_invoice_payment_routing:get_routing_attempt_limit(St).

-spec validate_transition(activity() | [activity()], change(), st(), change_opts()) -> ok | no_return().
validate_transition(Allowed, Change, St, Opts) ->
    hg_invoice_payment_validation:validate_transition(Allowed, Change, St, Opts).

-spec accrue_status_timing(payment_status_type(), opts(), st()) -> hg_timings:t().
accrue_status_timing(Name, Opts, #st{timings = Timings}) ->
    EventTime = define_event_timestamp(Opts),
    hg_timings:mark(Name, EventTime, hg_timings:accrue(Name, started, EventTime, Timings)).

-spec get_limit_values(st(), opts()) -> route_limit_context().
get_limit_values(St, Opts) ->
    get_limit_values_(St#st{opts = Opts}, strict).

get_limit_values_(St, Mode) ->
    {PaymentInstitution, VS, Revision} = route_args(St),
    Ctx = build_routing_context(PaymentInstitution, VS, Revision, St),
    Payment = get_payment(St),
    Invoice = get_invoice(get_opts(St)),
    %% NOTE If event 'route_changed' didn't occur, then there may be
    %% no route yet, however this must be accounted as first iteration
    %% of routing attempt.
    Iter =
        case get_route(St) of
            undefined -> 1;
            _ -> get_iter(St)
        end,
    lists:foldl(
        fun(Route, Acc) ->
            PaymentRoute = hg_route:to_payment_route(Route),
            ProviderTerms = hg_routing:get_payment_terms(PaymentRoute, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms, Mode),
            TurnoverLimitValues =
                hg_limiter:get_limit_values(TurnoverLimits, Invoice, Payment, PaymentRoute, Iter),
            Acc#{PaymentRoute => TurnoverLimitValues}
        end,
        #{},
        hg_routing_ctx:considered_candidates(Ctx)
    ).

-spec try_accrue_waiting_timing(change_opts(), st()) -> hg_timings:t().
try_accrue_waiting_timing(Opts, #st{payment = Payment, timings = Timings}) ->
    case get_payment_flow(Payment) of
        ?invoice_payment_flow_instant() ->
            Timings;
        ?invoice_payment_flow_hold(_, _) ->
            hg_timings:accrue(waiting, processed, define_event_timestamp(Opts), Timings)
    end.

-spec get_cashflow(st()) -> final_cash_flow().
get_cashflow(#st{cash_flow = FinalCashflow}) ->
    FinalCashflow.

-spec set_cashflow(final_cash_flow(), st()) -> st().
set_cashflow(Cashflow, St) ->
    hg_invoice_payment_state:set_cashflow(Cashflow, St).

-spec get_final_cashflow(st()) -> final_cash_flow().
get_final_cashflow(#st{final_cash_flow = Cashflow}) ->
    Cashflow.

-spec get_trx(st()) -> trx_info().
get_trx(#st{trx = Trx}) ->
    Trx.

-spec try_get_refund_state(refund_id(), st()) -> refund_state() | undefined.
try_get_refund_state(ID, St) ->
    hg_invoice_payment_state:try_get_refund_state(ID, St).

-spec try_get_chargeback_state(chargeback_id(), st()) -> chargeback_state() | undefined.
try_get_chargeback_state(ID, St) ->
    hg_invoice_payment_state:try_get_chargeback_state(ID, St).

-spec get_origin(st() | undefined) -> dmsl_domain_thrift:'InvoicePaymentRegistrationOrigin'() | undefined.
get_origin(#st{payment = #domain_InvoicePayment{registration_origin = Origin}}) ->
    Origin.

-spec get_captured_cost(dmsl_domain_thrift:'InvoicePaymentCaptured'(), payment()) ->
    dmsl_domain_thrift:'Cash'().
get_captured_cost(#domain_InvoicePaymentCaptured{cost = Cost}, _) when Cost /= undefined ->
    Cost;
get_captured_cost(_, #domain_InvoicePayment{cost = Cost}) ->
    Cost.

-spec get_captured_allocation(dmsl_domain_thrift:'InvoicePaymentCaptured'()) ->
    hg_allocation:allocation() | undefined.
get_captured_allocation(#domain_InvoicePaymentCaptured{allocation = Allocation}) ->
    Allocation.

-spec create_session_event_context(target(), st(), change_opts()) -> hg_session:event_context().
create_session_event_context(Target, St, Opts) ->
    hg_invoice_payment_session:create_session_event_context(Target, St, Opts).

-spec create_refund_event_context(st(), change_opts()) -> hg_invoice_payment_refund:event_context().
create_refund_event_context(St, Opts) ->
    #{
        timestamp => define_event_timestamp(Opts),
        route => get_route(St),
        session_context => create_session_event_context(?refunded(), St, Opts)
    }.

get_refund_status(#domain_InvoicePaymentRefund{status = Status}) ->
    Status.

define_refund_cash(undefined, St) ->
    get_remaining_payment_balance(St);
define_refund_cash(?cash(_, SymCode) = Cash, #st{payment = #domain_InvoicePayment{cost = ?cash(_, SymCode)}}) ->
    Cash;
define_refund_cash(?cash(_, SymCode), _St) ->
    throw(#payproc_InconsistentRefundCurrency{currency = SymCode}).

get_refund_cash(#domain_InvoicePaymentRefund{cash = Cash}) ->
    Cash.

-spec try_get_adjustment(adjustment_id(), st()) -> adjustment() | undefined.
try_get_adjustment(ID, St) ->
    hg_invoice_payment_state:try_get_adjustment(ID, St).

get_invoice_state(InvoiceID) ->
    case hg_invoice:get(InvoiceID) of
        {ok, Invoice} ->
            Invoice;
        {error, notfound} ->
            throw(#payproc_InvoiceNotFound{})
    end.

-spec get_payment_state(invoice_id(), payment_id()) -> st() | no_return().
get_payment_state(InvoiceID, PaymentID) ->
    Invoice = get_invoice_state(InvoiceID),
    case hg_invoice:get_payment(PaymentID, Invoice) of
        {ok, Payment} ->
            Payment;
        {error, notfound} ->
            throw(#payproc_InvoicePaymentNotFound{})
    end.

-spec get_session(target(), st()) -> session().
get_session(Target, St) ->
    hg_invoice_payment_session:get_session(Target, St).

-spec add_session(target(), session(), st()) -> st().
add_session(Target, Session, St) ->
    hg_invoice_payment_session:add_session(Target, Session, St).

-spec update_session(target(), session(), st()) -> st().
update_session(Target, Session, St) ->
    hg_invoice_payment_session:update_session(Target, Session, St).

-spec get_target(st()) -> target().
get_target(#st{target = Target}) ->
    Target.

-spec get_target_type(target()) -> session_target_type().
get_target_type({Type, _}) when Type == 'processed'; Type == 'captured'; Type == 'cancelled'; Type == 'refunded' ->
    Type.

-spec get_recurrent_token(st()) -> undefined | dmsl_domain_thrift:'Token'().
get_recurrent_token(#st{recurrent_token = Token}) ->
    Token.

-spec get_payment_revision(st()) -> hg_domain:revision().
get_payment_revision(#st{payment = #domain_InvoicePayment{domain_revision = Revision}}) ->
    Revision.

-spec get_payment_payer(st()) -> dmsl_domain_thrift:'Payer'().
get_payment_payer(#st{payment = #domain_InvoicePayment{payer = Payer}}) ->
    Payer.

%%

%%

-spec collapse_changes([change()], st() | undefined, change_opts()) -> st() | undefined.
collapse_changes(Changes, St, Opts) ->
    hg_invoice_payment_state:collapse_changes(Changes, St, Opts).

%%

get_route_provider(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

-spec get_st_meta(st()) -> #{id => payment_id()}.
get_st_meta(#st{payment = #domain_InvoicePayment{id = ID}}) ->
    #{
        id => ID
    };
get_st_meta(_) ->
    #{}.

%% Timings

-spec define_event_timestamp(change_opts()) -> integer().
define_event_timestamp(#{timestamp := Dt}) ->
    hg_datetime:parse(Dt, millisecond);
define_event_timestamp(#{}) ->
    erlang:system_time(millisecond).

%% Business metrics logging

-spec get_log_params(change(), st()) ->
    {ok, #{type := invoice_payment_event, params := list(), message := string()}} | undefined.
get_log_params(?payment_started(Payment), _) ->
    Params = #{
        payment => Payment,
        event_type => invoice_payment_started
    },
    make_log_params(Params);
get_log_params(?risk_score_changed(RiskScore), _) ->
    Params = #{
        risk_score => RiskScore,
        event_type => invoice_payment_risk_score_changed
    },
    make_log_params(Params);
get_log_params(?route_changed(Route), _) ->
    Params = #{
        route => Route,
        event_type => invoice_payment_route_changed
    },
    make_log_params(Params);
get_log_params(?cash_flow_changed(CashFlow), _) ->
    Params = #{
        cashflow => CashFlow,
        event_type => invoice_payment_cash_flow_changed
    },
    make_log_params(Params);
get_log_params(?payment_started(Payment, RiskScore, Route, CashFlow), _) ->
    Params = #{
        payment => Payment,
        cashflow => CashFlow,
        risk_score => RiskScore,
        route => Route,
        event_type => invoice_payment_started
    },
    make_log_params(Params);
get_log_params(?payment_status_changed(Status), State) ->
    make_log_params(
        #{
            status => Status,
            payment => get_payment(State),
            cashflow => get_final_cashflow(State),
            timings => State,
            event_type => invoice_payment_status_changed
        }
    );
get_log_params(_, _) ->
    undefined.

make_log_params(Params) ->
    LogParams = maps:fold(
        fun(K, V, Acc) ->
            make_log_params(K, V) ++ Acc
        end,
        [],
        Params
    ),
    Message = get_message(maps:get(event_type, Params)),
    {ok, #{
        type => invoice_payment_event,
        params => LogParams,
        message => Message
    }}.

make_log_params(
    payment,
    #domain_InvoicePayment{
        id = ID,
        cost = Cost,
        flow = Flow
    }
) ->
    [{id, ID}, {cost, make_log_params(cash, Cost)}, {flow, make_log_params(flow, Flow)}];
make_log_params(cash, ?cash(Amount, SymCode)) ->
    [{amount, Amount}, {currency, SymCode}];
make_log_params(flow, ?invoice_payment_flow_instant()) ->
    [{type, instant}];
make_log_params(flow, ?invoice_payment_flow_hold(OnHoldExpiration, _)) ->
    [{type, hold}, {on_hold_expiration, OnHoldExpiration}];
make_log_params(cashflow, undefined) ->
    [];
make_log_params(cashflow, CashFlow) ->
    Remainders = maps:to_list(hg_cashflow:get_partial_remainders(CashFlow)),
    Accounts = lists:map(
        fun({Account, ?cash(Amount, SymCode)}) ->
            Remainder = [{remainder, [{amount, Amount}, {currency, SymCode}]}],
            {get_account_key(Account), Remainder}
        end,
        Remainders
    ),
    [{accounts, Accounts}];
make_log_params(timings, #st{timings = Timings, sessions = Sessions}) ->
    Params1 = maps:fold(
        fun(N, T, Acc) -> [{hg_utils:join(<<"payment">>, $., N), T} | Acc] end,
        [],
        hg_timings:to_map(Timings)
    ),
    Params2 = maps:fold(
        fun(Target, Ss, Acc) ->
            TargetTimings = hg_timings:merge([hg_session:timings(S) || S <- Ss]),
            maps:fold(
                fun(N, T, Acc1) -> [{hg_utils:join($., [<<"session">>, Target, N]), T} | Acc1] end,
                Acc,
                hg_timings:to_map(TargetTimings)
            )
        end,
        Params1,
        Sessions
    ),
    [{timings, Params2}];
make_log_params(risk_score, Score) ->
    [{risk_score, Score}];
make_log_params(route, _Route) ->
    [];
make_log_params(status, {StatusTag, StatusDetails}) ->
    [{status, StatusTag}] ++ format_status_details(StatusDetails);
make_log_params(event_type, EventType) ->
    [{type, EventType}].

format_status_details(#domain_InvoicePaymentFailed{failure = Failure}) ->
    [{error, list_to_binary(format_failure(Failure))}];
format_status_details(_) ->
    [].

format_failure({operation_timeout, _}) ->
    [<<"timeout">>];
format_failure({failure, Failure}) ->
    format_domain_failure(Failure).

format_domain_failure(Failure) ->
    payproc_errors:format_raw(Failure).

get_account_key({AccountParty, AccountType}) ->
    hg_utils:join(AccountParty, $., AccountType).

get_message(invoice_payment_started) ->
    "Invoice payment is started";
get_message(invoice_payment_risk_score_changed) ->
    "Invoice payment risk score changed";
get_message(invoice_payment_route_changed) ->
    "Invoice payment route changed";
get_message(invoice_payment_cash_flow_changed) ->
    "Invoice payment cash flow changed";
get_message(invoice_payment_status_changed) ->
    "Invoice payment status is changed".

-spec is_route_cascade_available(
    hg_cascade:cascade_behaviour(),
    route(),
    payment_status(),
    st()
) -> boolean().
is_route_cascade_available(
    Behaviour,
    Route,
    ?failed(OperationFailure),
    #st{routes = AttemptedRoutes, sessions = Sessions} = St
) ->
    %% We don't care what type of UserInteraction was initiated, as long as there was none
    SessionsList = lists:flatten(maps:values(Sessions)),
    hg_cascade:is_triggered(Behaviour, OperationFailure, Route, SessionsList) andalso
        %% For cascade viability we require at least one more route candidate
        %% provided by recent routing.
        length(get_candidate_routes(St)) > 1 andalso
        length(AttemptedRoutes) < get_routing_attempt_limit(St).

-spec get_route_cascade_behaviour(route(), hg_domain:revision()) -> hg_cascade:cascade_behaviour().
get_route_cascade_behaviour(Route, Revision) ->
    ProviderRef = get_route_provider(Route),
    #domain_Provider{cascade_behaviour = Behaviour} = hg_domain:get(Revision, {provider, ProviderRef}),
    Behaviour.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("hellgate/test/hg_ct_domain.hrl").

-spec test() -> _.

-spec filter_attempted_routes_test_() -> [_].
filter_attempted_routes_test_() ->
    [R1, R2, R3] = [
        hg_route:new(
            #domain_ProviderRef{id = 171},
            #domain_TerminalRef{id = 307},
            20,
            1000,
            #{client_ip => <<127, 0, 0, 1>>}
        ),
        hg_route:new(
            #domain_ProviderRef{id = 171},
            #domain_TerminalRef{id = 344},
            80,
            1000,
            #{}
        ),
        hg_route:new(
            #domain_ProviderRef{id = 162},
            #domain_TerminalRef{id = 227},
            1,
            2000,
            #{client_ip => undefined}
        )
    ],
    [
        ?_assertMatch(
            #{candidates := []},
            hg_invoice_payment_routing:filter_attempted_routes(
                hg_routing_ctx:new([]),
                #st{
                    activity = idle,
                    routes = [
                        #domain_PaymentRoute{
                            provider = #domain_ProviderRef{id = 162},
                            terminal = #domain_TerminalRef{id = 227}
                        }
                    ]
                }
            )
        ),
        ?_assertMatch(
            #{candidates := []},
            hg_invoice_payment_routing:filter_attempted_routes(hg_routing_ctx:new([]), #st{activity = idle, routes = []})
        ),
        ?_assertMatch(
            #{candidates := [R1, R2, R3]},
            hg_invoice_payment_routing:filter_attempted_routes(hg_routing_ctx:new([R1, R2, R3]), #st{
                activity = idle, routes = []
            })
        ),
        ?_assertMatch(
            #{candidates := [R1, R2]},
            hg_invoice_payment_routing:filter_attempted_routes(
                hg_routing_ctx:new([R1, R2, R3]),
                #st{
                    activity = idle,
                    routes = [
                        #domain_PaymentRoute{
                            provider = #domain_ProviderRef{id = 162},
                            terminal = #domain_TerminalRef{id = 227}
                        }
                    ]
                }
            )
        ),
        ?_assertMatch(
            #{candidates := []},
            hg_invoice_payment_routing:filter_attempted_routes(
                hg_routing_ctx:new([R1, R2, R3]),
                #st{
                    activity = idle,
                    routes = [
                        #domain_PaymentRoute{
                            provider = #domain_ProviderRef{id = 171},
                            terminal = #domain_TerminalRef{id = 307}
                        },
                        #domain_PaymentRoute{
                            provider = #domain_ProviderRef{id = 171},
                            terminal = #domain_TerminalRef{id = 344}
                        },
                        #domain_PaymentRoute{
                            provider = #domain_ProviderRef{id = 162},
                            terminal = #domain_TerminalRef{id = 227}
                        }
                    ]
                }
            )
        )
    ].

-spec shop_limits_regression_test() -> _.
shop_limits_regression_test() ->
    DisposableResource = #domain_DisposablePaymentResource{
        payment_tool =
            {generic, #domain_GenericPaymentTool{
                payment_service = ?pmt_srv(<<"id">>)
            }}
    },
    ContactInfo = #domain_ContactInfo{},
    Payment = #domain_InvoicePayment{
        id = <<"PaymentID">>,
        created_at = <<"Timestamp">>,
        status = ?pending(),
        cost = ?cash(1000, <<"USD">>),
        domain_revision = 1,
        flow = ?invoice_payment_flow_instant(),
        payer = ?payment_resource_payer(DisposableResource, ContactInfo)
    },
    RiskScore = low,
    Route = #domain_PaymentRoute{
        provider = ?prv(1),
        terminal = ?trm(1)
    },
    FinalCashflow = [],
    TransactionInfo = #domain_TransactionInfo{
        id = <<"TransactionID">>,
        extra = #{}
    },
    Events = [
        ?payment_started(Payment),
        ?risk_score_changed(RiskScore),
        ?route_changed(Route),
        ?cash_flow_changed(FinalCashflow),
        hg_session:wrap_event(?processed(), hg_session:create()),
        hg_session:wrap_event(?processed(), ?trx_bound(TransactionInfo)),
        hg_session:wrap_event(?processed(), ?session_finished(?session_succeeded())),
        ?payment_status_changed(?processed())
    ],
    ChangeOpts = #{
        invoice_id => <<"InvoiceID">>
    },
    ?assertMatch(
        #st{},
        collapse_changes(Events, undefined, ChangeOpts)
    ).

-endif.
