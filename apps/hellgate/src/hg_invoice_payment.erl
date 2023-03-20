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
-export([get_route/1]).
-export([get_adjustments/1]).
-export([get_allocation/1]).
-export([get_adjustment/2]).
-export([get_trx/1]).
-export([get_session/2]).

-export([get_final_cashflow/1]).
-export([get_sessions/1]).

-export([get_party_revision/1]).
-export([get_remaining_payment_balance/1]).
-export([get_activity/1]).
-export([get_opts/1]).
-export([get_invoice/1]).
-export([get_origin/1]).
-export([get_risk_score/1]).

-export([construct_payment_info/2]).
-export([set_repair_scenario/2]).

%% Business logic

-export([capture/6]).
-export([cancel/2]).
-export([refund/3]).

-export([manual_refund/3]).

-export([create_adjustment/4]).

-export([create_chargeback/3]).
-export([cancel_chargeback/3]).
-export([reject_chargeback/3]).
-export([accept_chargeback/3]).
-export([reopen_chargeback/3]).

-export([get_merchant_terms/5]).
-export([get_provider_terminal_terms/3]).
-export([calculate_cashflow/10]).

-export([create_session_event_context/3]).
-export([add_session/3]).
-export([accrue_status_timing/3]).

%% Machine like

-export([init/3]).

-export([process_signal/3]).
-export([process_call/3]).
-export([process_timeout/3]).

-export([merge_change/3]).
-export([collapse_changes/3]).

-export([get_log_params/2]).
-export([validate_transition/4]).
-export([construct_payer/2]).

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

-type activity() ::
    payment_activity()
    | refund_activity()
    | adjustment_activity()
    | chargeback_activity()
    | idle.

-type payment_activity() :: {payment, payment_step()}.

-type refund_activity() ::
    {refund_new, refund_id()}
    | {refund_session, refund_id()}
    | {refund_failure, refund_id()}
    | {refund_accounter, refund_id()}.

-type adjustment_activity() ::
    {adjustment_new, adjustment_id()}
    | {adjustment_pending, adjustment_id()}.

-type chargeback_activity() :: {chargeback, chargeback_id(), chargeback_activity_type()}.

-type chargeback_activity_type() :: hg_invoice_payment_chargeback:activity().

-type payment_step() ::
    new
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

-type refund_state() :: #refund_st{}.
-type st() :: #st{}.

-type cash() :: dmsl_domain_thrift:'Cash'().
-type cart() :: dmsl_domain_thrift:'InvoiceCart'().
-type party() :: dmsl_domain_thrift:'Party'().
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
-type route() :: hg_routing:payment_route().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().
-type trx_info() :: dmsl_domain_thrift:'TransactionInfo'().
-type tag() :: dmsl_proxy_provider_thrift:'CallbackTag'().
-type callback() :: dmsl_proxy_provider_thrift:'Callback'().
-type callback_response() :: dmsl_proxy_provider_thrift:'CallbackResponse'().
-type make_recurrent() :: true | false.
-type retry_strategy() :: hg_retry:strategy().
-type capture_data() :: dmsl_payproc_thrift:'InvoicePaymentCaptureData'().
-type payment_session() :: dmsl_payproc_thrift:'InvoicePaymentSession'().
-type failure() :: dmsl_domain_thrift:'OperationFailure'().
-type shop() :: dmsl_domain_thrift:'Shop'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type recurrent_paytool_service_terms() :: dmsl_domain_thrift:'RecurrentPaytoolsServiceTerms'().
-type session() :: hg_session:t().

-type opts() :: #{
    party => party(),
    invoice => invoice(),
    timestamp => hg_datetime:timestamp()
}.

%%

-include("domain.hrl").
-include("payment_events.hrl").

-type change() ::
    dmsl_payproc_thrift:'InvoicePaymentChangePayload'().

%%

