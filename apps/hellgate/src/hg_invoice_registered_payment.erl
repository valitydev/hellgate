-module(hg_invoice_registered_payment).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-include("hg_invoice_payment.hrl").
-include("payment_events.hrl").

%% Machine like

-export([init/3]).
-export([merge_change/3]).
-export([process_signal/3]).

-define(CAPTURE_REASON, <<"Timeout">>).

%%

-spec init(hg_invoice_payment:payment_id(), _, hg_invoice_payment:opts()) ->
    {hg_invoice_payment:st(), hg_invoice_payment:result()}.
init(PaymentID, Params, Opts) ->
    scoper:scope(
        payment,
        #{
            id => PaymentID
        },
        fun() ->
            init_(PaymentID, Params, Opts)
        end
    ).

-spec init_(hg_invoice_payment:payment_id(), _, hg_invoice_payment:opts()) ->
    {hg_invoice_payment:st(), hg_invoice_payment:result()}.
init_(PaymentID, Params, Opts = #{timestamp := CreatedAt0}) ->
    #payproc_RegisterInvoicePaymentParams{
        payer_params = PayerParams,
        route = Route,
        cost = Cost0,
        payer_session_info = PayerSessionInfo,
        external_id = ExternalID,
        context = Context,
        transaction_info = TransactionInfo,
        risk_score = RiskScore,
        occurred_at = OccurredAt
    } = Params,
    CreatedAt1 = genlib:define(OccurredAt, CreatedAt0),
    Revision = hg_domain:head(),
    Party = get_party(Opts),
    Shop = get_shop(Opts, Revision),
    Invoice = get_invoice(Opts),
    %% NOTE even if payment cost < invoice cost, invoice will gain status 'paid'
    Cost1 = genlib:define(Cost0, get_invoice_cost(Invoice)),
    {ok, Payer, _} = hg_invoice_payment:construct_payer(PayerParams, Shop),
    PaymentTool = get_payer_payment_tool(Payer),
    VS = collect_validation_varset(Party, Shop, Cost1, PaymentTool, RiskScore),
    PaymentInstitutionRef = get_payment_institution_ref(Opts, Revision),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS, Revision),

    Payment = construct_payment(
        PaymentID,
        CreatedAt1,
        Cost1,
        Payer,
        Party,
        Shop,
        PayerSessionInfo,
        Context,
        ExternalID,
        Revision
    ),
    RiskScoreEventList = maybe_risk_score_event_list(RiskScore),

    MerchantTerms = get_merchant_payment_terms(Revision, Shop, VS),
    ProviderTerms = hg_invoice_payment:get_provider_terminal_terms(Route, VS, Revision),
    CashflowContext = #{
        provision_terms => ProviderTerms,
        merchant_terms => MerchantTerms,
        route => Route,
        payment => Payment,
        timestamp => CreatedAt1,
        varset => VS,
        revision => Revision
    },
    FinalCashflow = hg_invoice_payment:calculate_cashflow(PaymentInstitution, CashflowContext, Opts),

    Events =
        [
            ?payment_started(Payment),
            ?shop_limit_initiated(),
            ?shop_limit_applied()
        ] ++
            RiskScoreEventList ++
            [
                ?route_changed(Route),
                ?cash_flow_changed(FinalCashflow),
                hg_session:wrap_event(?processed(), hg_session:create()),
                hg_session:wrap_event(?processed(), ?trx_bound(TransactionInfo)),
                hg_session:wrap_event(?processed(), ?session_finished(?session_succeeded())),
                ?payment_status_changed(?processed()),
                ?payment_capture_started(#payproc_InvoicePaymentCaptureData{
                    reason = ?CAPTURE_REASON,
                    cash = Cost1
                })
            ],
    ChangeOpts = #{
        invoice_id => Invoice#domain_Invoice.id
    },
    {collapse_changes(Events, undefined, ChangeOpts), {Events, hg_machine_action:instant()}}.

-spec merge_change(
    hg_invoice_payment:change(),
    hg_invoice_payment:st() | undefined,
    hg_invoice_payment:change_opts()
) -> hg_invoice_payment:st().
merge_change(
    Change = ?route_changed(_Route, _Candidates),
    #st{} = St0,
    Opts
) ->
    %% Skip risk scoring, if it isn't provided
    St1 = St0#st{
        activity = {payment, routing}
    },
    hg_invoice_payment:merge_change(Change, St1, Opts);
merge_change(Change, St, Opts) ->
    hg_invoice_payment:merge_change(Change, St, Opts).

-spec collapse_changes(
    [hg_invoice_payment:change()],
    hg_invoice_payment:st() | undefined,
    hg_invoice_payment:change_opts()
) -> hg_invoice_payment:st().
collapse_changes(Changes, St, Opts) ->
    lists:foldl(fun(C, St1) -> merge_change(C, St1, Opts) end, St, Changes).

-spec process_signal(timeout, hg_invoice_payment:st(), hg_invoice_payment:opts()) ->
    hg_invoice_payment:machine_result().
