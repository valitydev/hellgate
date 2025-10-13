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

%%

-export_type([payment_id/0]).
-export_type([st/0]).
-export_type([activity/0]).
-export_type([machine_result/0]).
-export_type([opts/0]).
-export_type([payment/0]).
-export_type([payment_status/0]).
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
-type adjustment_state() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentState'().
-type adjustment_status_change() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentStatusChange'().
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
-type make_recurrent() :: true | false.
-type retry_strategy() :: hg_retry:strategy().
-type capture_data() :: dmsl_payproc_thrift:'InvoicePaymentCaptureData'().
-type payment_session() :: dmsl_payproc_thrift:'InvoicePaymentSession'().
-type failure() :: dmsl_domain_thrift:'OperationFailure'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type shop_config_ref() :: dmsl_domain_thrift:'ShopConfigRef'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type recurrent_paytool_service_terms() :: dmsl_domain_thrift:'RecurrentPaytoolsServiceTerms'().
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
    merchant_terms => dmsl_domain_thrift:'PaymentsServiceTerms'(),
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
init_(PaymentID, Params, Opts = #{timestamp := CreatedAt}) ->
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

get_merchant_payments_terms(Opts, Revision, _Timestamp, VS) ->
    Shop = get_shop(Opts, Revision),
    TermSet = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS),
    TermSet#domain_TermSet.payments.

-spec get_provider_terminal_terms(route(), hg_varset:varset(), hg_domain:revision()) ->
    dmsl_domain_thrift:'PaymentsProvisionTerms'() | undefined.
get_provider_terminal_terms(?route(ProviderRef, TerminalRef), VS, Revision) ->
    PreparedVS = hg_varset:prepare_varset(VS),
    {Client, Context} = get_party_client(),
    {ok, TermsSet} = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        Revision,
        PreparedVS,
        Client,
        Context
    ),
    TermsSet#domain_ProvisionTermSet.payments.

-spec construct_payer(payer_params()) -> {ok, payer(), map()}.
construct_payer(
    {payment_resource, #payproc_PaymentResourcePayerParams{
        resource = Resource,
        contact_info = ContactInfo
    }}
) ->
    {ok, ?payment_resource_payer(Resource, ContactInfo), #{}};
construct_payer(
    {recurrent, #payproc_RecurrentPayerParams{
        recurrent_parent = Parent,
        contact_info = ContactInfo
    }}
) ->
    ?recurrent_parent(InvoiceID, PaymentID) = Parent,
    ParentPayment =
        try
            get_payment_state(InvoiceID, PaymentID)
        catch
            throw:#payproc_InvoiceNotFound{} ->
                throw_invalid_recurrent_parent(<<"Parent invoice not found">>);
            throw:#payproc_InvoicePaymentNotFound{} ->
                throw_invalid_recurrent_parent(<<"Parent payment not found">>)
        end,
    #domain_InvoicePayment{payer = ParentPayer} = get_payment(ParentPayment),
    ParentPaymentTool = get_payer_payment_tool(ParentPayer),
    {ok, ?recurrent_payer(ParentPaymentTool, Parent, ContactInfo), #{parent_payment => ParentPayment}}.

construct_payment(
    PaymentID,
    CreatedAt,
    Cost,
    Payer,
    FlowParams,
    PartyConfigRef,
    {ShopConfigRef, Shop} = ShopObj,
    VS0,
    Revision,
    MakeRecurrent
) ->
    PaymentTool = get_payer_payment_tool(Payer),
    VS1 = VS0#{
        payment_tool => PaymentTool,
        cost => Cost
    },
    Terms = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS1),
    #domain_TermSet{payments = PaymentTerms, recurrent_paytools = RecurrentTerms} = Terms,
    ok = validate_payment_tool(
        PaymentTool,
        PaymentTerms#domain_PaymentsServiceTerms.payment_methods
    ),
    ok = validate_cash(
        Cost,
        PaymentTerms#domain_PaymentsServiceTerms.cash_limit
    ),
    Flow = construct_payment_flow(
        FlowParams,
        CreatedAt,
        PaymentTerms#domain_PaymentsServiceTerms.holds,
        PaymentTool
    ),
    ParentPayment = maps:get(parent_payment, VS1, undefined),
    ok = validate_recurrent_intention(Payer, RecurrentTerms, PaymentTool, ShopObj, ParentPayment, MakeRecurrent),
    #domain_InvoicePayment{
        id = PaymentID,
        created_at = CreatedAt,
        party_ref = PartyConfigRef,
        shop_ref = ShopConfigRef,
        domain_revision = Revision,
        status = ?pending(),
        cost = Cost,
        payer = Payer,
        flow = Flow,
        make_recurrent = MakeRecurrent,
        registration_origin = ?invoice_payment_merchant_reg_origin()
    }.

construct_payment_flow({instant, _}, _CreatedAt, _Terms, _PaymentTool) ->
    ?invoice_payment_flow_instant();
construct_payment_flow({hold, Params}, CreatedAt, Terms, PaymentTool) ->
    OnHoldExpiration = Params#payproc_InvoicePaymentParamsFlowHold.on_hold_expiration,
    ?hold_lifetime(Seconds) = validate_hold_lifetime(Terms, PaymentTool),
    HeldUntil = hg_datetime:format_ts(hg_datetime:parse_ts(CreatedAt) + Seconds),
    ?invoice_payment_flow_hold(OnHoldExpiration, HeldUntil).

reconstruct_payment_flow(Payment, VS) ->
    #domain_InvoicePayment{
        flow = Flow,
        created_at = CreatedAt
    } = Payment,
    reconstruct_payment_flow(Flow, CreatedAt, VS).

reconstruct_payment_flow(?invoice_payment_flow_instant(), _CreatedAt, VS) ->
    VS#{flow => instant};
reconstruct_payment_flow(?invoice_payment_flow_hold(_OnHoldExpiration, HeldUntil), CreatedAt, VS) ->
    Seconds = hg_datetime:parse_ts(HeldUntil) - hg_datetime:parse_ts(CreatedAt),
    VS#{flow => {hold, ?hold_lifetime(Seconds)}}.

-spec get_predefined_route(payer()) -> {ok, route()} | undefined.
get_predefined_route(?payment_resource_payer()) ->
    undefined;
get_predefined_route(?recurrent_payer() = Payer) ->
    get_predefined_recurrent_route(Payer).

-spec get_predefined_recurrent_route(payer()) -> {ok, route()}.
get_predefined_recurrent_route(?recurrent_payer(_, ?recurrent_parent(InvoiceID, PaymentID), _)) ->
    PreviousPayment = get_payment_state(InvoiceID, PaymentID),
    {ok, get_route(PreviousPayment)}.

validate_hold_lifetime(
    #domain_PaymentHoldsServiceTerms{
        payment_methods = PMs,
        lifetime = LifetimeSelector
    },
    PaymentTool
) ->
    ok = validate_payment_tool(PaymentTool, PMs),
    get_selector_value(hold_lifetime, LifetimeSelector);
validate_hold_lifetime(undefined, _PaymentTool) ->
    throw_invalid_request(<<"Holds are not available">>).

-spec validate_recurrent_intention(
    payer(),
    recurrent_paytool_service_terms(),
    payment_tool(),
    {shop_config_ref(), shop()},
    payment(),
    make_recurrent()
) -> ok | no_return().
validate_recurrent_intention(
    ?recurrent_payer() = Payer,
    RecurrentTerms,
    PaymentTool,
    ShopObj,
    ParentPayment,
    MakeRecurrent
) ->
    ok = validate_recurrent_terms(RecurrentTerms, PaymentTool),
    ok = validate_recurrent_payer(Payer, MakeRecurrent),
    ok = validate_recurrent_parent(ShopObj, ParentPayment);
validate_recurrent_intention(Payer, RecurrentTerms, PaymentTool, _Shop, _ParentPayment, true = MakeRecurrent) ->
    ok = validate_recurrent_terms(RecurrentTerms, PaymentTool),
    ok = validate_recurrent_payer(Payer, MakeRecurrent);
validate_recurrent_intention(_Payer, _RecurrentTerms, _PaymentTool, _Shop, _ParentPayment, false = _MakeRecurrent) ->
    ok.

-spec validate_recurrent_terms(recurrent_paytool_service_terms(), payment_tool()) -> ok | no_return().
validate_recurrent_terms(undefined, _PaymentTool) ->
    throw(#payproc_OperationNotPermitted{});
validate_recurrent_terms(RecurrentTerms, PaymentTool) ->
    #domain_RecurrentPaytoolsServiceTerms{payment_methods = PaymentMethodSelector} = RecurrentTerms,
    PMs = get_selector_value(recurrent_payment_methods, PaymentMethodSelector),
    % _ =
    %     hg_payment_tool:has_any_payment_method(PaymentTool, PMs) orelse
    %         throw_invalid_request(<<"Invalid payment method">>),
    %% TODO delete logging after successfull migration tokenization method in domain_config
    %% https://rbkmoney.atlassian.net/browse/ED-87
    _ =
        case hg_payment_tool:has_any_payment_method(PaymentTool, PMs) of
            false ->
                logger:notice("PaymentTool: ~p", [PaymentTool]),
                logger:notice("RecurrentPaymentMethods: ~p", [PMs]),
                throw_invalid_request(<<"Invalid payment method">>);
            true ->
                ok
        end,
    ok.

-spec validate_recurrent_parent({shop_config_ref(), shop()}, st()) -> ok | no_return().
validate_recurrent_parent(ShopObj, ParentPayment) ->
    ok = validate_recurrent_token_present(ParentPayment),
    ok = validate_recurrent_parent_shop(ShopObj, ParentPayment),
    ok = validate_recurrent_parent_status(ParentPayment).

-spec validate_recurrent_token_present(st()) -> ok | no_return().
validate_recurrent_token_present(PaymentState) ->
    case get_recurrent_token(PaymentState) of
        Token when Token =/= undefined ->
            ok;
        undefined ->
            throw_invalid_recurrent_parent(<<"Parent payment has no recurrent token">>)
    end.

-spec validate_recurrent_parent_shop({shop_config_ref(), shop()}, st()) -> ok | no_return().
validate_recurrent_parent_shop({ShopConfigRef, _}, PaymentState) ->
    PaymentShopConfigRef = get_payment_shop_config_ref(get_payment(PaymentState)),
    case ShopConfigRef =:= PaymentShopConfigRef of
        true ->
            ok;
        false ->
            throw_invalid_recurrent_parent(<<"Parent payment refer to another shop">>)
    end.

-spec validate_recurrent_parent_status(st()) -> ok | no_return().
validate_recurrent_parent_status(PaymentState) ->
    case get_payment(PaymentState) of
        #domain_InvoicePayment{status = {failed, _}} ->
            throw_invalid_recurrent_parent(<<"Invalid parent payment status">>);
        _Other ->
            ok
    end.

-spec validate_recurrent_payer(dmsl_domain_thrift:'Payer'(), make_recurrent()) -> ok | no_return().
validate_recurrent_payer(?recurrent_payer(), _MakeRecurrent) ->
    ok;
validate_recurrent_payer(?payment_resource_payer(), true) ->
    ok;
validate_recurrent_payer(_OtherPayer, true) ->
    throw_invalid_request(<<"Invalid payer">>).

validate_payment_tool(PaymentTool, PaymentMethodSelector) ->
    PMs = get_selector_value(payment_methods, PaymentMethodSelector),
    _ =
        case hg_payment_tool:has_any_payment_method(PaymentTool, PMs) of
            false ->
                throw_invalid_request(<<"Invalid payment method">>);
            true ->
                ok
        end,
    ok.

validate_cash(Cash, CashLimitSelector) ->
    Limit = get_selector_value(cash_limit, CashLimitSelector),
    ok = validate_limit(Cash, Limit).

validate_limit(Cash, CashRange) ->
    case hg_cash_range:is_inside(Cash, CashRange) of
        within ->
            ok;
        {exceeds, lower} ->
            throw_invalid_request(<<"Invalid amount, less than allowed minumum">>);
        {exceeds, upper} ->
            throw_invalid_request(<<"Invalid amount, more than allowed maximum">>)
    end.

gather_routes(PaymentInstitution, VS, Revision, St) ->
    Payment = get_payment(St),
    Predestination = choose_routing_predestination(Payment),
    #domain_Cash{currency = Currency} = get_payment_cost(Payment),
    Payer = Payment#domain_InvoicePayment.payer,
    #domain_ContactInfo{email = Email} = get_contact_info(Payer),
    CardToken = get_payer_card_token(Payer),
    PaymentTool = get_payer_payment_tool(Payer),
    ClientIP = get_payer_client_ip(Payer),
    hg_routing:gather_routes(Predestination, PaymentInstitution, VS, Revision, #{
        currency => Currency,
        payment_tool => PaymentTool,
        client_ip => ClientIP,
        email => Email,
        card_token => CardToken
    }).

-spec check_risk_score(risk_score()) -> ok | {error, risk_score_is_too_high}.
check_risk_score(fatal) ->
    {error, risk_score_is_too_high};
check_risk_score(_RiskScore) ->
    ok.