-spec get_party_revision(st()) -> {hg_party:party_revision(), hg_datetime:timestamp()}.
get_party_revision(#st{activity = {payment, _}} = St) ->
    #domain_InvoicePayment{party_revision = Revision, created_at = Timestamp} = get_payment(St),
    {Revision, Timestamp};
get_party_revision(#st{activity = {chargeback, ID, _Type}} = St) ->
    CB = hg_invoice_payment_chargeback:get(get_chargeback_state(ID, St)),
    #domain_InvoicePaymentChargeback{party_revision = Revision, created_at = Timestamp} = CB,
    {Revision, Timestamp};
get_party_revision(#st{activity = {_, ID} = Activity} = St) when
    Activity =:= {refund_new, ID} orelse
        Activity =:= {refund_failure, ID} orelse
        Activity =:= {refund_session, ID} orelse
        Activity =:= {refund_accounter, ID}
->
    #domain_InvoicePaymentRefund{party_revision = Revision, created_at = Timestamp} = get_refund(ID, St),
    {Revision, Timestamp};
get_party_revision(#st{activity = {Activity, ID}} = St) when
    Activity =:= adjustment_new orelse
        Activity =:= adjustment_pending
->
    #domain_InvoicePaymentAdjustment{party_revision = Revision, created_at = Timestamp} = get_adjustment(ID, St),
    {Revision, Timestamp};
get_party_revision(#st{activity = Activity}) ->
    erlang:error({no_revision_for_activity, Activity}).

-spec get_payment(st()) -> payment().
get_payment(#st{payment = Payment}) ->
    Payment.

-spec get_risk_score(st()) -> risk_score().
get_risk_score(#st{risk_score = RiskScore}) ->
    RiskScore.

-spec get_route(st()) -> route().
get_route(#st{routes = []}) ->
    undefined;
get_route(#st{routes = [Route|_AttemptedRoutes]}) ->
    Route.

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
get_refunds(#st{refunds = Rs, payment = Payment}) ->
    RefundList = lists:map(
        fun(#refund_st{refund = R, sessions = S, cash_flow = C}) ->
            #payproc_InvoicePaymentRefund{
                refund = enrich_refund_with_cash(R, Payment),
                sessions = lists:map(fun convert_refund_sessions/1, S),
                cash_flow = C
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

convert_refund_sessions(#{trx := TR}) ->
    #payproc_InvoiceRefundSession{
        transaction_info = TR
    }.

-spec get_refund(refund_id(), st()) -> domain_refund() | no_return().
get_refund(ID, St = #st{payment = Payment}) ->
    case try_get_refund_state(ID, St) of
        #refund_st{refund = Refund} ->
            enrich_refund_with_cash(Refund, Payment);
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
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    Invoice = get_invoice(Opts),
    Cost = get_invoice_cost(Invoice),
    {ok, Payer, VS0} = construct_payer(PayerParams, Shop),
    VS1 = collect_validation_varset(Party, Shop, VS0),
    PaymentTool = get_payer_payment_tool(Payer),
    VS2 = VS1#{
        payment_tool => PaymentTool,
        cost => Cost
    },
    Terms = get_merchant_terms(Party, Shop, Revision, CreatedAt, VS2),
    #domain_TermSet{payments = PaymentTerms, recurrent_paytools = RecurrentTerms} = Terms,
    Payment1 = construct_payment(
        PaymentTool,
        PaymentTerms,
        RecurrentTerms,
        PaymentID,
        CreatedAt,
        Cost,
        Payer,
        FlowParams,
        Party,
        Shop,
        VS2,
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
    %% TODO/FIXME: Explicitly allow only 'value' option of `dmsl_domain_thrift:'AttemptLimitSelector'()`
    %% TODO: make a func
    AttemptsLimit = case PaymentTerms#domain_PaymentsServiceTerms.attempt_limit of
        {value, #domain_AttemptLimit{attempts = Value}} when is_integer(Value) -> Value;
        undefined -> 1 % Default attempt limit is obvious '1'
    end,
    ChangeOpts = #{route_attempt_limit => AttemptsLimit},
    {collapse_changes(Events, undefined, ChangeOpts), {Events, hg_machine_action:instant()}}.

get_merchant_payments_terms(Opts, Revision, Timestamp, VS) ->
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    TermSet = get_merchant_terms(Party, Shop, Revision, Timestamp, VS),
    TermSet#domain_TermSet.payments.

-spec get_merchant_terms(party(), shop(), hg_domain:revision(), hg_datetime:timestamp(), hg_varset:varset()) ->
    dmsl_domain_thrift:'TermSet'().
get_merchant_terms(Party, Shop, DomainRevision, Timestamp, VS) ->
    ContractID = Shop#domain_Shop.contract_id,
    Contract = hg_party:get_contract(ContractID, Party),
    ok = assert_contract_active(Contract),
    PreparedVS = hg_varset:prepare_contract_terms_varset(VS),
    {Client, Context} = get_party_client(),
    {ok, Terms} = party_client_thrift:compute_contract_terms(
        Party#domain_Party.id,
        ContractID,
        Timestamp,
        {revision, Party#domain_Party.revision},
        DomainRevision,
        PreparedVS,
        Client,
        Context
    ),
    Terms.

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

assert_contract_active(#domain_Contract{status = {active, _}}) ->
    ok;
assert_contract_active(#domain_Contract{status = Status}) ->
    throw(#payproc_InvalidContractStatus{status = Status}).

-spec construct_payer(payer_params(), shop()) -> {ok, payer(), map()}.
construct_payer(
    {payment_resource, #payproc_PaymentResourcePayerParams{
        resource = Resource,
        contact_info = ContactInfo
    }},
    _
) ->
    {ok, ?payment_resource_payer(Resource, ContactInfo), #{}};
construct_payer(
    {recurrent, #payproc_RecurrentPayerParams{
        recurrent_parent = Parent,
        contact_info = ContactInfo
    }},
    _
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
    {ok, ?recurrent_payer(ParentPaymentTool, Parent, ContactInfo), #{parent_payment => ParentPayment}};
construct_payer({customer, #payproc_CustomerPayerParams{customer_id = CustomerID}}, Shop) ->
    Customer = get_customer(CustomerID),
    ok = validate_customer_shop(Customer, Shop),
    ActiveBinding = get_active_binding(Customer),
    % by keynfawkes
    % TODO Should we bake recurrent token right in too?
    %      Expect to have some issues related to access control while trying
    %      to fetch this token during deeper payment flow stages
    % by antibi0tic
    % we dont need it for refund, so I think - no
    Payer = ?customer_payer(
        CustomerID,
        ActiveBinding#payproc_CustomerBinding.id,
        ActiveBinding#payproc_CustomerBinding.rec_payment_tool_id,
        get_resource_payment_tool(ActiveBinding#payproc_CustomerBinding.payment_resource),
        get_customer_contact_info(Customer)
    ),
    {ok, Payer, #{}}.

validate_customer_shop(#payproc_Customer{shop_id = ShopID}, #domain_Shop{id = ShopID}) ->
    ok;
validate_customer_shop(_, _) ->
    throw_invalid_request(<<"Invalid customer">>).

get_active_binding(#payproc_Customer{bindings = Bindings, active_binding_id = BindingID}) ->
    case lists:keysearch(BindingID, #payproc_CustomerBinding.id, Bindings) of
        {value, ActiveBinding} ->
            ActiveBinding;
        false ->
            throw_invalid_request(<<"Specified customer is not ready">>)
    end.

get_customer_contact_info(#payproc_Customer{contact_info = ContactInfo}) ->
    ContactInfo.

construct_payment(
    PaymentTool,
    PaymentTerms,
    RecurrentTerms,
    PaymentID,
    CreatedAt,
    Cost,
    Payer,
    FlowParams,
    Party,
    Shop,
    VS,
    Revision,
    MakeRecurrent
) ->
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
    ParentPayment = maps:get(parent_payment, VS, undefined),
    ok = validate_recurrent_intention(Payer, RecurrentTerms, PaymentTool, Shop, ParentPayment, MakeRecurrent),
    #domain_InvoicePayment{
        id = PaymentID,
        created_at = CreatedAt,
        owner_id = Party#domain_Party.id,
        shop_id = Shop#domain_Shop.id,
        domain_revision = Revision,
        party_revision = Party#domain_Party.revision,
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
    get_predefined_recurrent_route(Payer);
get_predefined_route(?customer_payer() = Payer) ->
    get_predefined_customer_route(Payer).

-spec get_predefined_customer_route(payer()) -> {ok, route()} | undefined.
get_predefined_customer_route(?customer_payer(_, _, RecPaymentToolID, _, _) = Payer) ->
    case get_rec_payment_tool(RecPaymentToolID) of
        {ok, #payproc_RecurrentPaymentTool{
            route = Route
        }} when Route =/= undefined ->
            {ok, Route};
        _ ->
            % TODO more elegant error
            error({'Can\'t get route for customer payer', Payer})
    end.

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
    shop(),
    payment(),
    make_recurrent()
) -> ok | no_return().
validate_recurrent_intention(
    ?recurrent_payer() = Payer,
    RecurrentTerms,
    PaymentTool,
    Shop,
    ParentPayment,
    MakeRecurrent
) ->
    ok = validate_recurrent_terms(RecurrentTerms, PaymentTool),
    ok = validate_recurrent_payer(Payer, MakeRecurrent),
    ok = validate_recurrent_parent(Shop, ParentPayment);
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
                logger:info("PaymentTool: ~p", [PaymentTool]),
                logger:info("RecurrentPaymentMethods: ~p", [PMs]),
                throw_invalid_request(<<"Invalid payment method">>);
            true ->
                ok
        end,
    ok.

-spec validate_recurrent_parent(shop(), st()) -> ok | no_return().
validate_recurrent_parent(Shop, ParentPayment) ->
    ok = validate_recurrent_token_present(ParentPayment),
    ok = validate_recurrent_parent_shop(Shop, ParentPayment),
    ok = validate_recurrent_parent_status(ParentPayment).

-spec validate_recurrent_token_present(st()) -> ok | no_return().
validate_recurrent_token_present(PaymentState) ->
    case get_recurrent_token(PaymentState) of
        Token when Token =/= undefined ->
            ok;
        undefined ->
            throw_invalid_recurrent_parent(<<"Parent payment has no recurrent token">>)
    end.

-spec validate_recurrent_parent_shop(shop(), st()) -> ok | no_return().
validate_recurrent_parent_shop(Shop, PaymentState) ->
    PaymentShopID = get_payment_shop_id(get_payment(PaymentState)),
    case Shop of
        #domain_Shop{id = ShopID} when ShopID =:= PaymentShopID ->
            ok;
        _Other ->
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
    PartyID = Payment#domain_InvoicePayment.owner_id,
    Payer = get_payment_payer(St),
    PaymentTool = get_payer_payment_tool(Payer),
    ClientIP = get_payer_client_ip(Payer),
    case
        hg_routing:gather_routes(
            Predestination,
            PaymentInstitution,
            VS,
            Revision,
            #{
                currency => Currency,
                payment_tool => PaymentTool,
                party_id => PartyID,
                client_ip => ClientIP
            }
        )
    of
        {ok, {[], RejectedRoutes}} ->
            _ = log_rejected_routes(no_route_found, RejectedRoutes, VS),
            throw({no_route_found, unknown});
        {ok, {Routes, RejectedRoutes}} ->
            erlang:length(RejectedRoutes) > 0 andalso
                log_rejected_routes(rejected_route_found, RejectedRoutes, VS),
            Routes;
        {error, {misconfiguration, _Reason} = Error} ->
            _ = log_misconfigurations(Error),
            throw({no_route_found, unknown})
    end.

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

log_route_choice_meta(ChoiceMeta, Revision) ->
    Metadata = hg_routing:get_logger_metadata(ChoiceMeta, Revision),
    _ = logger:log(info, "Routing decision made", #{routing => Metadata}).

log_misconfigurations({misconfiguration, _} = Error) ->
    {Format, Details} = hg_routing:prepare_log_message(Error),
    _ = logger:warning(Format, Details),
    ok.

log_rejected_routes(no_route_found, RejectedRoutes, Varset) ->
    _ = logger:log(
        warning,
        "No route found for varset: ~p",
        [Varset],
        logger:get_process_metadata()
    ),
    _ = logger:log(
        warning,
        "No route found, rejected routes: ~p",
        [RejectedRoutes],
        logger:get_process_metadata()
    ),
    ok;
log_rejected_routes(rejected_route_found, RejectedRoutes, Varset) ->
    _ = logger:log(
        info,
        "Rejected routes found for varset: ~p",
        [Varset],
        logger:get_process_metadata()
    ),
    _ = logger:log(
        info,
        "Rejected routes found, rejected routes: ~p",
        [RejectedRoutes],
        logger:get_process_metadata()
    ),
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
    collect_validation_varset(get_party(Opts), get_shop(Opts), get_payment(St), #{}).

collect_validation_varset(Party, Shop, VS) ->
    #domain_Party{id = PartyID} = Party,
    #domain_Shop{
        id = ShopID,
        category = Category,
        account = #domain_ShopAccount{currency = Currency}
    } = Shop,
    VS#{
        party_id => PartyID,
        shop_id => ShopID,
        category => Category,
        currency => Currency
    }.

collect_validation_varset(Party, Shop, Payment, VS) ->
    VS0 = collect_validation_varset(Party, Shop, VS),
    VS0#{
        cost => get_payment_cost(Payment),
        payment_tool => get_payment_tool(Payment)
    }.

%%

construct_final_cashflow(Cashflow, Context, AccountMap) ->
    hg_cashflow:finalize(Cashflow, Context, AccountMap).

collect_cash_flow_context(
    #domain_InvoicePayment{cost = Cost}
) ->
    #{
        operation_amount => Cost
    };
collect_cash_flow_context(
    #domain_InvoicePaymentRefund{cash = Cash}
) ->
    #{
        operation_amount => Cash
    }.

get_available_amount(AccountID) ->
    #{
        min_available_amount := AvailableAmount
    } =
        hg_accounting:get_balance(AccountID),
    AvailableAmount.

construct_payment_plan_id(St) ->
    construct_payment_plan_id(get_invoice(get_opts(St)), get_payment(St)).

construct_payment_plan_id(Invoice, Payment) ->
    hg_utils:construct_complex_id([
        get_invoice_id(Invoice),
        get_payment_id(Payment)
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

-spec capture(st(), binary(), cash() | undefined, cart() | undefined, hg_allocation:allocation_prototype(), opts()) ->
    {ok, result()}.
capture(St, Reason, Cost, Cart, AllocationPrototype, Opts) ->
    Payment = get_payment(St),
    _ = assert_capture_cost_currency(Cost, Payment),
    _ = assert_capture_cart(Cost, Cart),
    _ = assert_activity({payment, flow_waiting}, St),
    _ = assert_payment_flow(hold, Payment),
    Revision = get_payment_revision(St),
    Timestamp = get_payment_created_at(Payment),
    VS = collect_validation_varset(St, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, Timestamp, VS),
    CaptureCost = genlib:define(Cost, get_payment_cost(Payment)),
    #domain_Invoice{allocation = Allocation} = get_invoice(Opts),
    Allocation = genlib:define(maybe_allocation(AllocationPrototype, CaptureCost, MerchantTerms, Opts), Allocation),
    case check_equal_capture_cost_amount(Cost, Payment) of
        true ->
            total_capture(St, Reason, Cart, Allocation);
        false ->
            partial_capture(St, Reason, Cost, Cart, Opts, MerchantTerms, Timestamp, Allocation)
    end.

maybe_allocation(undefined, _Cost, _MerchantTerms, _Opts) ->
    undefined;
maybe_allocation(AllocationPrototype, Cost, MerchantTerms, Opts) ->
    #domain_PaymentsServiceTerms{
        allocations = AllocationSelector
    } = MerchantTerms,
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    case
        hg_allocation:calculate(
            AllocationPrototype,
            Party,
            Shop,
            Cost,
            AllocationSelector
        )
    of
        {ok, A} ->
            A;
        {error, allocation_not_allowed} ->
            throw(#payproc_AllocationNotAllowed{});
        {error, amount_exceeded} ->
            throw(#payproc_AllocationExceededPaymentAmount{});
        {error, {invalid_transaction, Transaction, Details}} ->
            throw(#payproc_AllocationInvalidTransaction{
                transaction = marshal_transaction(Transaction),
                reason = marshal_allocation_details(Details)
            })
    end.

marshal_transaction(#domain_AllocationTransaction{} = T) ->
    {transaction, T};
marshal_transaction(#domain_AllocationTransactionPrototype{} = TP) ->
    {transaction_prototype, TP}.

marshal_allocation_details(negative_amount) ->
    <<"Transaction amount is negative">>;
marshal_allocation_details(zero_amount) ->
    <<"Transaction amount is zero">>;
marshal_allocation_details(target_conflict) ->
    <<"Transaction with similar target">>;
marshal_allocation_details(currency_mismatch) ->
    <<"Transaction currency mismatch">>;
marshal_allocation_details(payment_institutions_mismatch) ->
    <<"Transaction target shop Payment Institution mismatch">>.

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
    FinalCashflow =
        calculate_cashflow(Route, Payment2, ProviderTerms, MerchantTerms, VS, Revision, Opts, Timestamp, Allocation),
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
    Changes = [?refund_created(Refund, FinalCashflow)],
    Action = hg_machine_action:instant(),
    ID = Refund#domain_InvoicePaymentRefund.id,
    {Refund, {[?refund_ev(ID, C) || C <- Changes], Action}}.

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
    Changes = [?refund_created(Refund, FinalCashflow, TransactionInfo)],
    Action = hg_machine_action:instant(),
    ID = Refund#domain_InvoicePaymentRefund.id,
    {Refund, {[?refund_ev(ID, C) || C <- Changes], Action}}.

make_refund(Params, Payment, Revision, CreatedAt, St, Opts) ->
    _ = assert_no_pending_chargebacks(St),
    _ = assert_payment_status(captured, Payment),
    PartyRevision = get_opts_party_revision(Opts),
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
        Opts
    ),
    ok = validate_allocation_refund(Allocation, St),
    MerchantRefundTerms = get_merchant_refunds_terms(MerchantTerms),
    Refund = #domain_InvoicePaymentRefund{
        id = Params#payproc_InvoicePaymentRefundParams.id,
        created_at = CreatedAt,
        domain_revision = Revision,
        party_revision = PartyRevision,
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
    ok;
validate_allocation_refund(SubAllocation, St) ->
    Allocation =
        case get_allocation(St) of
            undefined ->
                throw(#payproc_AllocationNotFound{});
            A ->
                A
        end,
    case hg_allocation:sub(Allocation, SubAllocation) of
        {ok, _} ->
            ok;
        {error, {invalid_transaction, Transaction, Details}} ->
            throw(#payproc_AllocationInvalidTransaction{
                transaction = marshal_transaction(Transaction),
                reason = marshal_allocation_sub_details(Details)
            })
    end.

marshal_allocation_sub_details(negative_amount) ->
    <<"Transaction amount is negative">>;
marshal_allocation_sub_details(currency_mismatch) ->
    <<"Transaction currency mismatch">>;
marshal_allocation_sub_details(no_transaction_to_sub) ->
    <<"No transaction to refund">>.

make_refund_cashflow(Refund, Payment, Revision, St, Opts, MerchantTerms, VS, Timestamp) ->
    Route = get_route(St),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    ProviderPaymentsTerms = get_provider_terminal_terms(Route, VS, Revision),
    ProviderTerms = get_provider_refunds_terms(ProviderPaymentsTerms, Refund, Payment),
    Allocation = Refund#domain_InvoicePaymentRefund.allocation,
    Provider = get_route_provider(Route, Revision),
    collect_cashflow(
        refund,
        ProviderTerms,
        MerchantTerms,
        Party,
        Shop,
        Route,
        Allocation,
        Payment,
        Refund,
        Provider,
        Timestamp,
        VS,
        Revision
    ).

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

collect_cashflow(
    OpType,
    ProvisionTerms,
    MerchantTerms,
    Party,
    Shop,
    Route,
    Allocation,
    Payment,
    ContextSource,
    Provider,
    Timestamp,
    VS,
    Revision
) ->
    PaymentInstitution = get_cashflow_payment_institution(Party, Shop, VS, Revision),
    collect_cashflow(
        OpType,
        ProvisionTerms,
        MerchantTerms,
        Party,
        Shop,
        PaymentInstitution,
        Route,
        Allocation,
        Payment,
        ContextSource,
        Provider,
        Timestamp,
        VS,
        Revision
    ).

collect_cashflow(
    OpType,
    ProvisionTerms,
    MerchantTerms,
    Party,
    Shop,
    PaymentInstitution,
    Route,
    undefined,
    Payment,
    ContextSource,
    Provider,
    Timestamp,
    VS,
    Revision
) ->
    Amount = get_context_source_amount(ContextSource),
    PaymentInstitution = get_cashflow_payment_institution(Party, Shop, VS, Revision),
    CF = construct_transaction_cashflow(
        OpType,
        Party,
        Shop,
        PaymentInstitution,
        Route,
        Amount,
        MerchantTerms,
        Timestamp,
        Payment,
        Provider,
        VS,
        Revision
    ),
    ProviderCashflowSelector = get_provider_cashflow_selector(ProvisionTerms),
    ProviderCashflow = construct_provider_cashflow(
        ProviderCashflowSelector,
        PaymentInstitution,
        Party,
        Shop,
        Route,
        ContextSource,
        Payment,
        Provider,
        VS,
        Revision
    ),
    CF ++ ProviderCashflow;
collect_cashflow(
    OpType,
    ProvisionTerms,
    _MerchantTerms,
    Party,
    Shop,
    PaymentInstitution,
    Route,
    ?allocation(Transactions),
    Payment,
    ContextSource,
    Provider,
    Timestamp,
    VS0,
    Revision
) ->
    CF = lists:foldl(
        fun(?allocation_trx(_ID, Target, Amount), Acc) ->
            ?allocation_trx_target_shop(PartyID, ShopID) = Target,
            TargetParty = hg_party:get_party(PartyID),
            TargetShop = hg_party:get_shop(ShopID, TargetParty),
            VS1 = VS0#{
                party_id => Party#domain_Party.id,
                shop_id => Shop#domain_Shop.id,
                cost => Amount
            },
            AllocationPaymentInstitution =
                get_cashflow_payment_institution(Party, Shop, VS1, Revision),
            construct_transaction_cashflow(
                OpType,
                TargetParty,
                TargetShop,
                AllocationPaymentInstitution,
                Route,
                Amount,
                undefined,
                Timestamp,
                Payment,
                Provider,
                VS1,
                Revision
            ) ++ Acc
        end,
        [],
        Transactions
    ),
    ProviderCashflowSelector = get_provider_cashflow_selector(ProvisionTerms),
    ProviderCashflow = construct_provider_cashflow(
        ProviderCashflowSelector,
        PaymentInstitution,
        Party,
        Shop,
        Route,
        ContextSource,
        Payment,
        Provider,
        VS0,
        Revision
    ),
    CF ++ ProviderCashflow.

get_cashflow_payment_institution(Party, Shop, VS, Revision) ->
    Contract = hg_party:get_contract(Shop#domain_Shop.contract_id, Party),
    PaymentInstitutionRef = Contract#domain_Contract.payment_institution,
    hg_payment_institution:compute_payment_institution(
        PaymentInstitutionRef,
        VS,
        Revision
    ).

get_context_source_amount(#domain_InvoicePayment{cost = Cost}) ->
    Cost;
get_context_source_amount(#domain_InvoicePaymentRefund{cash = Cash}) ->
    Cash.

get_provider_cashflow_selector(#domain_PaymentsProvisionTerms{cash_flow = ProviderCashflowSelector}) ->
    ProviderCashflowSelector;
get_provider_cashflow_selector(#domain_PaymentRefundsProvisionTerms{cash_flow = ProviderCashflowSelector}) ->
    ProviderCashflowSelector.

construct_transaction_cashflow(
    OpType,
    Party,
    Shop,
    PaymentInstitution,
    Route,
    Amount,
    MerchantPaymentsTerms0,
    Timestamp,
    Payment,
    Provider,
    VS,
    Revision
) ->
    MerchantPaymentsTerms1 =
        case MerchantPaymentsTerms0 of
            undefined ->
                TermSet = get_merchant_terms(Party, Shop, Revision, Timestamp, VS),
                TermSet#domain_TermSet.payments;
            _ ->
                MerchantPaymentsTerms0
        end,
    MerchantCashflowSelector = get_terms_cashflow(OpType, MerchantPaymentsTerms1),
    MerchantCashflow = get_selector_value(merchant_payment_fees, MerchantCashflowSelector),
    AccountMap = hg_accounting:collect_account_map(
        Payment,
        Party,
        Shop,
        Route,
        PaymentInstitution,
        Provider,
        VS,
        Revision
    ),
    Context = #{
        operation_amount => Amount
    },
    construct_final_cashflow(MerchantCashflow, Context, AccountMap).

get_terms_cashflow(payment, MerchantPaymentsTerms) ->
    MerchantPaymentsTerms#domain_PaymentsServiceTerms.fees;
get_terms_cashflow(refund, MerchantPaymentsTerms) ->
    MerchantRefundTerms = MerchantPaymentsTerms#domain_PaymentsServiceTerms.refunds,
    MerchantRefundTerms#domain_PaymentRefundsServiceTerms.fees.

construct_provider_cashflow(
    ProviderCashflowSelector,
    PaymentInstitution,
    Party,
    Shop,
    Route,
    ContextSource,
    Payment,
    Provider,
    VS,
    Revision
) ->
    ProviderCashflow = get_selector_value(provider_payment_cash_flow, ProviderCashflowSelector),
    Context = collect_cash_flow_context(ContextSource),
    AccountMap = hg_accounting:collect_account_map(
        Payment,
        Party,
        Shop,
        Route,
        PaymentInstitution,
        Provider,
        VS,
        Revision
    ),
    construct_final_cashflow(ProviderCashflow, Context, AccountMap).

prepare_refund_cashflow(RefundSt, St) ->
    hg_accounting:hold(construct_refund_plan_id(RefundSt, St), get_refund_cashflow_plan(RefundSt)).

commit_refund_cashflow(RefundSt, St) ->
    hg_accounting:commit(construct_refund_plan_id(RefundSt, St), [get_refund_cashflow_plan(RefundSt)]).

rollback_refund_cashflow(RefundSt, St) ->
    hg_accounting:rollback(construct_refund_plan_id(RefundSt, St), [get_refund_cashflow_plan(RefundSt)]).

construct_refund_plan_id(RefundSt, St) ->
    hg_utils:construct_complex_id([
        get_invoice_id(get_invoice(get_opts(St))),
        get_payment_id(get_payment(St)),
        {refund_session, get_refund_id(get_refund(RefundSt))}
    ]).

get_refund_cashflow_plan(RefundSt) ->
    {1, get_refund_cashflow(RefundSt)}.

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
    _ = assert_payment_status([captured, refunded, charged_back], Payment),
    NewRevision = maybe_get_domain_revision(DomainRevision),
    PartyRevision = get_opts_party_revision(Opts),
    OldCashFlow = get_final_cashflow(St),
    VS = collect_validation_varset(St, Opts),
    Allocation = get_allocation(St),
    NewCashFlow = calculate_cashflow(Route, Payment, Timestamp, VS, NewRevision, Opts, Allocation),
    AdjState =
        {cash_flow, #domain_InvoicePaymentAdjustmentCashFlowState{
            scenario = #domain_InvoicePaymentAdjustmentCashFlow{domain_revision = DomainRevision}
        }},
    construct_adjustment(
        Timestamp,
        Params,
        NewRevision,
        PartyRevision,
        OldCashFlow,
        NewCashFlow,
        AdjState,
        St
    ).

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
        domain_revision = DomainRevision,
        party_revision = PartyRevision
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
        PartyRevision,
        OldCashFlow,
        NewCashFlow,
        AdjState,
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
    Payment = Payment0#domain_InvoicePayment{
        cost = Cost
    },
    Timestamp = get_payment_created_at(Payment),
    St = St0#st{payment = Payment},
    Revision = Payment#domain_InvoicePayment.domain_revision,
    VS = collect_validation_varset(St, Opts),
    calculate_cashflow(Route, Payment, Timestamp, VS, Revision, Opts, Allocation);
get_cash_flow_for_target_status({cancelled, _}, _St, _Opts) ->
    [];
get_cash_flow_for_target_status({failed, _}, _St, _Opts) ->
    [].

-spec calculate_cashflow(
    route(),
    payment(),
    hg_datetime:timestamp(),
    hg_varset:varset(),
    hg_domain:revision(),
    opts(),
    hg_allocation:allocation()
) -> final_cash_flow().
calculate_cashflow(Route, Payment, Timestamp, VS, Revision, Opts, Allocation) ->
    ProviderTerms = get_provider_terminal_terms(Route, VS, Revision),
    calculate_cashflow(Route, Payment, ProviderTerms, undefined, VS, Revision, Opts, Timestamp, Allocation).

-spec calculate_cashflow(
    route(),
    payment(),
    dmsl_domain_thrift:'PaymentsProvisionTerms'() | undefined,
    dmsl_domain_thrift:'PaymentsServiceTerms'() | undefined,
    hg_varset:varset(),
    hg_domain:revision(),
    opts(),
    hg_datetime:timestamp(),
    hg_allocation:allocation()
) -> final_cash_flow().
calculate_cashflow(Route, Payment, ProviderTerms, MerchantTerms, VS, Revision, Opts, Timestamp, Allocation) ->
    Provider = get_route_provider(Route, Revision),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    collect_cashflow(
        payment,
        ProviderTerms,
        MerchantTerms,
        Party,
        Shop,
        Route,
        Allocation,
        Payment,
        Payment,
        Provider,
        Timestamp,
        VS,
        Revision
    ).

-spec calculate_cashflow(
    route(),
    payment(),
    hg_payment_institution:t(),
    dmsl_domain_thrift:'PaymentsProvisionTerms'(),
    dmsl_domain_thrift:'PaymentsServiceTerms'(),
    hg_varset:varset(),
    hg_domain:revision(),
    opts(),
    hg_datetime:timestamp(),
    hg_allocation:allocation() | undefined
) -> final_cash_flow().
calculate_cashflow(
    Route, Payment, PaymentInstitution, ProviderTerms, MerchantTerms, VS, Revision, Opts, Timestamp, Allocation
) ->
    Provider = get_route_provider(Route, Revision),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    collect_cashflow(
        payment,
        ProviderTerms,
        MerchantTerms,
        Party,
        Shop,
        PaymentInstitution,
        Route,
        Allocation,
        Payment,
        Payment,
        Provider,
        Timestamp,
        VS,
        Revision
    ).

-spec construct_adjustment(
    Timestamp :: hg_datetime:timestamp(),
    Params :: adjustment_params(),
    DomainRevision :: hg_domain:revision(),
    PartyRevision :: hg_party:party_revision(),
    OldCashFlow :: final_cash_flow(),
    NewCashFlow :: final_cash_flow(),
    State :: adjustment_state(),
    St :: st()
) -> {adjustment(), result()}.
construct_adjustment(
    Timestamp,
    Params,
    DomainRevision,
    PartyRevision,
    OldCashFlow,
    NewCashFlow,
    State,
    St
) ->
    ID = construct_adjustment_id(St),
    Adjustment = #domain_InvoicePaymentAdjustment{
        id = ID,
        status = ?adjustment_pending(),
        created_at = Timestamp,
        domain_revision = DomainRevision,
        party_revision = PartyRevision,
        reason = Params#payproc_InvoicePaymentAdjustmentParams.reason,
        old_cash_flow_inverse = hg_cashflow:revert(OldCashFlow),
        new_cash_flow = NewCashFlow,
        state = State
    },
    Event = ?adjustment_ev(ID, ?adjustment_created(Adjustment)),
    {Adjustment, {[Event], hg_machine_action:instant()}}.

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
process_timeout({refund_new, ID}, Action, St) ->
    process_refund_cashflow(ID, Action, St);
process_timeout({refund_session, _ID}, _Action, St) ->
    process_session(St);
process_timeout({refund_failure, _ID}, Action, St) ->
    process_result(Action, St);
process_timeout({refund_accounter, _ID}, Action, St) ->
    process_result(Action, St);
process_timeout({adjustment_new, ID}, Action, St) ->
    process_adjustment_cashflow(ID, Action, St);
process_timeout({adjustment_pending, ID}, Action, St) ->
    process_adjustment_capture(ID, Action, St);
process_timeout({payment, flow_waiting}, Action, St) ->
    finalize_payment(Action, St).

repair_process_timeout(Activity, Action, St = #st{repair_scenario = Scenario}) ->
    case hg_invoice_repair:check_for_action(fail_pre_processing, Scenario) of
        {result, Result} ->
            Result;
        call ->
            process_timeout(Activity, Action, St)
    end.

-spec process_call({callback, tag(), callback()}, st(), opts()) -> {callback_response(), machine_result()}.
process_call({callback, Tag, Payload}, St, Options) ->
    scoper:scope(
        payment,
        get_st_meta(St),
        fun() -> process_callback(Tag, Payload, St#st{opts = Options}) end
    ).

-spec process_callback(tag(), callback(), st()) -> {callback_response(), machine_result()}.
process_callback(Tag, Payload, St) ->
    Session = get_activity_session(St),
    process_callback(Tag, Payload, Session, St).

process_callback(Tag, Payload, Session, St) when Session /= undefined ->
    case {hg_session:status(Session), hg_session:tags(Session)} of
        {suspended, [Tag | _]} ->
            handle_callback(Payload, Session, St);
        _ ->
            throw(invalid_callback)
    end;
process_callback(_Tag, _Payload, undefined, _St) ->
    throw(invalid_callback).

%%
-spec process_risk_score(action(), st()) -> machine_result().
process_risk_score(Action, St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    VS1 = get_varset(St, #{}),
    PaymentInstitutionRef = get_payment_institution_ref(Opts),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    RiskScore = repair_inspect(Payment, PaymentInstitution, Opts, St),
    Events = [?risk_score_changed(RiskScore)],
    case check_risk_score(RiskScore) of
        ok ->
            {next, {Events, hg_machine_action:set_timeout(0, Action)}};
        {error, risk_score_is_too_high = Reason} ->
            logger:info("No route found, reason = ~p, varset: ~p", [Reason, VS1]),
            handle_choose_route_error(Reason, Events, St, Action)
    end.

-spec process_routing(action(), st()) -> machine_result().
process_routing(Action, St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    #{payment_tool := PaymentTool} = VS1 = get_varset(St, #{risk_score => get_risk_score(St)}),
    CreatedAt = get_payment_created_at(Payment),
    PaymentInstitutionRef = get_payment_institution_ref(Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS1),
    VS2 = collect_refund_varset(
        MerchantTerms#domain_PaymentsServiceTerms.refunds,
        PaymentTool,
        VS1
    ),
    VS3 = collect_chargeback_varset(
        MerchantTerms#domain_PaymentsServiceTerms.chargebacks,
        VS2
    ),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    try
        Payer = get_payment_payer(St),
        Routes0 =
            case get_predefined_route(Payer) of
                {ok, PaymentRoute} ->
                    [hg_routing:from_payment_route(PaymentRoute)];
                undefined ->
                    gather_routes(PaymentInstitution, VS3, Revision, St)
            end,
        Routes1 = filter_out_attempted_routes(Routes0, St),
        Events = handle_gathered_route_result(
            filter_limit_overflow_routes(Routes1, VS3, St),
            [hg_routing:to_payment_route(R) || R <- Routes1],
            Revision
        ),
        {next, {Events, hg_machine_action:set_timeout(0, Action)}}
    catch
        throw:{no_route_found, Reason} ->
            handle_choose_route_error(Reason, [], St, Action)
    end.

filter_out_attempted_routes(Routes, #st{routes = AttemptedRoutes}) ->
    Routes -- AttemptedRoutes.

handle_gathered_route_result({ok, RoutesNoOverflow}, Routes, Revision) ->
    {ChoosenRoute, ChoiceContext} = hg_routing:choose_route(RoutesNoOverflow),
    _ = log_route_choice_meta(ChoiceContext, Revision),
    [?route_changed(hg_routing:to_payment_route(ChoosenRoute), ordsets:from_list(Routes))];
handle_gathered_route_result({error, not_found}, Routes, _) ->
    Failure =
        {failure,
            payproc_errors:construct(
                'PaymentFailure',
                {no_route_found, {forbidden, #payproc_error_GeneralFailure{}}}
            )},
    [Route | _] = Routes,
    %% For protocol compatability we set choosen route in route_changed event.
    %% It doesn't influence cash_flow building because this step will be skipped. And all limit's 'hold' operations
    %% will be rolled back.
    [?route_changed(Route, ordsets:from_list(Routes)), ?payment_rollback_started(Failure)].

handle_choose_route_error(Reason, Events, St, Action) ->
    Failure =
        {failure,
            payproc_errors:construct(
                'PaymentFailure',
                {no_route_found, {Reason, #payproc_error_GeneralFailure{}}}
            )},
    process_failure(get_activity(St), Events, Action, Failure, St).

-spec process_cash_flow_building(action(), st()) -> machine_result().
process_cash_flow_building(Action, St) ->
    Route = get_route(St),
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    Route = get_route(St),
    Timestamp = get_payment_created_at(Payment),
    VS0 = reconstruct_payment_flow(Payment, #{}),
    VS1 = collect_validation_varset(get_party(Opts), get_shop(Opts), Payment, VS0),
    ProviderTerms = get_provider_terminal_terms(Route, VS1, Revision),
    Allocation = get_allocation(St),
    FinalCashflow = calculate_cashflow(
        Route,
        Payment,
        ProviderTerms,
        undefined,
        VS1,
        Revision,
        Opts,
        Timestamp,
        Allocation
    ),
    _ = rollback_unused_payment_limits(St),
    _Clock = hg_accounting:hold(
        construct_payment_plan_id(Invoice, Payment),
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
    {Changes, Action1} = hg_invoice_payment_chargeback:process_timeout(Type, ChargebackState, Action0, ChargebackOpts),
    {done, {[?chargeback_ev(ID, C) || C <- Changes], Action1}}.

maybe_set_charged_back_status(?chargeback_status_accepted(), ChargebackBody, St) ->
    InterimPaymentAmount = get_remaining_payment_balance(St),
    case hg_cash:sub(InterimPaymentAmount, ChargebackBody) of
        ?cash(0, _) ->
            [?payment_status_changed(?charged_back())];
        ?cash(Amount, _) when Amount > 0 ->
            []
    end;
maybe_set_charged_back_status(_ChargebackStatus, _ChargebackBody, _St) ->
    [].

%%

-spec process_refund_cashflow(refund_id(), action(), st()) -> machine_result().
process_refund_cashflow(ID, Action, St) ->
    Opts = get_opts(St),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    RefundSt = try_get_refund_state(ID, St),
    hold_refund_limits(RefundSt, St),

    #{{merchant, settlement} := SettlementID} = hg_accounting:collect_merchant_account_map(Party, Shop, #{}),
    _ = prepare_refund_cashflow(RefundSt, St),
    % NOTE we assume that posting involving merchant settlement account MUST be present in the cashflow
    case get_available_amount(SettlementID) of
        % TODO we must pull this rule out of refund terms
        Available when Available >= 0 ->
            Events = start_session(?refunded()) ++ get_manual_refund_events(RefundSt),
            {next, {
                [?refund_ev(ID, C) || C <- Events],
                hg_machine_action:set_timeout(0, Action)
            }};
        _ ->
            Failure =
                {failure,
                    payproc_errors:construct(
                        'RefundFailure',
                        {terms_violated, {insufficient_merchant_funds, #payproc_error_GeneralFailure{}}}
                    )},
            process_failure(get_activity(St), [], Action, Failure, St, RefundSt)
    end.

get_manual_refund_events(#refund_st{transaction_info = undefined}) ->
    [];
get_manual_refund_events(#refund_st{transaction_info = TransactionInfo}) ->
    [
        ?session_ev(?refunded(), ?trx_bound(TransactionInfo)),
        ?session_ev(?refunded(), ?session_finished(?session_succeeded()))
    ].

%%

-spec process_adjustment_cashflow(adjustment_id(), action(), st()) -> machine_result().
process_adjustment_cashflow(ID, _Action, St) ->
    Opts = get_opts(St),
    Adjustment = get_adjustment(ID, St),
    ok = prepare_adjustment_cashflow(Adjustment, St, Opts),
    Events = [?adjustment_ev(ID, ?adjustment_status_changed(?adjustment_processed()))],
    {next, {Events, hg_machine_action:instant()}}.

process_accounter_update(Action, St = #st{partial_cash_flow = FinalCashflow, capture_data = CaptureData}) ->
    Opts = get_opts(St),
    #payproc_InvoicePaymentCaptureData{
        reason = Reason,
        cash = Cost,
        cart = Cart,
        allocation = Allocation
    } = CaptureData,
    Invoice = get_invoice(Opts),
    Payment = get_payment(St),
    Payment2 = Payment#domain_InvoicePayment{cost = Cost},
    _Clock = hg_accounting:plan(
        construct_payment_plan_id(Invoice, Payment2),
        [
            {2, hg_cashflow:revert(get_cashflow(St))},
            {3, FinalCashflow}
        ]
    ),
    Events = start_session(?captured(Reason, Cost, Cart, Allocation)),
    {next, {Events, hg_machine_action:set_timeout(0, Action)}}.

%%

-spec handle_callback(callback(), hg_session:t(), st()) -> {callback_response(), machine_result()}.
handle_callback(Payload, Session0, St) ->
    PaymentInfo = construct_payment_info(St, get_opts(St)),
    Session1 = hg_session:set_payment_info(PaymentInfo, Session0),
    {Response, {Result, Session2}} = hg_session:process_callback(Payload, Session1),
    {Response, finish_session_processing(get_activity(St), Result, Session2, St)}.

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
finish_session_processing(Activity, {Events, Action}, Session, St) ->
    Events0 = hg_session:wrap_events(Events, Session),
    Events1 =
        case Activity of
            {refund_session, ID} ->
                [?refund_ev(ID, Ev) || Ev <- Events0];
            _ ->
                Events0
        end,
    case {hg_session:status(Session), hg_session:result(Session)} of
        {finished, ?session_succeeded()} ->
            TargetType = get_target_type(hg_session:target(Session)),
            _ = maybe_notify_fault_detector(Activity, TargetType, finish, St),
            NewAction = hg_machine_action:set_timeout(0, Action),
            {next, {Events1, NewAction}};
        {finished, ?session_failed(Failure)} ->
            process_failure(Activity, Events1, Action, Failure, St);
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

process_result({payment, processing_accounter}, Action, St) ->
    Target = get_target(St),
    NewAction = get_action(Target, Action, St),
    {done, {[?payment_status_changed(Target)], NewAction}};
process_result({payment, routing_failure}, Action, St = #st{failure = Failure}) ->
    NewAction = hg_machine_action:set_timeout(0, Action),
    Routes = get_candidate_routes(St),
    _ = rollback_payment_limits(Routes, St),
    {done, {[?payment_status_changed(?failed(Failure))], NewAction}};
process_result({payment, processing_failure}, Action, St = #st{failure = Failure}) ->
    NewAction = hg_machine_action:set_timeout(0, Action),
    Routes = [get_route(St)],
    _ = rollback_payment_limits(Routes, St),
    _ = rollback_payment_cashflow(St),
    {done, {[?payment_status_changed(?failed(Failure))], NewAction}};
process_result({payment, finalizing_accounter}, Action, St) ->
    Target = get_target(St),
    _PostingPlanLog =
        case Target of
            ?captured() ->
                commit_payment_limits(St),
                commit_payment_cashflow(St);
            ?cancelled() ->
                Route = get_route(St),
                _ = rollback_payment_limits([Route], St),
                rollback_payment_cashflow(St)
        end,
    check_recurrent_token(St),
    NewAction = get_action(Target, Action, St),
    {done, {[?payment_status_changed(Target)], NewAction}};
process_result({refund_failure, ID}, Action, St) ->
    RefundSt = try_get_refund_state(ID, St),
    Failure = RefundSt#refund_st.failure,
    _ = rollback_refund_limits(RefundSt, St),
    _PostingPlanLog = rollback_refund_cashflow(RefundSt, St),
    Events = [
        ?refund_ev(ID, ?refund_status_changed(?refund_failed(Failure)))
    ],
    {done, {Events, Action}};
process_result({refund_accounter, ID}, Action, St) ->
    RefundSt = try_get_refund_state(ID, St),
    _ = commit_refund_limits(RefundSt, St),
    _PostingPlanLog = commit_refund_cashflow(RefundSt, St),
    Events =
        case get_remaining_payment_amount(get_refund_cash(get_refund(RefundSt)), St) of
            ?cash(0, _) ->
                [
                    ?payment_status_changed(?refunded())
                ];
            ?cash(Amount, _) when Amount > 0 ->
                []
        end,
    {done, {[?refund_ev(ID, ?refund_status_changed(?refund_succeeded())) | Events], Action}}.

process_failure(Activity, Events, Action, Failure, St) ->
    process_failure(Activity, Events, Action, Failure, St, undefined).

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
            _ = logger:info("Retry session after transient failure, wait ~p", [Timeout]),
            {SessionEvents, SessionAction} = retry_session(Action, Target, Timeout),
            {next, {Events ++ SessionEvents, SessionAction}};
        fatal ->
            TargetType = get_target_type(Target),
            OperationStatus = choose_fd_operation_status_for_failure(Failure),
            _ = maybe_notify_fault_detector(Activity, TargetType, OperationStatus, St),
            process_fatal_payment_failure(Target, Events, Action, Failure, St)
    end;
process_failure({refund_new, ID}, [], Action, Failure, _St, _RefundSt) ->
    {next, {[?refund_ev(ID, ?refund_rollback_started(Failure))], hg_machine_action:set_timeout(0, Action)}};
process_failure({refund_session, ID}, Events, Action, Failure, St, _RefundSt) ->
    Target = ?refunded(),
    case check_retry_possibility(Target, Failure, St) of
        {retry, Timeout} ->
            _ = logger:info("Retry session after transient failure, wait ~p", [Timeout]),
            {SessionEvents, SessionAction} = retry_session(Action, Target, Timeout),
            Events1 = [?refund_ev(ID, E) || E <- SessionEvents],
            {next, {Events ++ Events1, SessionAction}};
        fatal ->
            RollbackStarted = [?refund_ev(ID, ?refund_rollback_started(Failure))],
            {next, {Events ++ RollbackStarted, hg_machine_action:set_timeout(0, Action)}}
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
get_error_class({refunded, _}) ->
    'RefundFailure';
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
    VS1 = collect_validation_varset(get_party(Opts), get_shop(Opts), Payment, VS0),
    hg_routing:get_payment_terms(Route, VS1, Revision).

filter_limit_overflow_routes(Routes, VS, St) ->
    ok = hold_limit_routes(Routes, VS, St),
    RejectedContext = #{rejected_routes => []},
    case get_limit_overflow_routes(Routes, VS, St, RejectedContext) of
        {[], _RejectedRoutesOut} ->
            {error, not_found};
        {RoutesNoOverflow, _} ->
            {ok, RoutesNoOverflow}
    end.

get_limit_overflow_routes(Routes, VS, St, RejectedRoutes) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    lists:foldl(
        fun(Route, {RoutesNoOverflowIn, RejectedIn}) ->
            PaymentRoute = hg_routing:to_payment_route(Route),
            ProviderTerms = hg_routing:get_payment_terms(PaymentRoute, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms),
            case hg_limiter:check_limits(TurnoverLimits, Invoice, Payment, PaymentRoute) of
                {ok, _} ->
                    {[Route | RoutesNoOverflowIn], RejectedIn};
                {error, {limit_overflow, IDs}} ->
                    PRef = hg_routing:provider_ref(Route),
                    TRef = hg_routing:terminal_ref(Route),
                    RejectedOut = [{PRef, TRef, {'LimitOverflow', IDs}} | RejectedIn],
                    {RoutesNoOverflowIn, RejectedOut}
            end
        end,
        {[], RejectedRoutes},
        Routes
    ).

hold_limit_routes(Routes, VS, St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    lists:foreach(
        fun(Route) ->
            PaymentRoute = hg_routing:to_payment_route(Route),
            ProviderTerms = hg_routing:get_payment_terms(PaymentRoute, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms),
            ok = hg_limiter:hold_payment_limits(TurnoverLimits, PaymentRoute, Invoice, Payment)
        end,
        Routes
    ).

rollback_payment_limits(Routes, St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    Invoice = get_invoice(Opts),
    VS = get_varset(St, #{}),
    lists:foreach(
        fun(Route) ->
            ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms),
            ok = hg_limiter:rollback_payment_limits(TurnoverLimits, Route, Invoice, Payment)
        end,
        Routes
    ).

rollback_unused_payment_limits(St) ->
    Route = get_route(St),
    Routes = get_candidate_routes(St),
    UnUsedRoutes = Routes -- [Route],
    rollback_payment_limits(UnUsedRoutes, St).

get_turnover_limits(ProviderTerms) ->
    TurnoverLimitSelector = ProviderTerms#domain_PaymentsProvisionTerms.turnover_limits,
    hg_limiter:get_turnover_limits(TurnoverLimitSelector).

commit_payment_limits(#st{capture_data = CaptureData} = St) ->
    Opts = get_opts(St),
    Revision = get_payment_revision(St),
    Payment = get_payment(St),
    #payproc_InvoicePaymentCaptureData{cash = CapturedCash} = CaptureData,
    Invoice = get_invoice(Opts),
    Route = get_route(St),
    ProviderTerms = get_provider_terms(St, Revision),
    TurnoverLimits = get_turnover_limits(ProviderTerms),
    hg_limiter:commit_payment_limits(TurnoverLimits, Route, Invoice, Payment, CapturedCash).

hold_refund_limits(RefundSt, St) ->
    Invoice = get_invoice(get_opts(St)),
    Payment = get_payment(St),
    Refund = get_refund(RefundSt),
    ProviderTerms = get_provider_terms(St, get_refund_revision(RefundSt)),
    TurnoverLimits = get_turnover_limits(ProviderTerms),
    Route = get_route(St),
    hg_limiter:hold_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route).

commit_refund_limits(RefundSt, St) ->
    Revision = get_refund_revision(RefundSt),
    Invoice = get_invoice(get_opts(St)),
    Refund = get_refund(RefundSt),
    Payment = get_payment(St),
    ProviderTerms = get_provider_terms(St, Revision),
    TurnoverLimits = get_turnover_limits(ProviderTerms),
    Route = get_route(St),
    hg_limiter:commit_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route).

rollback_refund_limits(RefundSt, St) ->
    Revision = get_refund_revision(RefundSt),
    Invoice = get_invoice(get_opts(St)),
    Refund = get_refund(RefundSt),
    Payment = get_payment(St),
    ProviderTerms = get_provider_terms(St, Revision),
    TurnoverLimits = get_turnover_limits(ProviderTerms),
    Route = get_route(St),
    hg_limiter:rollback_refund_limits(TurnoverLimits, Invoice, Payment, Refund, Route).

commit_payment_cashflow(St) ->
    hg_accounting:commit(construct_payment_plan_id(St), get_cashflow_plan(St)).

rollback_payment_cashflow(St) ->
    hg_accounting:rollback(construct_payment_plan_id(St), get_cashflow_plan(St)).

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
    construct_payment_info(
        get_activity(St),
        get_target(St),
        St,
        #proxy_provider_PaymentInfo{
            shop = construct_proxy_shop(get_shop(Opts)),
            invoice = construct_proxy_invoice(get_invoice(Opts)),
            payment = construct_proxy_payment(get_payment(St), get_trx(St))
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
construct_payment_info({refund_session, ID}, _Target, St, PaymentInfo) ->
    PaymentInfo#proxy_provider_PaymentInfo{
        refund = construct_proxy_refund(try_get_refund_state(ID, St))
    }.

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
    }};
construct_payment_resource(?customer_payer(_, _, RecPaymentToolID, _, _) = Payer) ->
    case get_rec_payment_tool(RecPaymentToolID) of
        {ok, #payproc_RecurrentPaymentTool{
            payment_resource = #domain_DisposablePaymentResource{
                payment_tool = PaymentTool
            },
            rec_token = RecToken
        }} when RecToken =/= undefined ->
            {recurrent_payment_resource, #proxy_provider_RecurrentPaymentResource{
                payment_tool = PaymentTool,
                rec_token = RecToken
            }};
        _ ->
            % TODO more elegant error
            error({'Can\'t get rec_token for customer payer', Payer})
    end.

get_contact_info(?payment_resource_payer(_, ContactInfo)) ->
    ContactInfo;
get_contact_info(?recurrent_payer(_, _, ContactInfo)) ->
    ContactInfo;
get_contact_info(?customer_payer(_, _, _, _, ContactInfo)) ->
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
    #domain_Shop{
        id = ShopID,
        details = ShopDetails,
        location = Location,
        category = ShopCategoryRef
    }
) ->
    ShopCategory = hg_domain:get({category, ShopCategoryRef}),
    #proxy_provider_Shop{
        id = ShopID,
        category = ShopCategory,
        details = ShopDetails,
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

construct_proxy_refund(#refund_st{refund = Refund} = St) ->
    #proxy_provider_InvoicePaymentRefund{
        id = get_refund_id(Refund),
        created_at = get_refund_created_at(Refund),
        trx = hg_session:trx_info(get_refund_session(St)),
        cash = construct_proxy_cash(get_refund_cash(Refund))
    }.

construct_proxy_capture(?captured(_, Cost)) ->
    #proxy_provider_InvoicePaymentCapture{
        cost = construct_proxy_cash(Cost)
    }.

%%

get_party(#{party := Party}) ->
    Party.

get_shop(#{party := Party, invoice := Invoice}) ->
    hg_party:get_shop(get_invoice_shop_id(Invoice), Party).

get_contract(#{party := Party, invoice := Invoice}) ->
    Shop = hg_party:get_shop(get_invoice_shop_id(Invoice), Party),
    hg_party:get_contract(Shop#domain_Shop.contract_id, Party).

get_payment_institution_ref(Opts) ->
    Contract = get_contract(Opts),
    Contract#domain_Contract.payment_institution.

get_opts_party_revision(#{party := Party}) ->
    Party#domain_Party.revision.

-spec get_invoice(opts()) -> invoice().
get_invoice(#{invoice := Invoice}) ->
    Invoice.

get_invoice_id(#domain_Invoice{id = ID}) ->
    ID.

get_invoice_cost(#domain_Invoice{cost = Cost}) ->
    Cost.

get_invoice_shop_id(#domain_Invoice{shop_id = ShopID}) ->
    ShopID.

get_payment_id(#domain_InvoicePayment{id = ID}) ->
    ID.

get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_payment_flow(#domain_InvoicePayment{flow = Flow}) ->
    Flow.

get_payment_shop_id(#domain_InvoicePayment{shop_id = ShopID}) ->
    ShopID.

get_payment_tool(#domain_InvoicePayment{payer = Payer}) ->
    get_payer_payment_tool(Payer).

get_payment_created_at(#domain_InvoicePayment{created_at = CreatedAt}) ->
    CreatedAt.

get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource);
get_payer_payment_tool(?customer_payer(_CustomerID, _, _, PaymentTool, _)) ->
    PaymentTool;
get_payer_payment_tool(?recurrent_payer(PaymentTool, _, _)) ->
    PaymentTool.

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
    VS0 = reconstruct_payment_flow(Payment, InitialValue),
    VS1 = collect_validation_varset(get_party(Opts), get_shop(Opts), Payment, VS0),
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
    invoice_id => invoice_id(),
    route_attempt_limit => integer()
}.

-spec merge_change(change(), st() | undefined, change_opts()) -> st().
merge_change(Change, undefined, Opts = #{route_attempt_limit := RouteAttemptLimit}) ->
    St = #st{
        activity = {payment, new},
        route_attempt_limit = RouteAttemptLimit
    },
    merge_change(Change, St, Opts);
merge_change(Change = ?payment_started(Payment), #st{} = St, Opts) ->
    _ = validate_transition({payment, new}, Change, St, Opts),
    St#st{
        target = ?processed(),
        payment = Payment,
        activity = {payment, risk_scoring},
        timings = hg_timings:mark(started, define_event_timestamp(Opts))
    };
merge_change(Change = ?risk_score_changed(RiskScore), #st{} = St, Opts) ->
    _ = validate_transition({payment, risk_scoring}, Change, St, Opts),
    St#st{
        risk_score = RiskScore,
        activity = {payment, routing}
    };
merge_change(Change = ?route_changed(Route, Candidates), #st{routes = Routes} = St, Opts) ->
    _ = validate_transition({payment, routing}, Change, St, Opts),
    St#st{
        original_payment_failure_status = undefined,
        routes = [Route|Routes],
        candidate_routes = ordsets:to_list(Candidates),
        activity = {payment, cash_flow_building}
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
                processing_capture
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
merge_change(Change = ?payment_rollback_started(Failure), St, Opts) ->
    _ = validate_transition(
        [{payment, cash_flow_building}, {payment, processing_session}],
        Change,
        St,
        Opts
    ),
    Activity =
        case St#st.cash_flow of
            undefined ->
                {payment, routing_failure};
            _ ->
                {payment, processing_failure}
        end,
    St#st{
        failure = Failure,
        activity = Activity,
        timings = accrue_status_timing(failed, Opts, St)
    };
merge_change(
    Change = ?payment_status_changed(?failed(OperationFailure) = Status),
    #st{payment = Payment, routes = AttemptedRoutes} = St,
    Opts
) ->
    _ = validate_transition(
        [
            {payment, S}
         || S <- [
                risk_scoring,
                routing,
                routing_failure,
                processing_failure
            ]
        ],
        Change,
        St,
        Opts
    ),
    %% FIXME: n a m i n g
    %%        a
    %%        m
    %%        i
    %%        n
    %%        g
    %% TODO: Consider moving this setup to `init_/3`
    %% TODO: Discuss error code and naming for `failure_code_for_route_cascading`
    FailureCodeForRouteCascading = genlib_app:env(hellgate, failure_code_for_route_cascading),
    %%
    %% TODO/FIXME: Refactor into sane function calls
    case {OperationFailure, St#st.route_attempt_limit} of
        %% TODO: Refactor into `hg_routing`
        {{failure, #domain_Failure{code = FailureCodeForRouteCascading}}, AttemptLimit}
            when length(AttemptedRoutes) < AttemptLimit
        ->
            St#st{
                original_payment_failure_status = Status,
                activity = {payment, routing},
                %% FIXME: Should we accrue more time? And what status type?
                timings = accrue_status_timing(pending, Opts, St)
            };
        _ ->
            FinalStatus = genlib:define(St#st.original_payment_failure_status, Status),
            St#st{
                payment = Payment#domain_InvoicePayment{status = FinalStatus},
                activity = idle,
                failure = undefined,
                timings = accrue_status_timing(failed, Opts, St)
            }
    end;
merge_change(Change = ?payment_status_changed({cancelled, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition({payment, finalizing_accounter}, Change, St, Opts),
    St#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = idle,
        timings = accrue_status_timing(cancelled, Opts, St)
    };
merge_change(Change = ?payment_status_changed({captured, Captured} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition({payment, finalizing_accounter}, Change, St, Opts),
    St#st{
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
    St#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = {payment, flow_waiting},
        timings = accrue_status_timing(processed, Opts, St)
    };
merge_change(Change = ?payment_status_changed({refunded, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition(idle, Change, St, Opts),
    St#st{
        payment = Payment#domain_InvoicePayment{status = Status}
    };
merge_change(Change = ?payment_status_changed({charged_back, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = validate_transition(idle, Change, St, Opts),
    St#st{
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
merge_change(Change = ?refund_ev(ID, Event), St, Opts) ->
    St1 =
        case Event of
            ?refund_created(_, _, _) ->
                _ = validate_transition(idle, Change, St, Opts),
                St#st{activity = {refund_new, ID}};
            ?session_ev(?refunded(), ?session_started()) ->
                _ = validate_transition([{refund_new, ID}, {refund_session, ID}], Change, St, Opts),
                St#st{activity = {refund_session, ID}};
            ?session_ev(?refunded(), ?session_finished(?session_succeeded())) ->
                _ = validate_transition({refund_session, ID}, Change, St, Opts),
                St#st{activity = {refund_accounter, ID}};
            ?refund_status_changed(?refund_succeeded()) ->
                _ = validate_transition([{refund_accounter, ID}], Change, St, Opts),
                RefundSt0 = merge_refund_change(Event, try_get_refund_state(ID, St), St, Opts),
                Allocation = get_allocation(St),
                FinalAllocation = hg_maybe:apply(
                    fun(A) ->
                        #domain_InvoicePaymentRefund{allocation = RefundAllocation} = get_refund(
                            RefundSt0
                        ),
                        {ok, FA} = hg_allocation:sub(A, RefundAllocation),
                        FA
                    end,
                    Allocation
                ),
                St#st{allocation = FinalAllocation};
            ?refund_rollback_started(_) ->
                _ = validate_transition([{refund_session, ID}, {refund_new, ID}], Change, St, Opts),
                St#st{activity = {refund_failure, ID}};
            ?refund_status_changed(?refund_failed(_)) ->
                _ = validate_transition([{refund_failure, ID}], Change, St, Opts),
                St;
            _ ->
                _ = validate_transition([{refund_session, ID}], Change, St, Opts),
                St
        end,
    RefundSt1 = merge_refund_change(Event, try_get_refund_state(ID, St1), St1, Opts),
    St2 = set_refund_state(ID, RefundSt1, St1),
    case get_refund_status(get_refund(RefundSt1)) of
        {S, _} when S == succeeded; S == failed ->
            St2#st{activity = idle};
        _ ->
            St2
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

save_retry_attempt(Target, #st{retry_attempts = Attempts} = St) ->
    St#st{retry_attempts = maps:update_with(get_target_type(Target), fun(N) -> N + 1 end, 0, Attempts)}.

merge_chargeback_change(Change, ChargebackState) ->
    hg_invoice_payment_chargeback:merge_change(Change, ChargebackState).

merge_refund_change(?refund_created(Refund, Cashflow, TransactionInfo), undefined, _St, _Opts) ->
    #refund_st{refund = Refund, cash_flow = Cashflow, transaction_info = TransactionInfo};
merge_refund_change(?refund_status_changed(Status), RefundSt, _St, _Opts) ->
    set_refund(set_refund_status(Status, get_refund(RefundSt)), RefundSt);
merge_refund_change(?refund_rollback_started(Failure), RefundSt, _St, _Opts) ->
    RefundSt#refund_st{failure = Failure};
merge_refund_change(?session_ev(?refunded(), Event = ?session_started()), RefundSt, St, Opts) ->
    Session = hg_session:apply_event(Event, undefined, create_session_event_context(?refunded(), St, Opts)),
    add_refund_session(Session, RefundSt);
merge_refund_change(?session_ev(?refunded(), Event), RefundSt, St, Opts) ->
    Session = hg_session:apply_event(
        Event, get_refund_session(RefundSt), create_session_event_context(?refunded(), St, Opts)
    ),
    update_refund_session(Session, RefundSt).

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

get_refund_session(#refund_st{sessions = []}) ->
    undefined;
get_refund_session(#refund_st{sessions = [Session | _]}) ->
    Session.

add_refund_session(Session, St = #refund_st{sessions = OldSessions}) ->
    St#refund_st{sessions = [Session | OldSessions]}.

update_refund_session(Session, St = #refund_st{sessions = []}) ->
    St#refund_st{sessions = [Session]};
update_refund_session(Session, St = #refund_st{sessions = OldSessions}) ->
    %% Replace recent session with updated one
    St#refund_st{sessions = [Session | tl(OldSessions)]}.

get_refund(#refund_st{refund = Refund}) ->
    Refund.

set_refund(Refund, RefundSt = #refund_st{}) ->
    RefundSt#refund_st{refund = Refund}.

get_refund_id(#domain_InvoicePaymentRefund{id = ID}) ->
    ID.

get_refund_status(#domain_InvoicePaymentRefund{status = Status}) ->
    Status.

set_refund_status(Status, Refund = #domain_InvoicePaymentRefund{}) ->
    Refund#domain_InvoicePaymentRefund{status = Status}.

get_refund_cashflow(#refund_st{cash_flow = CashFlow}) ->
    CashFlow.

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

enrich_refund_with_cash(Refund, #domain_InvoicePayment{cost = PaymentCash}) ->
    #domain_InvoicePaymentRefund{cash = RefundCash} = Refund,
    case {RefundCash, PaymentCash} of
        {undefined, _} ->
            %% Earlier Refunds haven't got field cash and we got this value from PaymentCash.
            %% There are some refunds without cash in system that's why for compatablity we save this behaviour.
            Refund#domain_InvoicePaymentRefund{cash = PaymentCash};
        {?cash(_, SymCode), ?cash(_, SymCode)} ->
            Refund
    end.

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
get_session(Target, #st{sessions = Sessions}) ->
    case maps:get(get_target_type(Target), Sessions, []) of
        [] ->
            undefined;
        [Session | _] ->
            Session
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

get_payment_revision(#st{payment = #domain_InvoicePayment{domain_revision = Revision}}) ->
    Revision.

get_payment_payer(#st{payment = #domain_InvoicePayment{payer = Payer}}) ->
    Payer.

get_refund_revision(#refund_st{refund = #domain_InvoicePaymentRefund{domain_revision = Revision}}) ->
    Revision.

%%

get_activity_session(St) ->
    get_activity_session(get_activity(St), St).

-spec get_activity_session(activity(), st()) -> session() | undefined.
get_activity_session({payment, _Step}, St) ->
    get_session(get_target(St), St);
get_activity_session({refund_session, ID}, St) ->
    RefundSt = try_get_refund_state(ID, St),
    get_refund_session(RefundSt).

%%

-spec collapse_changes([change()], st() | undefined, change_opts()) -> st() | undefined.
collapse_changes(Changes, St, Opts) ->
    lists:foldl(fun(C, St1) -> merge_change(C, St1, Opts) end, St, Changes).

%%

get_rec_payment_tool(RecPaymentToolID) ->
    hg_woody_wrapper:call(recurrent_paytool, 'Get', {RecPaymentToolID}).

get_customer(CustomerID) ->
    case issue_customer_call('Get', {CustomerID, #payproc_EventRange{}}) of
        {ok, Customer} ->
            Customer;
        {exception, #payproc_CustomerNotFound{}} ->
            throw_invalid_request(<<"Customer not found">>);
        {exception, Error} ->
            error({<<"Can't get customer">>, Error})
    end.

get_route_provider_ref(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

get_route_provider(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

get_route_provider(Route, Revision) ->
    hg_domain:get(Revision, {provider, get_route_provider_ref(Route)}).

inspect(Payment = #domain_InvoicePayment{domain_revision = Revision}, PaymentInstitution, Opts) ->
    InspectorRef = get_selector_value(inspector, PaymentInstitution#domain_PaymentInstitution.inspector),
    Inspector = hg_domain:get(Revision, {inspector, InspectorRef}),
    hg_inspector:inspect(get_shop(Opts), get_invoice(Opts), Payment, Inspector).

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

issue_customer_call(Func, Args) ->
    hg_woody_wrapper:call(customer_management, Func, Args).

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
