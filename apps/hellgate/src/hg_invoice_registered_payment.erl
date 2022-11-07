-module(hg_invoice_registered_payment).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-include("hg_invoice_payment.hrl").
-include("payment_events.hrl").

%% Machine like

-export([init/3]).
-export([merge_change/3]).
-export([collapse_changes/3]).
-export([process_finishing_registration/2]).

-define(CAPTURE_REASON, <<"Timeout">>).

%%

-spec init(hg_invoice_payment:payment_id(), _, hg_invoice_payment:opts()) ->
    {hg_invoice_payment:st(), hg_invoice_payment:result()}.
init(PaymentID, Params, Opts = #{timestamp := CreatedAt0}) ->
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
    Shop = get_shop(Opts),
    Invoice = get_invoice(Opts),
    Cost1 = genlib:define(Cost0, get_invoice_cost(Invoice)),
    {ok, Payer, _} = hg_invoice_payment:construct_payer(PayerParams, Shop),
    PaymentTool = get_payer_payment_tool(Payer),
    VS = collect_validation_varset(Party, Shop, Cost1, PaymentTool, RiskScore),
    PaymentInstitutionRef = get_payment_institution_ref(Opts),
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

    MerchantTerms = get_merchant_payment_terms(Party, Shop, Revision, CreatedAt1, VS),
    ProviderTerms = hg_invoice_payment:get_provider_terminal_terms(Route, VS, Revision),
    FinalCashflow = hg_invoice_payment:calculate_cashflow(
        Route,
        Payment,
        PaymentInstitution,
        ProviderTerms,
        MerchantTerms,
        VS,
        Revision,
        Opts,
        CreatedAt1,
        undefined
    ),
    PlanID = construct_payment_plan_id(Invoice, Payment),
    _Clock = hg_accounting:hold(
        PlanID,
        {1, FinalCashflow}
    ),

    Events =
        [
            ?payment_started(Payment)
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
                }),
                hg_session:wrap_event(?captured(?CAPTURE_REASON, Cost1), hg_session:create()),
                hg_session:wrap_event(?captured(?CAPTURE_REASON, Cost1), ?session_finished(?session_succeeded()))
            ],
    ChangeOpts = #{
        invoice_id => Invoice#domain_Invoice.id
    },
    {collapse_changes(Events, undefined, ChangeOpts), {Events, hg_machine_action:new()}}.

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
merge_change(
    Change = ?session_ev(
        ?captured(?CAPTURE_REASON, _Cost),
        ?session_finished(?session_succeeded())
    ),
    #st{} = St0,
    Opts
) ->
    St1 = hg_invoice_payment:merge_change(Change, St0, Opts),
    St1#st{
        activity = {payment, finish_registration}
    };
merge_change(
    Change = ?payment_status_changed(?captured(?CAPTURE_REASON, _Cost)),
    #st{} = St0,
    Opts
) ->
    _ = hg_invoice_payment:validate_transition({payment, finish_registration}, Change, St0, Opts),
    St1 = St0#st{
        activity = {payment, finalizing_accounter}
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

-spec process_finishing_registration(hg_invoice_payment:action(), hg_invoice_payment:st()) ->
    hg_invoice_payment:machine_result().
process_finishing_registration(Action, St) ->
    Route = hg_invoice_payment:get_route(St),
    Opts = hg_invoice_payment:get_opts(St),
    RiskScore = hg_invoice_payment:get_risk_score(St),
    Invoice = hg_invoice_payment:get_invoice(Opts),
    FinalCashflow = hg_invoice_payment:get_final_cashflow(St),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    #domain_InvoicePayment{
        cost = Cost,
        payer = Payer,
        domain_revision = Revision
    } = Payment = hg_invoice_payment:get_payment(St),
    PaymentTool = get_payer_payment_tool(Payer),
    VS = collect_validation_varset(Party, Shop, Cost, PaymentTool, RiskScore),
    ok = commit_payment_limits(Route, Invoice, Payment, Cost, VS, Revision),
    PlanID = construct_payment_plan_id(Invoice, Payment),
    _ = hg_accounting:commit(PlanID, [{1, FinalCashflow}]),
    {done, {[?payment_status_changed(?captured(?CAPTURE_REASON, Cost))], Action}}.

maybe_risk_score_event_list(undefined) ->
    [];
maybe_risk_score_event_list(RiskScore) ->
    [?risk_score_changed(RiskScore)].

get_merchant_payment_terms(Party, Shop, DomainRevision, Timestamp, VS) ->
    TermSet = hg_invoice_payment:get_merchant_terms(Party, Shop, DomainRevision, Timestamp, VS),
    TermSet#domain_TermSet.payments.

commit_payment_limits(Route, Invoice, Payment, Cash, VS, Revision) ->
    ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
    TurnoverLimits = get_turnover_limits(ProviderTerms),
    hg_limiter:commit_payment_limits(TurnoverLimits, Route, Invoice, Payment, Cash).

get_turnover_limits(undefined) ->
    [];
get_turnover_limits(ProviderTerms) ->
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
        owner_id = Party#domain_Party.id,
        shop_id = Shop#domain_Shop.id,
        domain_revision = Revision,
        party_revision = Party#domain_Party.revision,
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

collect_validation_varset(Party, Shop, Cost, PaymentTool, RiskScore) ->
    #domain_Party{id = PartyID} = Party,
    #domain_Shop{
        id = ShopID,
        category = Category,
        account = #domain_ShopAccount{currency = Currency}
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

construct_payment_plan_id(Invoice, Payment) ->
    hg_utils:construct_complex_id([
        get_invoice_id(Invoice),
        get_payment_id(Payment)
    ]).

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

get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource);
get_payer_payment_tool(?customer_payer(_CustomerID, _, _, PaymentTool, _)) ->
    PaymentTool.

get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.