process_signal(timeout, St, Options) ->
    scoper:scope(
        payment,
        get_st_meta(St),
        fun() -> process_timeout(St#st{opts = Options}) end
    ).

process_timeout(St) ->
    Action = hg_machine_action:new(),
    process_timeout(hg_invoice_payment:get_activity(St), Action, St).

process_timeout({payment, processing_capture}, Action, St) ->
    %% It is an intermediate activity in hg_invoice_payment, but is used to initiate holds,
    %% due to need to save Transaction Info during initiation.
    process_processing_capture(Action, St);
process_timeout(Activity, Action, St) ->
    hg_invoice_payment:process_timeout(Activity, Action, St).

-spec process_processing_capture(hg_invoice_payment:action(), hg_invoice_payment:st()) ->
    hg_invoice_payment:machine_result().
process_processing_capture(Action, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    Invoice = hg_invoice_payment:get_invoice(Opts),
    #domain_InvoicePayment{
        cost = Cost
    } = Payment = hg_invoice_payment:get_payment(St),

    ok = hold_payment_limits(Invoice, Payment, St),
    ok = hold_payment_cashflow(St),
    Events = [
        hg_session:wrap_event(?captured(?CAPTURE_REASON, Cost), hg_session:create()),
        hg_session:wrap_event(?captured(?CAPTURE_REASON, Cost), ?session_finished(?session_succeeded()))
    ],
    {next, {Events, hg_machine_action:set_timeout(0, Action)}}.

hold_payment_cashflow(St) ->
    PlanID = hg_invoice_payment:construct_payment_plan_id(St),
    FinalCashflow = hg_invoice_payment:get_final_cashflow(St),
    _Clock = hg_accounting:hold(PlanID, {1, FinalCashflow}),
    ok.

maybe_risk_score_event_list(undefined) ->
    [];
maybe_risk_score_event_list(RiskScore) ->
    [?risk_score_changed(RiskScore)].

get_merchant_payment_terms(Revision, Shop, VS) ->
    TermSet = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS),
    TermSet#domain_TermSet.payments.

hold_payment_limits(Invoice, Payment, St) ->
    Route = hg_invoice_payment:get_route(St),
    TurnoverLimits = get_turnover_limits(Payment, Route, St),
    Iter = hg_invoice_payment:get_iter(St),
    hg_limiter:hold_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter).

get_turnover_limits(Payment, Route, St) ->
    Route = hg_invoice_payment:get_route(St),
    Opts = hg_invoice_payment:get_opts(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Party = get_party(Opts),
    Shop = get_shop(Opts, Revision),
    #domain_InvoicePayment{
        cost = Cost,
        payer = Payer,
        domain_revision = Revision
    } = Payment = hg_invoice_payment:get_payment(St),
    PaymentTool = get_payer_payment_tool(Payer),
    RiskScore = hg_invoice_payment:get_risk_score(St),
    VS = collect_validation_varset(Party, Shop, Cost, PaymentTool, RiskScore),
    ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
    TurnoverLimitSelector = ProviderTerms#domain_PaymentsProvisionTerms.turnover_limits,
    hg_limiter:get_turnover_limits(TurnoverLimitSelector).

construct_payment(
    PaymentID,
    CreatedAt,
    Cost,
    Payer,
    Party,
    Shop,
    PayerSessionInfo,
    Context,
    ExternalID,
    Revision
) ->
    #domain_InvoicePayment{
        id = PaymentID,
        created_at = CreatedAt,
        owner_id = Party#domain_PartyConfig.id,
        shop_id = Shop#domain_ShopConfig.id,
        domain_revision = Revision,
        status = ?pending(),
        cost = Cost,
        payer = Payer,
        payer_session_info = PayerSessionInfo,
        context = Context,
        external_id = ExternalID,
        flow = ?invoice_payment_flow_instant(),
        make_recurrent = false,
        registration_origin = ?invoice_payment_provider_reg_origin()
    }.

collect_validation_varset(Party, Shop, #domain_Cash{currency = Currency} = Cost, PaymentTool, RiskScore) ->
    #domain_PartyConfig{id = PartyID} = Party,
    #domain_ShopConfig{
        id = ShopID,
        category = Category
    } = Shop,
    #{
        party_id => PartyID,
        shop_id => ShopID,
        category => Category,
        currency => Currency,
        cost => Cost,
        payment_tool => PaymentTool,
        risk_score => RiskScore,
        flow => instant
    }.

%%

get_party(#{party := Party}) ->
    Party.

get_shop(#{party := Party, invoice := Invoice}, Revision) ->
    hg_party:get_shop(get_invoice_shop_id(Invoice), Party, Revision).
get_payment_institution_ref(Opts, Revision) ->
    Shop = get_shop(Opts, Revision),
    Shop#domain_ShopConfig.payment_institution.

get_invoice(#{invoice := Invoice}) ->
    Invoice.

get_invoice_cost(#domain_Invoice{cost = Cost}) ->
    Cost.

get_invoice_shop_id(#domain_Invoice{shop_id = ShopID}) ->
    ShopID.

get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource).

get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

get_st_meta(#st{payment = #domain_InvoicePayment{id = ID}}) ->
    #{
        id => ID
    };
get_st_meta(_) ->
    #{}.