-spec choose_routing_predestination(payment()) -> hg_routing:route_predestination().
choose_routing_predestination(#domain_InvoicePayment{make_recurrent = true}) ->
    recurrent_payment;
choose_routing_predestination(#domain_InvoicePayment{payer = ?payment_resource_payer()}) ->
    payment.

% Other payers has predefined routes

log_route_choice_meta(#{choice_meta := undefined}, _Revision) ->
    ok;
log_route_choice_meta(#{choice_meta := ChoiceMeta}, Revision) ->
    Metadata = hg_routing:get_logger_metadata(ChoiceMeta, Revision),
    logger:log(notice, "Routing decision made", #{routing => Metadata}).

maybe_log_misconfigurations({misconfiguration, _} = Error) ->
    {Format, Details} = hg_routing:prepare_log_message(Error),
    ?LOG_MD(warning, Format, Details);
maybe_log_misconfigurations(_Error) ->
    ok.

log_rejected_routes(_, [], _VS) ->
    ok;
log_rejected_routes(all, Routes, VS) ->
    ?LOG_MD(warning, "No route found for varset: ~p", [VS]),
    ?LOG_MD(warning, "No route found, rejected routes: ~p", [Routes]);
log_rejected_routes(limit_misconfiguration, Routes, _VS) ->
    ?LOG_MD(warning, "Limiter hold error caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(limit_overflow, Routes, _VS) ->
    ?LOG_MD(notice, "Limit overflow caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(in_blacklist, Routes, _VS) ->
    ?LOG_MD(notice, "Route candidates are blacklisted: ~p", [Routes]);
log_rejected_routes(adapter_unavailable, Routes, _VS) ->
    ?LOG_MD(notice, "Adapter unavailability caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(provider_conversion_is_too_low, Routes, _VS) ->
    ?LOG_MD(notice, "Lacking conversion of provider caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(forbidden, Routes, VS) ->
    ?LOG_MD(notice, "Rejected routes found for varset: ~p", [VS]),
    ?LOG_MD(notice, "Rejected routes found, rejected routes: ~p", [Routes]);
log_rejected_routes(_, _Routes, _VS) ->
    ok.

validate_refund_time(RefundCreatedAt, PaymentCreatedAt, TimeSpanSelector) ->
    EligibilityTime = get_selector_value(eligibility_time, TimeSpanSelector),
    RefundEndTime = hg_datetime:add_time_span(EligibilityTime, PaymentCreatedAt),
    case hg_datetime:compare(RefundCreatedAt, RefundEndTime) of
        Result when Result == earlier; Result == simultaneously ->
            ok;
        later ->
            throw(#payproc_OperationNotPermitted{})
    end.

collect_chargeback_varset(
    #domain_PaymentChargebackServiceTerms{},
    VS
) ->
    % nothing here yet
    VS;
collect_chargeback_varset(undefined, VS) ->
    VS.

collect_refund_varset(
    #domain_PaymentRefundsServiceTerms{
        payment_methods = PaymentMethodSelector,
        partial_refunds = PartialRefundsServiceTerms
    },
    PaymentTool,
    VS
) ->
    RPMs = get_selector_value(payment_methods, PaymentMethodSelector),
    case hg_payment_tool:has_any_payment_method(PaymentTool, RPMs) of
        true ->
            RVS = collect_partial_refund_varset(PartialRefundsServiceTerms),
            VS#{refunds => RVS};
        false ->
            VS
    end;
collect_refund_varset(undefined, _PaymentTool, VS) ->
    VS.

collect_partial_refund_varset(
    #domain_PartialRefundsServiceTerms{
        cash_limit = CashLimitSelector
    }
) ->
    #{
        partial => #{
            cash_limit => get_selector_value(cash_limit, CashLimitSelector)
        }
    };
collect_partial_refund_varset(undefined) ->
    #{}.

collect_validation_varset(St, Opts) ->
    Revision = get_payment_revision(St),
    collect_validation_varset(get_party_config_ref(Opts), get_shop_obj(Opts, Revision), get_payment(St), #{}).

collect_validation_varset(PartyConfigRef, ShopObj, Payment, VS) ->
    Cost = #domain_Cash{currency = Currency} = get_payment_cost(Payment),
    VS0 = collect_validation_varset_(PartyConfigRef, ShopObj, Currency, VS),
    VS0#{
        cost => Cost,
        payment_tool => get_payment_tool(Payment)
    }.

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
construct_payment_plan_id(St = #st{opts = Opts, payment = Payment}) ->
    Iter = get_iter(St),
    construct_payment_plan_id(get_invoice(Opts), Payment, Iter, normal).

-spec construct_payment_plan_id(st(), legacy | normal) -> payment_plan_id().
construct_payment_plan_id(St = #st{opts = Opts, payment = Payment}, Mode) ->
    Iter = get_iter(St),
    construct_payment_plan_id(get_invoice(Opts), Payment, Iter, Mode).

construct_payment_plan_id(Invoice, Payment, _Iter, legacy) ->
    hg_utils:construct_complex_id([
        get_invoice_id(Invoice),
        get_payment_id(Payment)
    ]);
construct_payment_plan_id(Invoice, Payment, Iter, _Mode) ->
    hg_utils:construct_complex_id([
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        integer_to_binary(Iter)
    ]).

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

%%

-spec start_session(target()) -> events().
start_session(Target) ->
    [hg_session:wrap_event(Target, hg_session:create())].

start_capture(Reason, Cost, Cart, Allocation) ->
    [?payment_capture_started(Reason, Cost, Cart, Allocation)] ++
        start_session(?captured(Reason, Cost, Cart, Allocation)).

start_partial_capture(Reason, Cost, Cart, FinalCashflow, Allocation) ->
    [
        ?payment_capture_started(Reason, Cost, Cart, Allocation),
        ?cash_flow_changed(FinalCashflow)
    ].

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
    case
        hg_allocation:calculate(
            AllocationPrototype,
            Party,
            Shop,
            Cost,
            AllocationSelector
        )
    of
        {error, allocation_not_allowed} ->
            throw(#payproc_AllocationNotAllowed{})
    end.

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

assert_capture_cost_currency(undefined, _) ->
    ok;
assert_capture_cost_currency(?cash(_, SymCode), #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    ok;
assert_capture_cost_currency(?cash(_, PassedSymCode), #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    throw(#payproc_InconsistentCaptureCurrency{
        payment_currency = SymCode,
        passed_currency = PassedSymCode
    }).

validate_processing_deadline(#domain_InvoicePayment{processing_deadline = Deadline}, _TargetType = processed) ->
    case hg_invoice_utils:check_deadline(Deadline) of
        ok ->
            ok;
        {error, deadline_reached} ->
            {failure,
                payproc_errors:construct(
                    'PaymentFailure',
                    {authorization_failed, {processing_deadline_reached, #payproc_error_GeneralFailure{}}}
                )}
    end;
validate_processing_deadline(_, _TargetType) ->
    ok.

assert_capture_cart(_Cost, undefined) ->
    ok;
assert_capture_cart(Cost, Cart) ->
    case Cost =:= hg_invoice_utils:get_cart_amount(Cart) of
        true ->
            ok;
        _ ->
            throw_invalid_request(<<"Capture amount does not match with the cart total amount">>)
    end.

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

validate_merchant_hold_terms(#domain_PaymentsServiceTerms{holds = Terms}) when Terms /= undefined ->
    case Terms of
        %% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
        #domain_PaymentHoldsServiceTerms{partial_captures = undefined} ->
            ok;
        #domain_PaymentHoldsServiceTerms{} ->
            throw(#payproc_OperationNotPermitted{})
    end;
%% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
validate_merchant_hold_terms(#domain_PaymentsServiceTerms{holds = undefined}) ->
    ok.

validate_provider_holds_terms(#domain_PaymentsProvisionTerms{holds = Terms}) when Terms /= undefined ->
    case Terms of
        %% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
        #domain_PaymentHoldsProvisionTerms{partial_captures = undefined} ->
            ok;
        #domain_PaymentHoldsProvisionTerms{} ->
            throw(#payproc_OperationNotPermitted{})
    end;
%% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
validate_provider_holds_terms(#domain_PaymentsProvisionTerms{holds = undefined}) ->
    ok.

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

validate_payment_status(Status, #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
validate_payment_status(_, #domain_InvoicePayment{status = Status}) ->
    throw(#payproc_InvalidPaymentStatus{status = Status}).

-spec refund(refund_params(), st(), opts()) -> {domain_refund(), result()}.
refund(Params, St0, Opts = #{timestamp := CreatedAt}) ->
    St = St0#st{opts = Opts},
    Revision = hg_domain:head(),
    Payment = get_payment(St),
    VS = collect_validation_varset(St, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS),
    Refund = make_refund(Params, Payment, Revision, CreatedAt, St, Opts),
    FinalCashflow = make_refund_cashflow(Refund, Payment, Revision, St, Opts, MerchantTerms, VS, CreatedAt),
    Changes = hg_invoice_payment_refund:create(#{
        refund => Refund,
        cash_flow => FinalCashflow
    }),
    {Refund, {Changes, hg_machine_action:instant()}}.

-spec manual_refund(refund_params(), st(), opts()) -> {domain_refund(), result()}.
manual_refund(Params, St0, Opts = #{timestamp := CreatedAt}) ->
    St = St0#st{opts = Opts},
    Revision = hg_domain:head(),
    Payment = get_payment(St),
    VS = collect_validation_varset(St, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS),
    Refund = make_refund(Params, Payment, Revision, CreatedAt, St, Opts),
    FinalCashflow = make_refund_cashflow(Refund, Payment, Revision, St, Opts, MerchantTerms, VS, CreatedAt),
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

validate_allocation_refund(undefined, _St) ->
    ok.

make_refund_cashflow(Refund, Payment, Revision, St, Opts, MerchantTerms, VS, Timestamp) ->
    Route = get_route(St),
    ProviderPaymentsTerms = get_provider_terminal_terms(Route, VS, Revision),
    Allocation = Refund#domain_InvoicePaymentRefund.allocation,
    CollectCashflowContext = genlib_map:compact(#{
        operation => refund,
        provision_terms => get_provider_refunds_terms(ProviderPaymentsTerms, Refund, Payment),
        merchant_terms => MerchantTerms,
        party => get_party_obj(Opts),
        shop => get_shop_obj(Opts, Revision),
        route => Route,
        payment => Payment,
        provider => get_route_provider(Route, Revision),
        timestamp => Timestamp,
        varset => VS,
        revision => Revision,
        refund => Refund,
        allocation => Allocation
    }),
    hg_cashflow_utils:collect_cashflow(CollectCashflowContext).

assert_refund_cash(Cash, St) ->
    PaymentAmount = get_remaining_payment_amount(Cash, St),
    assert_remaining_payment_amount(PaymentAmount, St).

assert_remaining_payment_amount(?cash(Amount, _), _St) when Amount >= 0 ->
    ok;
assert_remaining_payment_amount(?cash(Amount, _), St) when Amount < 0 ->
    Maximum = get_remaining_payment_balance(St),
    throw(#payproc_InvoicePaymentAmountExceeded{maximum = Maximum}).

assert_previous_refunds_finished(St) ->
    PendingRefunds = lists:filter(
        fun(#payproc_InvoicePaymentRefund{refund = R}) ->
            R#domain_InvoicePaymentRefund.status =:= ?refund_pending()
        end,
        get_refunds(St)
    ),
    case PendingRefunds of
        [] ->
            ok;
        [_R | _] ->
            throw(#payproc_OperationNotPermitted{})
    end.

assert_refund_cart(_RefundCash, undefined, _St) ->
    ok;
assert_refund_cart(undefined, _Cart, _St) ->
    throw_invalid_request(<<"Refund amount does not match with the cart total amount">>);
assert_refund_cart(RefundCash, Cart, St) ->
    InterimPaymentAmount = get_remaining_payment_balance(St),
    case hg_cash:sub(InterimPaymentAmount, RefundCash) =:= hg_invoice_utils:get_cart_amount(Cart) of
        true ->
            ok;
        _ ->
            throw_invalid_request(<<"Remaining payment amount not equal cart cost">>)
    end.

get_remaining_payment_amount(Cash, St) ->
    InterimPaymentAmount = get_remaining_payment_balance(St),
    hg_cash:sub(InterimPaymentAmount, Cash).

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
            (CB = #domain_InvoicePaymentChargeback{}, Acc) ->
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
    Terms;
get_merchant_refunds_terms(#domain_PaymentsServiceTerms{refunds = undefined}) ->
    throw(#payproc_OperationNotPermitted{}).

get_provider_refunds_terms(
    #domain_PaymentsProvisionTerms{refunds = Terms},
    Refund,
    Payment
) when Terms /= undefined ->
    Cost = get_payment_cost(Payment),
    Cash = get_refund_cash(Refund),
    case hg_cash:sub(Cost, Cash) of
        ?cash(0, _) ->
            Terms;
        ?cash(Amount, _) when Amount > 0 ->
            get_provider_partial_refunds_terms(Terms, Refund, Payment)
    end;
get_provider_refunds_terms(#domain_PaymentsProvisionTerms{refunds = undefined}, _Refund, Payment) ->
    error({misconfiguration, {'No refund terms for a payment', Payment}}).

get_provider_partial_refunds_terms(
    #domain_PaymentRefundsProvisionTerms{
        partial_refunds = #domain_PartialRefundsProvisionTerms{
            cash_limit = CashLimitSelector
        }
    } = Terms,
    Refund,
    _Payment
) ->
    Cash = get_refund_cash(Refund),
    CashRange = get_selector_value(cash_limit, CashLimitSelector),
    case hg_cash_range:is_inside(Cash, CashRange) of
        within ->
            Terms;
        {exceeds, _} ->
            error({misconfiguration, {'Refund amount doesnt match allowed cash range', CashRange}})
    end;
get_provider_partial_refunds_terms(
    #domain_PaymentRefundsProvisionTerms{partial_refunds = undefined},
    _Refund,
    Payment
) ->
    error({misconfiguration, {'No partial refund terms for a payment', Payment}}).

validate_refund(Terms, Refund, Payment) ->
    Cost = get_payment_cost(Payment),
    Cash = get_refund_cash(Refund),
    case hg_cash:sub(Cost, Cash) of
        ?cash(0, _) ->
            validate_common_refund_terms(Terms, Refund, Payment);
        ?cash(Amount, _) when Amount > 0 ->
            validate_partial_refund(Terms, Refund, Payment)
    end.

validate_partial_refund(
    #domain_PaymentRefundsServiceTerms{partial_refunds = PRs} = Terms,
    Refund,
    Payment
) when PRs /= undefined ->
    ok = validate_common_refund_terms(Terms, Refund, Payment),
    ok = validate_cash(
        get_refund_cash(Refund),
        PRs#domain_PartialRefundsServiceTerms.cash_limit
    ),
    ok;
validate_partial_refund(
    #domain_PaymentRefundsServiceTerms{partial_refunds = undefined},
    _Refund,
    _Payment
) ->
    throw(#payproc_OperationNotPermitted{}).

validate_common_refund_terms(Terms, Refund, Payment) ->
    ok = validate_payment_tool(
        get_payment_tool(Payment),
        Terms#domain_PaymentRefundsServiceTerms.payment_methods
    ),
    ok = validate_refund_time(
        get_refund_created_at(Refund),
        get_payment_created_at(Payment),
        Terms#domain_PaymentRefundsServiceTerms.eligibility_time
    ),
    ok.

%%

-spec create_adjustment(hg_datetime:timestamp(), adjustment_params(), st(), opts()) -> {adjustment(), result()}.
create_adjustment(Timestamp, Params, St, Opts) ->
    _ = assert_no_adjustment_pending(St),
    case Params#payproc_InvoicePaymentAdjustmentParams.scenario of
        {cash_flow, #domain_InvoicePaymentAdjustmentCashFlow{domain_revision = DomainRevision}} ->
            create_cash_flow_adjustment(Timestamp, Params, DomainRevision, St, Opts);
        {status_change, Change} ->
            create_status_adjustment(Timestamp, Params, Change, St, Opts)
    end.

-spec create_cash_flow_adjustment(
    hg_datetime:timestamp(),
    adjustment_params(),
    undefined | hg_domain:revision(),
    st(),
    opts()
) -> {adjustment(), result()}.
create_cash_flow_adjustment(Timestamp, Params, DomainRevision, St, Opts) ->
    Payment = get_payment(St),
    Route = get_route(St),
    _ = assert_payment_status([captured, refunded, charged_back, failed], Payment),
    NewRevision = maybe_get_domain_revision(DomainRevision),
    OldCashFlow = get_final_cashflow(St),
    VS = collect_validation_varset(St, Opts),
    Allocation = get_allocation(St),
    {Payment1, AdditionalEvents} = maybe_inject_new_cost_amount(
        Payment, Params#payproc_InvoicePaymentAdjustmentParams.scenario
    ),
    Context = #{
        provision_terms => get_provider_terminal_terms(Route, VS, NewRevision),
        route => Route,
        payment => Payment1,
        timestamp => Timestamp,
        varset => VS,
        revision => NewRevision,
        allocation => Allocation
    },
    NewCashFlow =
        case Payment of
            #domain_InvoicePayment{status = {failed, _}} ->
                [];
            _ ->
                calculate_cashflow(Context, Opts)
        end,
    AdjState =
        {cash_flow, #domain_InvoicePaymentAdjustmentCashFlowState{
            scenario = #domain_InvoicePaymentAdjustmentCashFlow{domain_revision = DomainRevision}
        }},
    construct_adjustment(
        Timestamp,
        Params,
        NewRevision,
        OldCashFlow,
        NewCashFlow,
        AdjState,
        AdditionalEvents,
        St
    ).

maybe_inject_new_cost_amount(
    Payment,
    {'cash_flow', #domain_InvoicePaymentAdjustmentCashFlow{new_amount = NewAmount}}
) when NewAmount =/= undefined ->
    OldCost = get_payment_cost(Payment),
    NewCost = OldCost#domain_Cash{amount = NewAmount},
    Payment1 = Payment#domain_InvoicePayment{cost = NewCost},
    {Payment1, [?cash_changed(OldCost, NewCost)]};
maybe_inject_new_cost_amount(Payment, _AdjustmentScenario) ->
    {Payment, []}.

-spec create_status_adjustment(
    hg_datetime:timestamp(),
    adjustment_params(),
    adjustment_status_change(),
    st(),
    opts()
) -> {adjustment(), result()}.
create_status_adjustment(Timestamp, Params, Change, St, Opts) ->
    #domain_InvoicePaymentAdjustmentStatusChange{
        target_status = TargetStatus
    } = Change,
    #domain_InvoicePayment{
        status = Status,
        domain_revision = DomainRevision
    } = get_payment(St),
    ok = assert_adjustment_payment_status(Status),
    ok = assert_no_refunds(St),
    ok = assert_adjustment_payment_statuses(TargetStatus, Status),
    OldCashFlow = get_cash_flow_for_status(Status, St),
    NewCashFlow = get_cash_flow_for_target_status(TargetStatus, St, Opts),
    AdjState =
        {status_change, #domain_InvoicePaymentAdjustmentStatusChangeState{
            scenario = Change
        }},
    construct_adjustment(
        Timestamp,
        Params,
        DomainRevision,
        OldCashFlow,
        NewCashFlow,
        AdjState,
        [],
        St
    ).

-spec maybe_get_domain_revision(undefined | hg_domain:revision()) -> hg_domain:revision().
maybe_get_domain_revision(undefined) ->
    hg_domain:head();
maybe_get_domain_revision(DomainRevision) ->
    DomainRevision.

-spec assert_adjustment_payment_status(payment_status()) -> ok | no_return().
assert_adjustment_payment_status(Status) ->
    case is_adjustment_payment_status_final(Status) of
        true ->
            ok;
        false ->
            erlang:throw(#payproc_InvalidPaymentStatus{status = Status})
    end.

assert_no_refunds(St) ->
    case get_refunds_count(St) of
        0 ->
            ok;
        _ ->
            throw_invalid_request(<<"Cannot change status of payment with refunds.">>)
    end.

-spec assert_adjustment_payment_statuses(TargetStatus :: payment_status(), Status :: payment_status()) ->
    ok | no_return().
assert_adjustment_payment_statuses(Status, Status) ->
    erlang:throw(#payproc_InvoicePaymentAlreadyHasStatus{status = Status});
assert_adjustment_payment_statuses(TargetStatus, _Status) ->
    case is_adjustment_payment_status_final(TargetStatus) of
        true ->
            ok;
        false ->
            erlang:throw(#payproc_InvalidPaymentTargetStatus{status = TargetStatus})
    end.

-spec is_adjustment_payment_status_final(payment_status()) -> boolean().
is_adjustment_payment_status_final({captured, _}) ->
    true;
is_adjustment_payment_status_final({cancelled, _}) ->
    true;
is_adjustment_payment_status_final({failed, _}) ->
    true;
is_adjustment_payment_status_final(_) ->
    false.

-spec get_cash_flow_for_status(payment_status(), st()) -> final_cash_flow().
get_cash_flow_for_status({captured, _}, St) ->
    get_final_cashflow(St);
get_cash_flow_for_status({cancelled, _}, _St) ->
    [];
get_cash_flow_for_status({failed, _}, _St) ->
    [].

-spec get_cash_flow_for_target_status(payment_status(), st(), opts()) -> final_cash_flow().
get_cash_flow_for_target_status({captured, Captured}, St0, Opts) ->
    Payment0 = get_payment(St0),
    Route = get_route(St0),
    Cost = get_captured_cost(Captured, Payment0),
    Allocation = get_captured_allocation(Captured),
    Payment1 = Payment0#domain_InvoicePayment{
        cost = Cost
    },
    Payment2 =
        case Payment1 of
            #domain_InvoicePayment{changed_cost = ChangedCost} when ChangedCost =/= undefined ->
                Payment1#domain_InvoicePayment{
                    cost = ChangedCost
                };
            _ ->
                Payment1
        end,
    Timestamp = get_payment_created_at(Payment2),
    St = St0#st{payment = Payment2},
    Revision = Payment2#domain_InvoicePayment.domain_revision,
    VS = collect_validation_varset(St, Opts),
    Context = #{
        provision_terms => get_provider_terminal_terms(Route, VS, Revision),
        route => Route,
        payment => Payment2,
        timestamp => Timestamp,
        varset => VS,
        revision => Revision,
        allocation => Allocation
    },
    calculate_cashflow(Context, Opts);
get_cash_flow_for_target_status({cancelled, _}, _St, _Opts) ->
    [];
get_cash_flow_for_target_status({failed, _}, _St, _Opts) ->
    [].

-spec calculate_cashflow(cashflow_context(), opts()) -> final_cash_flow().
calculate_cashflow(Context = #{route := Route, revision := Revision}, Opts) ->
    CollectCashflowContext = genlib_map:compact(Context#{
        operation => payment,
        party => get_party_obj(Opts),
        shop => get_shop_obj(Opts, Revision),
        provider => get_route_provider(Route, Revision)
    }),
    hg_cashflow_utils:collect_cashflow(CollectCashflowContext).

-spec calculate_cashflow(hg_payment_institution:t(), cashflow_context(), opts()) -> final_cash_flow().
calculate_cashflow(PaymentInstitution, Context = #{route := Route, revision := Revision}, Opts) ->
    CollectCashflowContext = genlib_map:compact(Context#{
        operation => payment,
        party => get_party_obj(Opts),
        shop => get_shop_obj(Opts, Revision),
        provider => get_route_provider(Route, Revision)
    }),
    hg_cashflow_utils:collect_cashflow(PaymentInstitution, CollectCashflowContext).

-spec construct_adjustment(
    Timestamp :: hg_datetime:timestamp(),
    Params :: adjustment_params(),
    DomainRevision :: hg_domain:revision(),
    OldCashFlow :: final_cash_flow(),
    NewCashFlow :: final_cash_flow(),
    State :: adjustment_state(),
    AdditionalEvents :: events(),
    St :: st()
) -> {adjustment(), result()}.
construct_adjustment(
    Timestamp,
    Params,
    DomainRevision,
    OldCashFlow,
    NewCashFlow,
    State,
    AdditionalEvents,
    St
) ->
    ID = construct_adjustment_id(St),
    Adjustment = #domain_InvoicePaymentAdjustment{
        id = ID,
        status = ?adjustment_pending(),
        created_at = Timestamp,
        domain_revision = DomainRevision,
        reason = Params#payproc_InvoicePaymentAdjustmentParams.reason,
        old_cash_flow_inverse = hg_cashflow:revert(OldCashFlow),
        new_cash_flow = NewCashFlow,
        state = State
    },
    Events = [?adjustment_ev(ID, ?adjustment_created(Adjustment)) | AdditionalEvents],
    {Adjustment, {Events, hg_machine_action:instant()}}.

construct_adjustment_id(#st{adjustments = As}) ->
    erlang:integer_to_binary(length(As) + 1).

-spec assert_activity(activity(), st()) -> ok | no_return().
assert_activity(Activity, #st{activity = Activity}) ->
    ok;
assert_activity(_Activity, St) ->
    %% TODO: Create dedicated error like "Payment is capturing already"
    #domain_InvoicePayment{status = Status} = get_payment(St),
    throw(#payproc_InvalidPaymentStatus{status = Status}).

assert_payment_status([Status | _], #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
assert_payment_status([_ | Rest], InvoicePayment) ->
    assert_payment_status(Rest, InvoicePayment);
assert_payment_status(Status, #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
assert_payment_status(_, #domain_InvoicePayment{status = Status}) ->
    throw(#payproc_InvalidPaymentStatus{status = Status}).

assert_no_pending_chargebacks(PaymentState) ->
    Chargebacks = [CB#payproc_InvoicePaymentChargeback.chargeback || CB <- get_chargebacks(PaymentState)],
    case lists:any(fun hg_invoice_payment_chargeback:is_pending/1, Chargebacks) of
        true ->
            throw(#payproc_InvoicePaymentChargebackPending{});
        false ->
            ok
    end.

assert_no_adjustment_pending(#st{adjustments = As}) ->
    lists:foreach(fun assert_adjustment_finalized/1, As).

assert_adjustment_finalized(#domain_InvoicePaymentAdjustment{id = ID, status = {Status, _}}) when
    Status =:= pending; Status =:= processed
->
    throw(#payproc_InvoicePaymentAdjustmentPending{id = ID});
assert_adjustment_finalized(_) ->
    ok.

assert_payment_flow(hold, #domain_InvoicePayment{flow = ?invoice_payment_flow_hold(_, _)}) ->
    ok;
assert_payment_flow(_, _) ->
    throw(#payproc_OperationNotPermitted{}).

-spec process_adjustment_capture(adjustment_id(), action(), st()) -> machine_result().
process_adjustment_capture(ID, _Action, St) ->
    Opts = get_opts(St),
    Adjustment = get_adjustment(ID, St),
    ok = assert_adjustment_status(processed, Adjustment),
    ok = finalize_adjustment_cashflow(Adjustment, St, Opts),
    Status = ?adjustment_captured(maps:get(timestamp, Opts)),
    Event = ?adjustment_ev(ID, ?adjustment_status_changed(Status)),
    {done, {[Event], hg_machine_action:new()}}.

prepare_adjustment_cashflow(Adjustment, St, Options) ->
    PlanID = construct_adjustment_plan_id(Adjustment, St, Options),
    Plan = get_adjustment_cashflow_plan(Adjustment),
    plan(PlanID, Plan).

finalize_adjustment_cashflow(Adjustment, St, Options) ->
    PlanID = construct_adjustment_plan_id(Adjustment, St, Options),
    Plan = get_adjustment_cashflow_plan(Adjustment),
    commit(PlanID, Plan).

get_adjustment_cashflow_plan(#domain_InvoicePaymentAdjustment{
    old_cash_flow_inverse = CashflowInverse,
    new_cash_flow = Cashflow
}) ->
    number_plan([CashflowInverse, Cashflow], 1, []).

number_plan([], _Number, Acc) ->
    lists:reverse(Acc);
number_plan([[] | Tail], Number, Acc) ->
    number_plan(Tail, Number, Acc);
number_plan([NonEmpty | Tail], Number, Acc) ->
    number_plan(Tail, Number + 1, [{Number, NonEmpty} | Acc]).

plan(_PlanID, []) ->
    ok;
plan(PlanID, Plan) ->
    _ = hg_accounting:plan(PlanID, Plan),
    ok.

commit(_PlanID, []) ->
    ok;
commit(PlanID, Plan) ->
    _ = hg_accounting:commit(PlanID, Plan),
    ok.

assert_adjustment_status(Status, #domain_InvoicePaymentAdjustment{status = {Status, _}}) ->
    ok;
assert_adjustment_status(_, #domain_InvoicePaymentAdjustment{status = Status}) ->
    throw(#payproc_InvalidPaymentAdjustmentStatus{status = Status}).

construct_adjustment_plan_id(Adjustment, St, Options) ->
    hg_utils:construct_complex_id([
        get_invoice_id(get_invoice(Options)),
        get_payment_id(get_payment(St)),
        {adj, get_adjustment_id(Adjustment)}
    ]).

get_adjustment_id(#domain_InvoicePaymentAdjustment{id = ID}) ->
    ID.

get_adjustment_status(#domain_InvoicePaymentAdjustment{status = Status}) ->
    Status.

get_adjustment_cashflow(#domain_InvoicePaymentAdjustment{new_cash_flow = Cashflow}) ->
    Cashflow.

-define(adjustment_target_status(Status), #domain_InvoicePaymentAdjustment{
    state =
        {status_change, #domain_InvoicePaymentAdjustmentStatusChangeState{
            scenario = #domain_InvoicePaymentAdjustmentStatusChange{target_status = Status}
        }}
}).

%%

-spec process_signal(timeout, st(), opts()) -> machine_result().
process_signal(timeout, St, Options) ->
    scoper:scope(
        payment,
        get_st_meta(St),
        fun() -> process_timeout(St#st{opts = Options}) end
    ).

process_timeout(St) ->
    Action = hg_machine_action:new(),
    repair_process_timeout(get_activity(St), Action, St).

-spec process_timeout(activity(), action(), st()) -> machine_result().
process_timeout({payment, shop_limit_initializing}, Action, St) ->
    process_shop_limit_initialization(Action, St);
process_timeout({payment, shop_limit_failure}, Action, St) ->
    process_shop_limit_failure(Action, St);
process_timeout({payment, shop_limit_finalizing}, Action, St) ->
    process_shop_limit_finalization(Action, St);
process_timeout({payment, risk_scoring}, Action, St) ->
    process_risk_score(Action, St);
process_timeout({payment, routing}, Action, St) ->
    process_routing(Action, St);
process_timeout({payment, cash_flow_building}, Action, St) ->
    process_cash_flow_building(Action, St);
process_timeout({payment, Step}, _Action, St) when
    Step =:= processing_session orelse
        Step =:= finalizing_session
->
    process_session(St);
process_timeout({payment, Step}, Action, St) when
    Step =:= processing_failure orelse
        Step =:= routing_failure orelse
        Step =:= processing_accounter orelse
        Step =:= finalizing_accounter
->
    process_result(Action, St);
process_timeout({payment, updating_accounter}, Action, St) ->
    process_accounter_update(Action, St);
process_timeout({chargeback, ID, Type}, Action, St) ->
    process_chargeback(Type, ID, Action, St);
process_timeout({refund, ID}, _Action, St) ->
    process_refund(ID, St);
process_timeout({adjustment_new, ID}, Action, St) ->
    process_adjustment_cashflow(ID, Action, St);
process_timeout({adjustment_pending, ID}, Action, St) ->
    process_adjustment_capture(ID, Action, St);
process_timeout({payment, flow_waiting}, Action, St) ->
    finalize_payment(Action, St).

process_refund(ID, St = #st{opts = Options0, payment = Payment, repair_scenario = Scenario}) ->
    RepairScenario =
        case hg_invoice_repair:check_for_action(repair_session, Scenario) of
            call -> undefined;
            RepairAction -> RepairAction
        end,
    PaymentInfo = construct_payment_info(St, get_opts(St)),
    Options1 = Options0#{
        payment => Payment,
        payment_info => PaymentInfo,
        repair_scenario => RepairScenario
    },
    Refund = try_get_refund_state(ID, St),
    {Step, {Events0, Action}} = hg_invoice_payment_refund:process(Options1, Refund),
    Events1 = hg_invoice_payment_refund:wrap_events(Events0, Refund),
    Events2 =
        case hg_invoice_payment_refund:is_status_changed(?refund_succeeded(), Events1) of
            true ->
                process_refund_result(Events1, Refund, St);
            false ->
                Events1
        end,
    {Step, {Events2, Action}}.

process_refund_result(Changes, Refund0, St) ->
    Events = [Event || ?refund_ev(_, Event) <- Changes],
    Refund1 = hg_invoice_payment_refund:update_state_with(Events, Refund0),
    PaymentEvents =
        case
            hg_cash:sub(
                get_remaining_payment_balance(St), hg_invoice_payment_refund:cash(Refund1)
            )
        of
            ?cash(0, _) ->
                [
                    ?payment_status_changed(?refunded())
                ];
            ?cash(Amount, _) when Amount > 0 ->
                []
        end,
    Changes ++ PaymentEvents.

repair_process_timeout(Activity, Action, St = #st{repair_scenario = Scenario}) ->
    case hg_invoice_repair:check_for_action(fail_pre_processing, Scenario) of
        {result, Result} when
            Activity =:= {payment, routing} orelse
                Activity =:= {payment, cash_flow_building}
        ->
            rollback_broken_payment_limits(St),
            Result;
        {result, Result} ->
            Result;
        call ->
            process_timeout(Activity, Action, St)
    end.

-spec process_call
    ({callback, tag(), callback()}, st(), opts()) -> {callback_response(), machine_result()};
    ({session_change, tag(), session_change()}, st(), opts()) -> {ok, machine_result()}.
process_call({callback, Tag, Payload}, St, Options) ->
    scoper:scope(
        payment,
        get_st_meta(St),
        fun() -> process_callback(Tag, Payload, St#st{opts = Options}) end
    );
process_call({session_change, Tag, SessionChange}, St, Options) ->
    scoper:scope(
        payment,
        get_st_meta(St),
        fun() -> process_session_change(Tag, SessionChange, St#st{opts = Options}) end
    ).

-spec process_callback(tag(), callback(), st()) -> {callback_response(), machine_result()}.
process_callback(Tag, Payload, St) ->
    Session = get_activity_session(St),
    process_callback(Tag, Payload, Session, St).

-spec process_session_change(tag(), session_change(), st()) -> {ok, machine_result()}.
process_session_change(Tag, SessionChange, St) ->
    Session = get_activity_session(St),
    process_session_change(Tag, SessionChange, Session, St).

process_callback(Tag, Payload, Session, St) when Session /= undefined ->
    case {hg_session:status(Session), hg_session:tags(Session)} of
        {suspended, [Tag | _]} ->
            handle_callback(get_activity(St), Payload, Session, St);
        _ ->
            throw(invalid_callback)
    end;
process_callback(_Tag, _Payload, undefined, _St) ->
    throw(invalid_callback).

process_session_change(Tag, SessionChange, Session0, St) when Session0 /= undefined ->
    %% NOTE Change allowed only for suspended session. Not suspended
    %% session does not have registered callback with tag.
    case {hg_session:status(Session0), hg_session:tags(Session0)} of
        {suspended, [Tag | _]} ->
            {Result, Session1} = hg_session:process_change(SessionChange, Session0),
            {ok, finish_session_processing(get_activity(St), Result, Session1, St)};
        _ ->
            throw(invalid_callback)
    end;
process_session_change(_Tag, _Payload, undefined, _St) ->
    throw(invalid_callback).

%%

-spec process_shop_limit_initialization(action(), st()) -> machine_result().
process_shop_limit_initialization(Action, St) ->
    Opts = get_opts(St),
    _ = hold_shop_limits(Opts, St),
    case check_shop_limits(Opts, St) of
        ok ->
            {next, {[?shop_limit_initiated()], hg_machine_action:set_timeout(0, Action)}};
        {error, {limit_overflow = Error, IDs}} ->
            Failure = construct_shop_limit_failure(Error, IDs),
            Events = [
                ?shop_limit_initiated(),
                ?payment_rollback_started(Failure)
            ],
            {next, {Events, hg_machine_action:set_timeout(0, Action)}}
    end.

construct_shop_limit_failure(limit_overflow, IDs) ->
    Error = mk_static_error([authorization_failed, shop_limit_exceeded, unknown]),
    Reason = genlib:format("Limits with following IDs overflowed: ~p", [IDs]),
    {failure, payproc_errors:construct('PaymentFailure', Error, Reason)}.

process_shop_limit_failure(Action, St = #st{failure = Failure}) ->
    Opts = get_opts(St),
    _ = rollback_shop_limits(Opts, St, [ignore_business_error, ignore_not_found]),
    {done, {[?payment_status_changed(?failed(Failure))], hg_machine_action:set_timeout(0, Action)}}.

-spec process_shop_limit_finalization(action(), st()) -> machine_result().
process_shop_limit_finalization(Action, St) ->
    Opts = get_opts(St),
    _ = commit_shop_limits(Opts, St),
    {next, {[?shop_limit_applied()], hg_machine_action:set_timeout(0, Action)}}.

-spec process_risk_score(action(), st()) -> machine_result().
process_risk_score(Action, St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    VS1 = get_varset(St, #{}),
    PaymentInstitutionRef = get_payment_institution_ref(Opts, Revision),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    RiskScore = repair_inspect(Payment, PaymentInstitution, Opts, St),
    Events = [?risk_score_changed(RiskScore)],
    case check_risk_score(RiskScore) of
        ok ->
            {next, {Events, hg_machine_action:set_timeout(0, Action)}};
        {error, risk_score_is_too_high = Reason} ->
            logger:notice("No route found, reason = ~p, varset: ~p", [Reason, VS1]),
            handle_choose_route_error(Reason, Events, St, Action)
    end.

-spec process_routing(action(), st()) -> machine_result().
process_routing(Action, St) ->
    {PaymentInstitution, VS, Revision} = route_args(St),
    Ctx0 = hg_routing_ctx:with_guard(build_routing_context(PaymentInstitution, VS, Revision, St)),
    %% NOTE We need to handle routing errors differently if route not found
    %% before the pipeline.
    case hg_routing_ctx:error(Ctx0) of
        undefined ->
            Ctx1 = run_routing_decision_pipeline(Ctx0, VS, St),
            _ = [
                log_rejected_routes(Group, RejectedRoutes, VS)
             || {Group, RejectedRoutes} <- hg_routing_ctx:rejections(Ctx1)
            ],
            Events = produce_routing_events(Ctx1, Revision, St),
            {next, {Events, hg_machine_action:set_timeout(0, Action)}};
        Error ->
            ok = maybe_log_misconfigurations(Error),
            ok = log_rejected_routes(all, hg_routing_ctx:rejected_routes(Ctx0), VS),
            handle_choose_route_error(Error, [], St, Action)
    end.

run_routing_decision_pipeline(Ctx0, VS, St) ->
    %% NOTE Since this is routing step then current attempt is not yet
    %% accounted for in `St`.
    NewIter = get_iter(St) + 1,
    hg_routing_ctx:pipeline(
        Ctx0,
        [
            fun(Ctx) -> filter_attempted_routes(Ctx, St) end,
            fun(Ctx) -> filter_routes_with_limit_hold(Ctx, VS, NewIter, St) end,
            fun(Ctx) -> filter_routes_by_limit_overflow(Ctx, VS, NewIter, St) end,
            fun(Ctx) -> hg_routing:filter_by_blacklist(Ctx, build_blacklist_context(St)) end,
            fun hg_routing:filter_by_critical_provider_status/1,
            fun hg_routing:choose_route_with_ctx/1
        ]
    ).

produce_routing_events(Ctx = #{error := Error}, _Revision, St) when Error =/= undefined ->
    %% TODO Pass failure subcode from error. Say, if last candidates were
    %% rejected because of provider gone critical, then use subcode to highlight
    %% the offender. Like 'provider_dead' or 'conversion_lacking'.
    Failure = genlib:define(St#st.failure, construct_routing_failure(Error)),
    %% NOTE Not all initial candidates have their according limits held. And so
    %% we must account only for those that can be rolled back.
    RollbackableCandidates = hg_routing_ctx:accounted_candidates(Ctx),
    Route = hg_route:to_payment_route(hd(RollbackableCandidates)),
    Candidates =
        ordsets:from_list([hg_route:to_payment_route(R) || R <- RollbackableCandidates]),
    RouteScores = hg_routing_ctx:route_scores(Ctx),
    RouteLimits = hg_routing_ctx:route_limits(Ctx),
    %% For protocol compatability we set choosen route in route_changed event.
    %% It doesn't influence cash_flow building because this step will be
    %% skipped. And all limit's 'hold' operations will be rolled back.
    %% For same purpose in cascade routing we use route from unfiltered list of
    %% originally resolved candidates.
    [?route_changed(Route, Candidates, RouteScores, RouteLimits), ?payment_rollback_started(Failure)];
produce_routing_events(Ctx, Revision, _St) ->
    ok = log_route_choice_meta(Ctx, Revision),
    Route = hg_route:to_payment_route(hg_routing_ctx:choosen_route(Ctx)),
    Candidates =
        ordsets:from_list([hg_route:to_payment_route(R) || R <- hg_routing_ctx:considered_candidates(Ctx)]),
    RouteScores = hg_routing_ctx:route_scores(Ctx),
    RouteLimits = hg_routing_ctx:route_limits(Ctx),
    [?route_changed(Route, Candidates, RouteScores, RouteLimits)].

route_args(St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    #{payment_tool := PaymentTool} = VS1 = get_varset(St, #{risk_score => get_risk_score(St)}),
    CreatedAt = get_payment_created_at(Payment),
    PaymentInstitutionRef = get_payment_institution_ref(Opts, Revision),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS1),
    VS2 = collect_refund_varset(MerchantTerms#domain_PaymentsServiceTerms.refunds, PaymentTool, VS1),
    VS3 = collect_chargeback_varset(MerchantTerms#domain_PaymentsServiceTerms.chargebacks, VS2),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    {PaymentInstitution, VS3, Revision}.

build_routing_context(PaymentInstitution, VS, Revision, St) ->
    Payer = get_payment_payer(St),
    case get_predefined_route(Payer) of
        {ok, PaymentRoute} ->
            hg_routing_ctx:new([hg_route:from_payment_route(PaymentRoute)]);
        undefined ->
            gather_routes(PaymentInstitution, VS, Revision, St)
    end.

build_blacklist_context(St) ->
    Revision = get_payment_revision(St),
    #domain_InvoicePayment{payer = Payer} = get_payment(St),
    Token =
        case get_payer_payment_tool(Payer) of
            {bank_card, #domain_BankCard{token = CardToken}} ->
                CardToken;
            _ ->
                undefined
        end,
    Opts = get_opts(St),
    VS1 = get_varset(St, #{}),
    PaymentInstitutionRef = get_payment_institution_ref(Opts, Revision),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    InspectorRef = get_selector_value(inspector, PaymentInstitution#domain_PaymentInstitution.inspector),
    Inspector = hg_domain:get(Revision, {inspector, InspectorRef}),
    #{
        revision => Revision,
        token => Token,
        inspector => Inspector
    }.

filter_attempted_routes(Ctx, #st{routes = AttemptedRoutes}) ->
    lists:foldr(
        fun(R, C) ->
            R1 = hg_route:from_payment_route(R),
            R2 = hg_route:to_rejected_route(R1, {'AlreadyAttempted', undefined}),
            hg_routing_ctx:reject(already_attempted, R2, C)
        end,
        Ctx,
        AttemptedRoutes
    ).

handle_choose_route_error(Error, Events, St, Action) ->
    Failure = construct_routing_failure(Error),
    process_failure(get_activity(St), Events, Action, Failure, St).

%% NOTE See damsel payproc errors (proto/payment_processing_errors.thrift) for no route found

construct_routing_failure({rejected_routes, {SubCode, RejectedRoutes}}) when
    SubCode =:= limit_misconfiguration orelse
        SubCode =:= limit_overflow orelse
        SubCode =:= adapter_unavailable orelse
        SubCode =:= provider_conversion_is_too_low
->
    construct_routing_failure([rejected, SubCode], genlib:format(RejectedRoutes));
construct_routing_failure({rejected_routes, {_SubCode, RejectedRoutes}}) ->
    construct_routing_failure([forbidden], genlib:format(RejectedRoutes));
construct_routing_failure({misconfiguration = Code, Details}) ->
    construct_routing_failure([unknown, {unknown_error, atom_to_binary(Code)}], genlib:format(Details));
construct_routing_failure(Code = risk_score_is_too_high) ->
    construct_routing_failure([Code], undefined);
construct_routing_failure(Error) when is_atom(Error) ->
    construct_routing_failure([{unknown_error, Error}], undefined).

construct_routing_failure(Codes, Reason) ->
    {failure, payproc_errors:construct('PaymentFailure', mk_static_error([no_route_found | Codes]), Reason)}.

mk_static_error([_ | _] = Codes) -> mk_static_error_(#payproc_error_GeneralFailure{}, lists:reverse(Codes)).
mk_static_error_(T, []) -> T;
mk_static_error_(Sub, [Code | Codes]) -> mk_static_error_({Code, Sub}, Codes).

-spec process_cash_flow_building(action(), st()) -> machine_result().
process_cash_flow_building(Action, St) ->
    Route = get_route(St),
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Timestamp = get_payment_created_at(Payment),
    VS0 = reconstruct_payment_flow(Payment, #{}),
    VS1 = collect_validation_varset(get_party_config_ref(Opts), get_shop_obj(Opts, Revision), Payment, VS0),
    ProviderTerms = get_provider_terminal_terms(Route, VS1, Revision),
    Allocation = get_allocation(St),
    Context = #{
        provision_terms => ProviderTerms,
        route => Route,
        payment => Payment,
        timestamp => Timestamp,
        varset => VS1,
        revision => Revision,
        allocation => Allocation
    },
    FinalCashflow = calculate_cashflow(Context, Opts),
    _ = rollback_unused_payment_limits(St),
    _Clock = hg_accounting:hold(
        construct_payment_plan_id(St),
        {1, FinalCashflow}
    ),
    Events = [?cash_flow_changed(FinalCashflow)],
    {next, {Events, hg_machine_action:set_timeout(0, Action)}}.

%%

-spec process_chargeback(chargeback_activity_type(), chargeback_id(), action(), st()) -> machine_result().
process_chargeback(Type = finalising_accounter, ID, Action0, St) ->
    ChargebackState = get_chargeback_state(ID, St),
    ChargebackOpts = get_chargeback_opts(St),
    ChargebackBody = hg_invoice_payment_chargeback:get_body(ChargebackState),
    ChargebackTarget = hg_invoice_payment_chargeback:get_target_status(ChargebackState),
    MaybeChargedback = maybe_set_charged_back_status(ChargebackTarget, ChargebackBody, St),
    {Changes, Action1} = hg_invoice_payment_chargeback:process_timeout(Type, ChargebackState, Action0, ChargebackOpts),
    {done, {[?chargeback_ev(ID, C) || C <- Changes] ++ MaybeChargedback, Action1}};
process_chargeback(Type, ID, Action0, St) ->
    ChargebackState = get_chargeback_state(ID, St),
    ChargebackOpts = get_chargeback_opts(St),
    {Changes0, Action1} = hg_invoice_payment_chargeback:process_timeout(Type, ChargebackState, Action0, ChargebackOpts),
    Changes1 = [?chargeback_ev(ID, C) || C <- Changes0],
    case Type of
        %% NOTE In case if payment is already charged back and we want
        %% to reopen and change it, this will ensure machine to
        %% continue processing activities following cashflow update
        %% event.
        updating_cash_flow ->
            {next, {Changes1, Action1}};
        _ ->
            {done, {Changes1, Action1}}
    end.

maybe_set_charged_back_status(?chargeback_status_accepted(), ChargebackBody, St) ->
    InterimPaymentAmount = get_remaining_payment_balance(St),
    case hg_cash:sub(InterimPaymentAmount, ChargebackBody) of
        ?cash(0, _) ->
            [?payment_status_changed(?charged_back())];
        ?cash(Amount, _) when Amount > 0 ->
            []
    end;
maybe_set_charged_back_status(
    ?chargeback_status_cancelled(),
    _ChargebackBody,
    #st{
        payment = #domain_InvoicePayment{status = ?charged_back()},
        status_log = [_ActualStatus, PrevStatus | _]
    }
) ->
    [?payment_status_changed(PrevStatus)];
maybe_set_charged_back_status(_ChargebackStatus, _ChargebackBody, _St) ->
    [].

%%

-spec process_adjustment_cashflow(adjustment_id(), action(), st()) -> machine_result().
process_adjustment_cashflow(ID, _Action, St) ->
    Opts = get_opts(St),
    Adjustment = get_adjustment(ID, St),
    ok = prepare_adjustment_cashflow(Adjustment, St, Opts),
    Events = [?adjustment_ev(ID, ?adjustment_status_changed(?adjustment_processed()))],
    {next, {Events, hg_machine_action:instant()}}.

process_accounter_update(Action, St = #st{partial_cash_flow = FinalCashflow, capture_data = CaptureData}) ->
    #payproc_InvoicePaymentCaptureData{
        reason = Reason,
        cash = Cost,
        cart = Cart,
        allocation = Allocation
    } = CaptureData,
    _Clock = hg_accounting:plan(
        construct_payment_plan_id(St),
        [
            {2, hg_cashflow:revert(get_cashflow(St))},
            {3, FinalCashflow}
        ]
    ),
    Events = start_session(?captured(Reason, Cost, Cart, Allocation)),
    {next, {Events, hg_machine_action:set_timeout(0, Action)}}.

%%

-spec handle_callback(activity(), callback(), hg_session:t(), st()) -> {callback_response(), machine_result()}.
handle_callback({refund, ID}, Payload, _Session0, St) ->
    PaymentInfo = construct_payment_info(St, get_opts(St)),
    Refund = try_get_refund_state(ID, St),
    {Resp, {Step, {Events0, Action}}} = hg_invoice_payment_refund:process_callback(Payload, PaymentInfo, Refund),
    Events1 = hg_invoice_payment_refund:wrap_events(Events0, Refund),
    {Resp, {Step, {Events1, Action}}};
handle_callback(Activity, Payload, Session0, St) ->
    PaymentInfo = construct_payment_info(St, get_opts(St)),
    Session1 = hg_session:set_payment_info(PaymentInfo, Session0),
    {Response, {Result, Session2}} = hg_session:process_callback(Payload, Session1),
    {Response, finish_session_processing(Activity, Result, Session2, St)}.

-spec process_session(st()) -> machine_result().
process_session(St) ->
    Session = get_activity_session(St),
    process_session(Session, St).

process_session(undefined, St0) ->
    Target = get_target(St0),
    TargetType = get_target_type(Target),
    Action = hg_machine_action:new(),
    case validate_processing_deadline(get_payment(St0), TargetType) of
        ok ->
            Events = start_session(Target),
            Result = {Events, hg_machine_action:set_timeout(0, Action)},
            {next, Result};
        Failure ->
            process_failure(get_activity(St0), [], Action, Failure, St0)
    end;
process_session(Session0, St = #st{repair_scenario = Scenario}) ->
    Session1 =
        case hg_invoice_repair:check_for_action(repair_session, Scenario) of
            RepairScenario = {result, _} ->
                hg_session:set_repair_scenario(RepairScenario, Session0);
            call ->
                Session0
        end,
    PaymentInfo = construct_payment_info(St, get_opts(St)),
    Session2 = hg_session:set_payment_info(PaymentInfo, Session1),
    {Result, Session3} = hg_session:process(Session2),
    finish_session_processing(get_activity(St), Result, Session3, St).

-spec finish_session_processing(activity(), result(), hg_session:t(), st()) -> machine_result().
finish_session_processing(Activity, {Events0, Action}, Session, St0) ->
    Events1 = hg_session:wrap_events(Events0, Session),
    case {hg_session:status(Session), hg_session:result(Session)} of
        {finished, ?session_succeeded()} ->
            TargetType = get_target_type(hg_session:target(Session)),
            _ = maybe_notify_fault_detector(Activity, TargetType, finish, St0),
            NewAction = hg_machine_action:set_timeout(0, Action),
            InvoiceID = get_invoice_id(get_invoice(get_opts(St0))),
            St1 = collapse_changes(Events1, St0, #{invoice_id => InvoiceID}),
            _ =
                case St1 of
                    #st{new_cash_provided = true, activity = {payment, processing_accounter}} ->
                        %% Revert with St0 cause default rollback takes into account new cash
                        %% We need to rollback only current route.
                        %% Previously used routes are supposed to have their limits already rolled back.
                        Route = get_route(St0),
                        Routes = [Route],
                        _ = rollback_payment_limits(Routes, get_iter(St0), St0, []),
                        _ = rollback_payment_cashflow(St0);
                    _ ->
                        ok
                end,
            {next, {Events1, NewAction}};
        {finished, ?session_failed(Failure)} ->
            process_failure(Activity, Events1, Action, Failure, St0);
        _ ->
            {next, {Events1, Action}}
    end.

-spec finalize_payment(action(), st()) -> machine_result().
finalize_payment(Action, St) ->
    Target =
        case get_payment_flow(get_payment(St)) of
            ?invoice_payment_flow_instant() ->
                ?captured(<<"Timeout">>, get_payment_cost(get_payment(St)));
            ?invoice_payment_flow_hold(OnHoldExpiration, _) ->
                case OnHoldExpiration of
                    cancel ->
                        ?cancelled();
                    capture ->
                        ?captured(
                            <<"Timeout">>,
                            get_payment_cost(get_payment(St))
                        )
                end
        end,
    StartEvents =
        case Target of
            ?captured(Reason, Cost) ->
                start_capture(Reason, Cost, undefined, get_allocation(St));
            _ ->
                start_session(Target)
        end,
    {done, {StartEvents, hg_machine_action:set_timeout(0, Action)}}.

-spec process_result(action(), st()) -> machine_result().
process_result(Action, St) ->
    process_result(get_activity(St), Action, St).

process_result({payment, processing_accounter}, Action, St0 = #st{new_cash = Cost}) when
    Cost =/= undefined
->
    %% Rebuild cashflow for new cost
    Payment0 = get_payment(St0),
    Payment1 = Payment0#domain_InvoicePayment{cost = Cost},
    St1 = St0#st{payment = Payment1},
    Opts = get_opts(St1),
    Revision = get_payment_revision(St1),
    Timestamp = get_payment_created_at(Payment0),
    VS = collect_validation_varset(St1, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, Timestamp, VS),
    Route = get_route(St1),
    ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
    Context = #{
        provision_terms => ProviderTerms,
        merchant_terms => MerchantTerms,
        route => Route,
        payment => Payment1,
        timestamp => Timestamp,
        varset => VS,
        revision => Revision
    },
    FinalCashflow = calculate_cashflow(Context, Opts),
    %% Hold limits (only for chosen route) for new cashflow
    {_PaymentInstitution, RouteVS, _Revision} = route_args(St1),
    Routes = [hg_route:from_payment_route(Route)],
    _ = hold_limit_routes(Routes, RouteVS, get_iter(St1), St1),
    %% Hold cashflow
    St2 = St1#st{new_cash_flow = FinalCashflow},
    _Clock = hg_accounting:plan(
        construct_payment_plan_id(St2),
        get_cashflow_plan(St2)
    ),
    {next, {[?cash_flow_changed(FinalCashflow)], hg_machine_action:set_timeout(0, Action)}};
process_result({payment, processing_accounter}, Action, St) ->
    Target = get_target(St),
    NewAction = get_action(Target, Action, St),
    {done, {[?payment_status_changed(Target)], NewAction}};
process_result({payment, routing_failure}, Action, St = #st{failure = Failure}) ->
    NewAction = hg_machine_action:set_timeout(0, Action),
    Routes = get_candidate_routes(St),
    _ = rollback_payment_limits(Routes, get_iter(St), St, [ignore_business_error, ignore_not_found]),
    {done, {[?payment_status_changed(?failed(Failure))], NewAction}};
process_result({payment, processing_failure}, Action, St = #st{failure = Failure}) ->
    NewAction = hg_machine_action:set_timeout(0, Action),
    %% We need to rollback only current route.
    %% Previously used routes are supposed to have their limits already rolled back.
    Route = get_route(St),
    Routes = [Route],
    _ = rollback_payment_limits(Routes, get_iter(St), St, []),
    _ = rollback_payment_cashflow(St),
    Revision = get_payment_revision(St),
    Behaviour = get_route_cascade_behaviour(Route, Revision),
    case is_route_cascade_available(Behaviour, Route, ?failed(Failure), St) of
        true -> process_routing(NewAction, St);
        false -> {done, {[?payment_status_changed(?failed(Failure))], NewAction}}
    end;
process_result({payment, finalizing_accounter}, Action, St) ->
    Target = get_target(St),
    _PostingPlanLog =
        case Target of
            ?captured() ->
                commit_payment_limits(St),
                commit_payment_cashflow(St);
            ?cancelled() ->
                Route = get_route(St),
                _ = rollback_payment_limits([Route], get_iter(St), St, []),
                rollback_payment_cashflow(St)
        end,
    check_recurrent_token(St),
    NewAction = get_action(Target, Action, St),
    {done, {[?payment_status_changed(Target)], NewAction}}.

process_failure(Activity, Events, Action, Failure, St) ->
    process_failure(Activity, Events, Action, Failure, St, undefined).

process_failure({payment, processing_failure}, Events, Action, _Failure, #st{failure = Failure}, _RefundSt) when
    Failure =/= undefined
->
    %% In case of cascade attempt we may catch and handle routing failure during 'processing_failure' activity
    {done, {Events ++ [?payment_status_changed(?failed(Failure))], Action}};
process_failure({payment, Step}, Events, Action, Failure, _St, _RefundSt) when
    Step =:= risk_scoring orelse
        Step =:= routing
->
    {done, {Events ++ [?payment_status_changed(?failed(Failure))], Action}};
process_failure({payment, Step} = Activity, Events, Action, Failure, St, _RefundSt) when
    Step =:= processing_session orelse
        Step =:= finalizing_session
->
    Target = get_target(St),
    case check_retry_possibility(Target, Failure, St) of
        {retry, Timeout} ->
            _ = logger:notice("Retry session after transient failure, wait ~p", [Timeout]),
            {SessionEvents, SessionAction} = retry_session(Action, Target, Timeout),
            {next, {Events ++ SessionEvents, SessionAction}};
        fatal ->
            TargetType = get_target_type(Target),
            OperationStatus = choose_fd_operation_status_for_failure(Failure),
            _ = maybe_notify_fault_detector(Activity, TargetType, OperationStatus, St),
            process_fatal_payment_failure(Target, Events, Action, Failure, St)
    end.

check_recurrent_token(#st{
    payment = #domain_InvoicePayment{id = ID, make_recurrent = true},
    recurrent_token = undefined
}) ->
    _ = logger:warning("Fail to get recurrent token in recurrent payment. Payment id:~p", [ID]);
check_recurrent_token(#st{
    payment = #domain_InvoicePayment{id = ID, make_recurrent = MakeRecurrent},
    recurrent_token = Token
}) when
    (MakeRecurrent =:= false orelse MakeRecurrent =:= undefined) andalso
        Token =/= undefined
->
    _ = logger:warning("Got recurrent token in non recurrent payment. Payment id:~p", [ID]);
check_recurrent_token(_) ->
    ok.

choose_fd_operation_status_for_failure({failure, Failure}) ->
    payproc_errors:match('PaymentFailure', Failure, fun do_choose_fd_operation_status_for_failure/1);
choose_fd_operation_status_for_failure(_Failure) ->
    finish.

do_choose_fd_operation_status_for_failure({authorization_failed, {FailType, _}}) ->
    DefaultBenignFailures = [
        insufficient_funds,
        rejected_by_issuer,
        processing_deadline_reached
    ],
    FDConfig = genlib_app:env(hellgate, fault_detector, #{}),
    Config = genlib_map:get(conversion, FDConfig, #{}),
    BenignFailures = genlib_map:get(benign_failures, Config, DefaultBenignFailures),
    case lists:member(FailType, BenignFailures) of
        false -> error;
        true -> finish
    end;
do_choose_fd_operation_status_for_failure(_Failure) ->
    finish.

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

process_fatal_payment_failure(?cancelled(), _Events, _Action, Failure, _St) ->
    error({invalid_cancel_failure, Failure});
process_fatal_payment_failure(?captured(), _Events, _Action, Failure, _St) ->
    error({invalid_capture_failure, Failure});
process_fatal_payment_failure(?processed(), Events, Action, Failure, _St) ->
    RollbackStarted = [?payment_rollback_started(Failure)],
    {next, {Events ++ RollbackStarted, hg_machine_action:set_timeout(0, Action)}}.

retry_session(Action, Target, Timeout) ->
    NewEvents = start_session(Target),
    NewAction = set_timer({timeout, Timeout}, Action),
    {NewEvents, NewAction}.

get_actual_retry_strategy(Target, #st{retry_attempts = Attempts}) ->
    AttemptNum = maps:get(get_target_type(Target), Attempts, 0),
    hg_retry:skip_steps(get_initial_retry_strategy(get_target_type(Target)), AttemptNum).

-spec get_initial_retry_strategy(session_target_type()) -> retry_strategy().
get_initial_retry_strategy(TargetType) ->
    PolicyConfig = genlib_app:env(hellgate, payment_retry_policy, #{}),
    hg_retry:new_strategy(maps:get(TargetType, PolicyConfig, no_retry)).

-spec check_retry_possibility(Target, Failure, St) -> {retry, Timeout} | fatal when
    Failure :: failure(),
    Target :: target(),
    St :: st(),
    Timeout :: non_neg_integer().
check_retry_possibility(Target, Failure, St) ->
    case check_failure_type(Target, Failure) of
        transient ->
            RetryStrategy = get_actual_retry_strategy(Target, St),
            case hg_retry:next_step(RetryStrategy) of
                {wait, Timeout, _NewStrategy} ->
                    {retry, Timeout};
                finish ->
                    _ = logger:debug("Retries strategy is exceed"),
                    fatal
            end;
        fatal ->
            _ = logger:debug("Failure ~p is not transient", [Failure]),
            fatal
    end.

-spec check_failure_type(target(), failure()) -> transient | fatal.
check_failure_type(Target, {failure, Failure}) ->
    payproc_errors:match(get_error_class(Target), Failure, fun do_check_failure_type/1);
check_failure_type(_Target, _Other) ->
    fatal.

get_error_class({Target, _}) when Target =:= processed; Target =:= captured; Target =:= cancelled ->
    'PaymentFailure';
get_error_class(Target) ->
    error({unsupported_target, Target}).

do_check_failure_type({authorization_failed, {temporarily_unavailable, _}}) ->
    transient;
do_check_failure_type(_Failure) ->
    fatal.

get_action(?processed(), Action, St) ->
    case get_payment_flow(get_payment(St)) of
        ?invoice_payment_flow_instant() ->
            hg_machine_action:set_timeout(0, Action);
        ?invoice_payment_flow_hold(_, HeldUntil) ->
            hg_machine_action:set_deadline(HeldUntil, Action)
    end;
get_action(_Target, Action, _St) ->
    Action.

set_timer(Timer, Action) ->
    hg_machine_action:set_timer(Timer, Action).

get_provider_terms(St, Revision) ->
    Opts = get_opts(St),
    Route = get_route(St),
    Payment = get_payment(St),
    VS0 = reconstruct_payment_flow(Payment, #{}),
    VS1 = collect_validation_varset(get_party_config_ref(Opts), get_shop_obj(Opts, Revision), Payment, VS0),
    hg_routing:get_payment_terms(Route, VS1, Revision).

filter_routes_with_limit_hold(Ctx0, VS, Iter, St) ->
    {_Routes, RejectedRoutes} = hold_limit_routes(hg_routing_ctx:candidates(Ctx0), VS, Iter, St),
    Ctx1 = reject_routes(limit_misconfiguration, RejectedRoutes, Ctx0),
    hg_routing_ctx:stash_current_candidates(Ctx1).

filter_routes_by_limit_overflow(Ctx0, VS, Iter, St) ->
    {_Routes, RejectedRoutes, Limits} = get_limit_overflow_routes(hg_routing_ctx:candidates(Ctx0), VS, Iter, St),
    Ctx1 = hg_routing_ctx:stash_route_limits(Limits, Ctx0),
    reject_routes(limit_overflow, RejectedRoutes, Ctx1).

reject_routes(GroupReason, RejectedRoutes, Ctx) ->
    lists:foldr(
        fun(R, C) -> hg_routing_ctx:reject(GroupReason, R, C) end,
        Ctx,
        RejectedRoutes
    ).

get_limit_overflow_routes(Routes, VS, Iter, St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    lists:foldl(
        fun(Route, {RoutesNoOverflowIn, RejectedIn, LimitsIn}) ->
            PaymentRoute = hg_route:to_payment_route(Route),
            ProviderTerms = hg_routing:get_payment_terms(PaymentRoute, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms, strict),
            case hg_limiter:check_limits(TurnoverLimits, Invoice, Payment, PaymentRoute, Iter) of
                {ok, Limits} ->
                    {[Route | RoutesNoOverflowIn], RejectedIn, LimitsIn#{PaymentRoute => Limits}};
                {error, {limit_overflow, IDs, Limits}} ->
                    RejectedRoute = hg_route:to_rejected_route(Route, {'LimitOverflow', IDs}),
                    {RoutesNoOverflowIn, [RejectedRoute | RejectedIn], LimitsIn#{PaymentRoute => Limits}}
            end
        end,
        {[], [], #{}},
        Routes
    ).

%% Shop limits

hold_shop_limits(Opts, St) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    Invoice = get_invoice(Opts),
    PartyConfigRef = get_party_config_ref(Opts),
    {ShopConfigRef, Shop} = get_shop_obj(Opts, Revision),
    TurnoverLimits = get_shop_turnover_limits(Shop),
    ok = hg_limiter:hold_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment).

commit_shop_limits(Opts, St) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    Invoice = get_invoice(Opts),
    PartyConfigRef = get_party_config_ref(Opts),
    {ShopConfigRef, Shop} = get_shop_obj(Opts, Revision),
    TurnoverLimits = get_shop_turnover_limits(Shop),
    ok = hg_limiter:commit_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment).

check_shop_limits(Opts, St) ->
    Payment = get_payment(St),
    Revision = get_payment_revision(St),
    Invoice = get_invoice(Opts),
    PartyConfigRef = get_party_config_ref(Opts),
    {ShopConfigRef, Shop} = get_shop_obj(Opts, Revision),
    TurnoverLimits = get_shop_turnover_limits(Shop),
    hg_limiter:check_shop_limits(TurnoverLimits, PartyConfigRef, ShopConfigRef, Invoice, Payment).

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

rollback_unused_payment_limits(St) ->
    Route = get_route(St),
    Routes = get_candidate_routes(St),
    UnUsedRoutes = Routes -- [Route],
    rollback_payment_limits(UnUsedRoutes, get_iter(St), St, [ignore_business_error, ignore_not_found]).

get_turnover_limits(ProviderTerms, Mode) ->
    hg_limiter:get_turnover_limits(ProviderTerms, Mode).

commit_payment_limits(#st{capture_data = CaptureData} = St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    #payproc_InvoicePaymentCaptureData{cash = CapturedCash} = CaptureData,
    Invoice = get_invoice(Opts),
    Route = get_route(St),
    ProviderTerms = get_provider_terms(St, Revision),
    TurnoverLimits = get_turnover_limits(ProviderTerms, strict),
    Iter = get_iter(St),
    hg_limiter:commit_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, CapturedCash).

commit_payment_cashflow(St) ->
    Plan = get_cashflow_plan(St),
    do_try_with_ids(
        [
            construct_payment_plan_id(St),
            construct_payment_plan_id(St, legacy)
        ],
        fun(ID) ->
            hg_accounting:commit(ID, Plan)
        end
    ).

rollback_payment_cashflow(St) ->
    Plan = get_cashflow_plan(St),
    do_try_with_ids(
        [
            construct_payment_plan_id(St),
            construct_payment_plan_id(St, legacy)
        ],
        fun(ID) ->
            hg_accounting:rollback(ID, Plan)
        end
    ).

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

get_cashflow_plan(
    St = #st{
        partial_cash_flow = PartialCashFlow,
        new_cash_provided = true,
        new_cash_flow = NewCashFlow
    }
) when PartialCashFlow =/= undefined ->
    [
        {1, get_cashflow(St)},
        {2, hg_cashflow:revert(get_cashflow(St))},
        {3, PartialCashFlow},
        {4, hg_cashflow:revert(PartialCashFlow)},
        {5, NewCashFlow}
    ];
get_cashflow_plan(St = #st{new_cash_provided = true, new_cash_flow = NewCashFlow}) ->
    [
        {1, get_cashflow(St)},
        {2, hg_cashflow:revert(get_cashflow(St))},
        {3, NewCashFlow}
    ];
get_cashflow_plan(St = #st{partial_cash_flow = PartialCashFlow}) when PartialCashFlow =/= undefined ->
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
    construct_payment_info(
        get_activity(St),
        get_target(St),
        St,
        #proxy_provider_PaymentInfo{
            shop = construct_proxy_shop(get_shop_obj(Opts, Revision)),
            invoice = construct_proxy_invoice(get_invoice(Opts)),
            payment = construct_proxy_payment(Payment, get_trx(St))
        }
    ).

construct_payment_info(idle, _Target, _St, PaymentInfo) ->
    PaymentInfo;
construct_payment_info(
    {payment, _Step},
    Target = ?captured(),
    _St,
    PaymentInfo
) ->
    PaymentInfo#proxy_provider_PaymentInfo{
        capture = construct_proxy_capture(Target)
    };
construct_payment_info({payment, _Step}, _Target, _St, PaymentInfo) ->
    PaymentInfo;
construct_payment_info({refund, _ID}, _Target, _St, PaymentInfo) ->
    PaymentInfo.

construct_proxy_payment(
    #domain_InvoicePayment{
        id = ID,
        created_at = CreatedAt,
        domain_revision = Revision,
        payer = Payer,
        payer_session_info = PayerSessionInfo,
        cost = Cost,
        make_recurrent = MakeRecurrent,
        processing_deadline = Deadline
    },
    Trx
) ->
    ContactInfo = get_contact_info(Payer),
    PaymentTool = get_payer_payment_tool(Payer),
    #proxy_provider_InvoicePayment{
        id = ID,
        created_at = CreatedAt,
        trx = Trx,
        payment_resource = construct_payment_resource(Payer),
        payment_service = hg_payment_tool:get_payment_service(PaymentTool, Revision),
        payer_session_info = PayerSessionInfo,
        cost = construct_proxy_cash(Cost),
        contact_info = ContactInfo,
        make_recurrent = MakeRecurrent,
        processing_deadline = Deadline
    }.

construct_payment_resource(?payment_resource_payer(Resource, _)) ->
    {disposable_payment_resource, Resource};
construct_payment_resource(?recurrent_payer(PaymentTool, ?recurrent_parent(InvoiceID, PaymentID), _)) ->
    PreviousPayment = get_payment_state(InvoiceID, PaymentID),
    RecToken = get_recurrent_token(PreviousPayment),
    {recurrent_payment_resource, #proxy_provider_RecurrentPaymentResource{
        payment_tool = PaymentTool,
        rec_token = RecToken
    }}.

get_contact_info(?payment_resource_payer(_, ContactInfo)) ->
    ContactInfo;
get_contact_info(?recurrent_payer(_, _, ContactInfo)) ->
    ContactInfo.

construct_proxy_invoice(
    #domain_Invoice{
        id = InvoiceID,
        created_at = CreatedAt,
        due = Due,
        details = Details,
        cost = Cost
    }
) ->
    #proxy_provider_Invoice{
        id = InvoiceID,
        created_at = CreatedAt,
        due = Due,
        details = Details,
        cost = construct_proxy_cash(Cost)
    }.

construct_proxy_shop(
    {
        #domain_ShopConfigRef{id = ShopConfigID},
        Shop = #domain_ShopConfig{
            location = Location,
            category = ShopCategoryRef
        }
    }
) ->
    ShopCategory = hg_domain:get({category, ShopCategoryRef}),
    #proxy_provider_Shop{
        id = ShopConfigID,
        category = ShopCategory,
        name = Shop#domain_ShopConfig.name,
        description = Shop#domain_ShopConfig.description,
        location = Location
    }.

construct_proxy_cash(#domain_Cash{
    amount = Amount,
    currency = CurrencyRef
}) ->
    #proxy_provider_Cash{
        amount = Amount,
        currency = hg_domain:get({currency, CurrencyRef})
    }.

construct_proxy_capture(?captured(_, Cost)) ->
    #proxy_provider_InvoicePaymentCapture{
        cost = construct_proxy_cash(Cost)
    }.

%%

get_party_obj(#{party := Party, party_config_ref := PartyConfigRef}) ->
    {PartyConfigRef, Party}.

get_party(#{party := Party}) ->
    Party.

get_party_config_ref(#{party_config_ref := PartyConfigRef}) ->
    PartyConfigRef.

get_shop(Opts, Revision) ->
    {_, Shop} = get_shop_obj(Opts, Revision),
    Shop.

get_shop_obj(#{invoice := Invoice, party_config_ref := PartyConfigRef}, Revision) ->
    hg_party:get_shop(get_invoice_shop_config_ref(Invoice), PartyConfigRef, Revision).

get_payment_institution_ref(Opts, Revision) ->
    Shop = get_shop(Opts, Revision),
    Shop#domain_ShopConfig.payment_institution.

-spec get_invoice(opts()) -> invoice().
get_invoice(#{invoice := Invoice}) ->
    Invoice.

get_invoice_id(#domain_Invoice{id = ID}) ->
    ID.

get_invoice_cost(#domain_Invoice{cost = Cost}) ->
    Cost.

get_invoice_shop_config_ref(#domain_Invoice{shop_ref = ShopConfigRef}) ->
    ShopConfigRef.

get_payment_id(#domain_InvoicePayment{id = ID}) ->
    ID.

get_payment_cost(#domain_InvoicePayment{changed_cost = Cost}) when Cost =/= undefined ->
    Cost;
get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_payment_flow(#domain_InvoicePayment{flow = Flow}) ->
    Flow.

get_payment_shop_config_ref(#domain_InvoicePayment{shop_ref = ShopConfigRef}) ->
    ShopConfigRef.

get_payment_tool(#domain_InvoicePayment{payer = Payer}) ->
    get_payer_payment_tool(Payer).

get_payment_created_at(#domain_InvoicePayment{created_at = CreatedAt}) ->
    CreatedAt.

-spec get_payer_payment_tool(payer()) -> payment_tool().
get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource);
get_payer_payment_tool(?recurrent_payer(PaymentTool, _, _)) ->
    PaymentTool.

get_payer_card_token(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    case get_resource_payment_tool(PaymentResource) of
        {bank_card, #domain_BankCard{token = Token}} ->
            Token;
        _ ->
            undefined
    end;
get_payer_card_token(?recurrent_payer(_, _, _)) ->
    undefined.

get_payer_client_ip(
    ?payment_resource_payer(
        #domain_DisposablePaymentResource{
            client_info = #domain_ClientInfo{
                ip_address = IP
            }
        },
        _ContactInfo
    )
) ->
    IP;
get_payer_client_ip(_OtherPayer) ->
    undefined.

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

-spec throw_invalid_request(binary()) -> no_return().
throw_invalid_request(Why) ->
    throw(#base_InvalidRequest{errors = [Why]}).

-spec throw_invalid_recurrent_parent(binary()) -> no_return().
throw_invalid_recurrent_parent(Details) ->
    throw(#payproc_InvalidRecurrentParentPayment{details = Details}).

%%

-type change_opts() :: #{
    timestamp => hg_datetime:timestamp(),
    validation => strict,
    invoice_id => invoice_id()
}.

-spec merge_change(change(), st() | undefined, change_opts()) -> st().
merge_change(Change, undefined, Opts) ->
    merge_change(Change, #st{activity = {payment, new}}, Opts);
merge_change(Change = ?payment_started(Payment), #st{} = St, Opts) ->
    _ = validate_transition({payment, new}, Change, St, Opts),
    St#st{
        target = ?processed(),
        payment = Payment,
        activity = {payment, shop_limit_initializing},
        timings = hg_timings:mark(started, define_event_timestamp(Opts))
    };
merge_change(Change = ?shop_limit_initiated(), #st{} = St, Opts) ->
    _ = validate_transition({payment, shop_limit_initializing}, Change, St, Opts),
    St#st{
        shop_limit_status = initialized,
        activity = {payment, shop_limit_finalizing}
    };
merge_change(Change = ?shop_limit_applied(), #st{} = St, Opts) ->
    _ = validate_transition({payment, shop_limit_finalizing}, Change, St, Opts),
    St#st{
        shop_limit_status = finalized,
        activity = {payment, risk_scoring}
    };
merge_change(Change = ?risk_score_changed(RiskScore), #st{} = St, Opts) ->
    _ = validate_transition(
        [
            {payment, S}
         || S <- [
                risk_scoring,
                %% Added for backward compatibility
                shop_limit_initializing
            ]
        ],
        Change,
        St,
        Opts
    ),
    St#st{
        risk_score = RiskScore,
        activity = {payment, routing}
    };
merge_change(
    Change = ?route_changed(Route, Candidates, Scores, Limits),
    #st{routes = Routes, route_scores = RouteScores, route_limits = RouteLimits} = St,
    Opts
) ->
    _ = validate_transition([{payment, S} || S <- [routing, processing_failure]], Change, St, Opts),
    St#st{
        %% On route change we expect cash flow from previous attempt to be rolled back.
        %% So on `?payment_rollback_started(_)` event for routing failure we won't try to do it again.
        cash_flow = undefined,
        %% `trx` from previous session (if any) also must be considered obsolete.
        trx = undefined,
        routes = [Route | Routes],
        candidate_routes = ordsets:to_list(Candidates),
        activity = {payment, cash_flow_building},
        route_scores = hg_maybe:apply(fun(S) -> maps:merge(RouteScores, S) end, Scores, RouteScores),
        route_limits = hg_maybe:apply(fun(L) -> maps:merge(RouteLimits, L) end, Limits, RouteLimits)
    };
merge_change(Change = ?payment_capture_started(Data), #st{} = St, Opts) ->
    _ = validate_transition([{payment, S} || S <- [flow_waiting]], Change, St, Opts),
    St#st{
        capture_data = Data,
        activity = {payment, processing_capture},
        allocation = Data#payproc_InvoicePaymentCaptureData.allocation
    };
merge_change(Change = ?cash_flow_changed(CashFlow), #st{activity = Activity} = St0, Opts) ->
    _ = validate_transition(
        [
            {payment, S}
         || S <- [
                cash_flow_building,
                processing_capture,
                processing_accounter
            ]
        ],
        Change,
        St0,
        Opts
    ),
    St = St0#st{
        final_cash_flow = CashFlow
    },
    case Activity of
        {payment, processing_accounter} ->
            St#st{new_cash = undefined, new_cash_flow = CashFlow};
        {payment, cash_flow_building} ->
            St#st{
                cash_flow = CashFlow,
                activity = {payment, processing_session}
            };
        {payment, processing_capture} ->
            St#st{
                partial_cash_flow = CashFlow,
                activity = {payment, updating_accounter}
            };
        _ ->
            St
    end;
merge_change(Change = ?rec_token_acquired(Token), #st{} = St, Opts) ->
    _ = validate_transition([{payment, processing_session}, {payment, finalizing_session}], Change, St, Opts),
    St#st{recurrent_token = Token};
merge_change(Change = ?cash_changed(_OldCash, NewCash), #st{} = St, Opts) ->
    _ = validate_transition(
        [{adjustment_new, latest_adjustment_id(St)}, {payment, processing_session}],
        Change,
        St,
        Opts
    ),
    Payment0 = get_payment(St),
    Payment1 = Payment0#domain_InvoicePayment{changed_cost = NewCash},
    St#st{new_cash = NewCash, new_cash_provided = true, payment = Payment1};
merge_change(Change = ?payment_rollback_started(Failure), St, Opts) ->
    _ = validate_transition(
        [
            {payment, shop_limit_finalizing},
            {payment, cash_flow_building},
            {payment, processing_session}
        ],
        Change,
        St,
        Opts
    ),
    Activity =
        case St of
            #st{shop_limit_status = initialized} ->
                {payment, shop_limit_failure};
            #st{cash_flow = undefined} ->
                {payment, routing_failure};
            _ ->
                {payment, processing_failure}
        end,
    St#st{
        failure = Failure,
        activity = Activity,
        timings = accrue_status_timing(failed, Opts, St)
    };
merge_change(Change = ?payment_status_changed({failed, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition(
        [
            {payment, S}
         || S <- [
                risk_scoring,
                routing,
                cash_flow_building,
                shop_limit_failure,
                routing_failure,
                processing_failure
            ]
        ],
        Change,
        St,
        Opts
    ),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = idle,
        failure = undefined,
        timings = accrue_status_timing(failed, Opts, St)
    };
merge_change(Change = ?payment_status_changed({cancelled, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition({payment, finalizing_accounter}, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = idle,
        timings = accrue_status_timing(cancelled, Opts, St)
    };
merge_change(Change = ?payment_status_changed({captured, Captured} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition([idle, {payment, finalizing_accounter}], Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{
            status = Status,
            cost = get_captured_cost(Captured, Payment)
        },
        activity = idle,
        timings = accrue_status_timing(captured, Opts, St),
        allocation = get_captured_allocation(Captured)
    };
merge_change(Change = ?payment_status_changed({processed, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition({payment, processing_accounter}, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = {payment, flow_waiting},
        timings = accrue_status_timing(processed, Opts, St)
    };
merge_change(Change = ?payment_status_changed({refunded, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition(idle, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status}
    };
merge_change(Change = ?payment_status_changed({charged_back, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition(idle, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status}
    };
merge_change(Change = ?chargeback_ev(ID, Event), St, Opts) ->
    St1 =
        case Event of
            ?chargeback_created(_) ->
                _ = validate_transition(idle, Change, St, Opts),
                St#st{activity = {chargeback, ID, preparing_initial_cash_flow}};
            ?chargeback_stage_changed(_) ->
                _ = validate_transition(idle, Change, St, Opts),
                St;
            ?chargeback_levy_changed(_) ->
                _ = validate_transition([idle, {chargeback, ID, updating_chargeback}], Change, St, Opts),
                St#st{activity = {chargeback, ID, updating_chargeback}};
            ?chargeback_body_changed(_) ->
                _ = validate_transition([idle, {chargeback, ID, updating_chargeback}], Change, St, Opts),
                St#st{activity = {chargeback, ID, updating_chargeback}};
            ?chargeback_cash_flow_changed(_) ->
                Valid = [{chargeback, ID, Activity} || Activity <- [preparing_initial_cash_flow, updating_cash_flow]],
                _ = validate_transition(Valid, Change, St, Opts),
                case St of
                    #st{activity = {chargeback, ID, preparing_initial_cash_flow}} ->
                        St#st{activity = idle};
                    #st{activity = {chargeback, ID, updating_cash_flow}} ->
                        St#st{activity = {chargeback, ID, finalising_accounter}}
                end;
            ?chargeback_target_status_changed(?chargeback_status_accepted()) ->
                _ = validate_transition([idle, {chargeback, ID, updating_chargeback}], Change, St, Opts),
                case St of
                    #st{activity = idle} ->
                        St#st{activity = {chargeback, ID, finalising_accounter}};
                    #st{activity = {chargeback, ID, updating_chargeback}} ->
                        St#st{activity = {chargeback, ID, updating_cash_flow}}
                end;
            ?chargeback_target_status_changed(_) ->
                _ = validate_transition([idle, {chargeback, ID, updating_chargeback}], Change, St, Opts),
                St#st{activity = {chargeback, ID, updating_cash_flow}};
            ?chargeback_status_changed(_) ->
                _ = validate_transition([idle, {chargeback, ID, finalising_accounter}], Change, St, Opts),
                St#st{activity = idle}
        end,
    ChargebackSt = merge_chargeback_change(Event, try_get_chargeback_state(ID, St1)),
    set_chargeback_state(ID, ChargebackSt, St1);
merge_change(?refund_ev(ID, Event), St, Opts) ->
    EventContext = create_refund_event_context(St, Opts),
    St1 =
        case Event of
            ?refund_status_changed(?refund_succeeded()) ->
                RefundSt0 = hg_invoice_payment_refund:apply_event(
                    Event, try_get_refund_state(ID, St), EventContext
                ),
                DomainRefund = hg_invoice_payment_refund:refund(RefundSt0),
                Allocation = get_allocation(St),
                FinalAllocation = hg_maybe:apply(
                    fun(A) ->
                        #domain_InvoicePaymentRefund{allocation = RefundAllocation} = DomainRefund,
                        {ok, FA} = hg_allocation:sub(A, RefundAllocation),
                        FA
                    end,
                    Allocation
                ),
                St#st{allocation = FinalAllocation};
            _ ->
                St
        end,
    RefundSt1 = hg_invoice_payment_refund:apply_event(Event, try_get_refund_state(ID, St1), EventContext),
    St2 = set_refund_state(ID, RefundSt1, St1),
    case hg_invoice_payment_refund:status(RefundSt1) of
        S when S == succeeded; S == failed ->
            St2#st{activity = idle};
        _ ->
            St2#st{activity = {refund, ID}}
    end;
merge_change(Change = ?adjustment_ev(ID, Event), St, Opts) ->
    St1 =
        case Event of
            ?adjustment_created(_) ->
                _ = validate_transition(idle, Change, St, Opts),
                St#st{activity = {adjustment_new, ID}};
            ?adjustment_status_changed(?adjustment_processed()) ->
                _ = validate_transition({adjustment_new, ID}, Change, St, Opts),
                St#st{activity = {adjustment_pending, ID}};
            ?adjustment_status_changed(_) ->
                _ = validate_transition({adjustment_pending, ID}, Change, St, Opts),
                St#st{activity = idle}
        end,
    Adjustment = merge_adjustment_change(Event, try_get_adjustment(ID, St1)),
    St2 = set_adjustment(ID, Adjustment, St1),
    % TODO new cashflow imposed implicitly on the payment state? rough
    case get_adjustment_status(Adjustment) of
        ?adjustment_captured(_) ->
            apply_adjustment_effects(Adjustment, St2);
        _ ->
            St2
    end;
merge_change(
    Change = ?session_ev(Target, Event = ?session_started()),
    #st{activity = Activity} = St,
    Opts
) ->
    _ = validate_transition(
        [
            {payment, S}
         || S <- [
                processing_session,
                flow_waiting,
                processing_capture,
                updating_accounter,
                finalizing_session
            ]
        ],
        Change,
        St,
        Opts
    ),
    % FIXME why the hell dedicated handling
    Session0 = hg_session:apply_event(Event, undefined, create_session_event_context(Target, St, Opts)),
    %% We need to pass processed trx_info to captured/cancelled session due to provider requirements
    Session1 = hg_session:set_trx_info(get_trx(St), Session0),
    St1 = add_session(Target, Session1, St#st{target = Target}),
    St2 = save_retry_attempt(Target, St1),
    case Activity of
        {payment, processing_session} ->
            %% session retrying
            St2#st{activity = {payment, processing_session}};
        {payment, PaymentActivity} when PaymentActivity == flow_waiting; PaymentActivity == processing_capture ->
            %% session flow
            St2#st{
                activity = {payment, finalizing_session},
                timings = try_accrue_waiting_timing(Opts, St2)
            };
        {payment, updating_accounter} ->
            %% session flow
            St2#st{activity = {payment, finalizing_session}};
        {payment, finalizing_session} ->
            %% session retrying
            St2#st{activity = {payment, finalizing_session}};
        _ ->
            St2
    end;
merge_change(Change = ?session_ev(Target, Event), St = #st{activity = Activity}, Opts) ->
    _ = validate_transition([{payment, S} || S <- [processing_session, finalizing_session]], Change, St, Opts),
    Session = hg_session:apply_event(
        Event,
        get_session(Target, St),
        create_session_event_context(Target, St, Opts)
    ),
    St1 = update_session(Target, Session, St),
    % FIXME leaky transactions
    St2 = set_trx(hg_session:trx_info(Session), St1),
    case Session of
        #{status := finished, result := ?session_succeeded()} ->
            NextActivity =
                case Activity of
                    {payment, processing_session} ->
                        {payment, processing_accounter};
                    {payment, finalizing_session} ->
                        {payment, finalizing_accounter};
                    _ ->
                        Activity
                end,
            St2#st{activity = NextActivity};
        _ ->
            St2
    end.

record_status_change(?payment_status_changed(Status), St) ->
    St#st{status_log = [Status | St#st.status_log]}.

latest_adjustment_id(#st{adjustments = []}) ->
    undefined;
latest_adjustment_id(#st{adjustments = Adjustments}) ->
    Adjustment = lists:last(Adjustments),
    Adjustment#domain_InvoicePaymentAdjustment.id.

get_routing_attempt_limit(
    St = #st{
        payment = #domain_InvoicePayment{
            party_ref = PartyConfigRef,
            shop_ref = ShopConfigRef,
            domain_revision = Revision
        }
    }
) ->
    {PartyConfigRef, _Party} = hg_party:checkout(PartyConfigRef, Revision),
    ShopObj = {_, Shop} = hg_party:get_shop(ShopConfigRef, PartyConfigRef, Revision),
    VS = collect_validation_varset(PartyConfigRef, ShopObj, get_payment(St), #{}),
    Terms = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS),
    #domain_TermSet{payments = PaymentTerms} = Terms,
    log_cascade_attempt_context(PaymentTerms, St),
    get_routing_attempt_limit_value(PaymentTerms#domain_PaymentsServiceTerms.attempt_limit).

log_cascade_attempt_context(
    #domain_PaymentsServiceTerms{attempt_limit = AttemptLimit},
    #st{routes = AttemptedRoutes}
) ->
    ?LOG_MD(notice, "Cascade context: merchant payment terms' attempt limit '~p', attempted routes: ~p", [
        AttemptLimit, AttemptedRoutes
    ]).

get_routing_attempt_limit_value(undefined) ->
    1;
get_routing_attempt_limit_value({decisions, _}) ->
    get_routing_attempt_limit_value(undefined);
get_routing_attempt_limit_value({value, #domain_AttemptLimit{attempts = Value}}) when is_integer(Value) ->
    Value.

save_retry_attempt(Target, #st{retry_attempts = Attempts} = St) ->
    St#st{retry_attempts = maps:update_with(get_target_type(Target), fun(N) -> N + 1 end, 0, Attempts)}.

merge_chargeback_change(Change, ChargebackState) ->
    hg_invoice_payment_chargeback:merge_change(Change, ChargebackState).

merge_adjustment_change(?adjustment_created(Adjustment), undefined) ->
    Adjustment;
merge_adjustment_change(?adjustment_status_changed(Status), Adjustment) ->
    Adjustment#domain_InvoicePaymentAdjustment{status = Status}.

apply_adjustment_effects(Adjustment, St) ->
    apply_adjustment_effect(
        status,
        Adjustment,
        apply_adjustment_effect(cashflow, Adjustment, St)
    ).

apply_adjustment_effect(status, ?adjustment_target_status(Status), St = #st{payment = Payment}) ->
    case Status of
        {captured, Capture} ->
            St#st{
                payment = Payment#domain_InvoicePayment{
                    status = Status,
                    cost = get_captured_cost(Capture, Payment)
                }
            };
        _ ->
            St#st{
                payment = Payment#domain_InvoicePayment{
                    status = Status
                }
            }
    end;
apply_adjustment_effect(status, #domain_InvoicePaymentAdjustment{}, St) ->
    St;
apply_adjustment_effect(cashflow, Adjustment, St) ->
    set_cashflow(get_adjustment_cashflow(Adjustment), St).

-spec validate_transition(activity() | [activity()], change(), st(), change_opts()) -> ok | no_return().
validate_transition(Allowed, Change, St, Opts) ->
    case {Opts, is_transition_valid(Allowed, St)} of
        {#{}, true} ->
            ok;
        {#{validation := strict}, false} ->
            erlang:error({invalid_transition, Change, St, Allowed});
        {#{}, false} ->
            logger:warning(
                "Invalid transition for change ~p in state ~p, allowed ~p",
                [Change, St, Allowed]
            )
    end.

is_transition_valid(Allowed, St) when is_list(Allowed) ->
    lists:any(fun(A) -> is_transition_valid(A, St) end, Allowed);
is_transition_valid(Allowed, #st{activity = Activity}) ->
    Activity =:= Allowed.

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

set_cashflow(Cashflow, St = #st{}) ->
    St#st{
        cash_flow = Cashflow,
        final_cash_flow = Cashflow
    }.

-spec get_final_cashflow(st()) -> final_cash_flow().
get_final_cashflow(#st{final_cash_flow = Cashflow}) ->
    Cashflow.

-spec get_trx(st()) -> trx_info().
get_trx(#st{trx = Trx}) ->
    Trx.

set_trx(undefined, St = #st{}) ->
    St;
set_trx(Trx, St = #st{}) ->
    St#st{trx = Trx}.

try_get_refund_state(ID, #st{refunds = Rs}) ->
    case Rs of
        #{ID := RefundSt} ->
            RefundSt;
        #{} ->
            undefined
    end.

set_chargeback_state(ID, ChargebackSt, St = #st{chargebacks = CBs}) ->
    St#st{chargebacks = CBs#{ID => ChargebackSt}}.

try_get_chargeback_state(ID, #st{chargebacks = CBs}) ->
    case CBs of
        #{ID := ChargebackSt} ->
            ChargebackSt;
        #{} ->
            undefined
    end.

set_refund_state(ID, RefundSt, St = #st{refunds = Rs}) ->
    St#st{refunds = Rs#{ID => RefundSt}}.

-spec get_origin(st() | undefined) -> dmsl_domain_thrift:'InvoicePaymentRegistrationOrigin'() | undefined.
get_origin(#st{payment = #domain_InvoicePayment{registration_origin = Origin}}) ->
    Origin.

get_captured_cost(#domain_InvoicePaymentCaptured{cost = Cost}, _) when Cost /= undefined ->
    Cost;
get_captured_cost(_, #domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_captured_allocation(#domain_InvoicePaymentCaptured{allocation = Allocation}) ->
    Allocation.

-spec create_session_event_context(target(), st(), change_opts()) -> hg_session:event_context().
create_session_event_context(Target, St, Opts = #{invoice_id := InvoiceID}) ->
    #{
        timestamp => define_event_timestamp(Opts),
        target => Target,
        route => get_route(St),
        invoice_id => InvoiceID,
        payment_id => get_payment_id(get_payment(St))
    }.

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

get_refund_created_at(#domain_InvoicePaymentRefund{created_at = CreatedAt}) ->
    CreatedAt.

try_get_adjustment(ID, #st{adjustments = As}) ->
    case lists:keyfind(ID, #domain_InvoicePaymentAdjustment.id, As) of
        V = #domain_InvoicePaymentAdjustment{} ->
            V;
        false ->
            undefined
    end.

set_adjustment(ID, Adjustment, St = #st{adjustments = As}) ->
    St#st{adjustments = lists:keystore(ID, #domain_InvoicePaymentAdjustment.id, As, Adjustment)}.

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
get_session(Target, #st{sessions = Sessions, routes = [Route | _PreviousRoutes]}) ->
    TargetSessions = maps:get(get_target_type(Target), Sessions, []),
    MatchingRoute = fun(#{route := SR}) -> SR =:= Route end,
    case lists:search(MatchingRoute, TargetSessions) of
        {value, Session} -> Session;
        _ -> undefined
    end.

-spec add_session(target(), session(), st()) -> st().
add_session(Target, Session, St = #st{sessions = Sessions}) ->
    TargetType = get_target_type(Target),
    TargetTypeSessions = maps:get(TargetType, Sessions, []),
    St#st{sessions = Sessions#{TargetType => [Session | TargetTypeSessions]}}.

update_session(Target, Session, St = #st{sessions = Sessions}) ->
    TargetType = get_target_type(Target),
    [_ | Rest] = maps:get(TargetType, Sessions, []),
    St#st{sessions = Sessions#{TargetType => [Session | Rest]}}.

get_target(#st{target = Target}) ->
    Target.

get_target_type({Type, _}) when Type == 'processed'; Type == 'captured'; Type == 'cancelled'; Type == 'refunded' ->
    Type.

get_recurrent_token(#st{recurrent_token = Token}) ->
    Token.

-spec get_payment_revision(st()) -> hg_domain:revision().
get_payment_revision(#st{payment = #domain_InvoicePayment{domain_revision = Revision}}) ->
    Revision.

get_payment_payer(#st{payment = #domain_InvoicePayment{payer = Payer}}) ->
    Payer.

%%

get_activity_session(St) ->
    get_activity_session(get_activity(St), St).

-spec get_activity_session(activity(), st()) -> session() | undefined.
get_activity_session({payment, _Step}, St) ->
    get_session(get_target(St), St);
get_activity_session({refund, ID}, St) ->
    Refund = try_get_refund_state(ID, St),
    hg_invoice_payment_refund:session(Refund).

%%

-spec collapse_changes([change()], st() | undefined, change_opts()) -> st() | undefined.
collapse_changes(Changes, St, Opts) ->
    lists:foldl(fun(C, St1) -> merge_change(C, St1, Opts) end, St, Changes).

%%

get_route_provider_ref(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

get_route_provider(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

get_route_provider(Route, Revision) ->
    hg_domain:get(Revision, {provider, get_route_provider_ref(Route)}).

inspect(Payment = #domain_InvoicePayment{domain_revision = Revision}, PaymentInstitution, Opts) ->
    InspectorRef = get_selector_value(inspector, PaymentInstitution#domain_PaymentInstitution.inspector),
    Inspector = hg_domain:get(Revision, {inspector, InspectorRef}),
    hg_inspector:inspect(get_shop(Opts, Revision), get_invoice(Opts), Payment, Inspector).

repair_inspect(Payment, PaymentInstitution, Opts, #st{repair_scenario = Scenario}) ->
    case hg_invoice_repair:check_for_action(skip_inspector, Scenario) of
        {result, Result} ->
            Result;
        call ->
            inspect(Payment, PaymentInstitution, Opts)
    end.

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

get_party_client() ->
    HgContext = hg_context:load(),
    Client = hg_context:get_party_client(HgContext),
    Context = hg_context:get_party_client_context(HgContext),
    {Client, Context}.

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
            filter_attempted_routes(
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
            #{candidates := []}, filter_attempted_routes(hg_routing_ctx:new([]), #st{activity = idle, routes = []})
        ),
        ?_assertMatch(
            #{candidates := [R1, R2, R3]},
            filter_attempted_routes(hg_routing_ctx:new([R1, R2, R3]), #st{activity = idle, routes = []})
        ),
        ?_assertMatch(
            #{candidates := [R1, R2]},
            filter_attempted_routes(
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
            filter_attempted_routes(
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
