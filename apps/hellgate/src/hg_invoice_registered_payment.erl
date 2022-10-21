-module(hg_invoice_registered_payment).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-include("hg_invoice_payment.hrl").
-include("payment_events.hrl").

%% Machine like

-export([init/3]).
-export([merge_change/3]).
-export([process_finishing_registration/2]).

-define(CAPTURE_REASON, <<"Timeout">>).

%%

-spec init(hg_invoice_payment:payment_id(), _, hg_invoice_payment:opts()) ->
    {hg_invoice_payment:st(), hg_invoice_payment:result()}.
init(PaymentID, Params, Opts = #{timestamp := CreatedAt}) ->
    #payproc_RegisterInvoicePaymentParams{
        payer_params = PayerParams,
        route = Route,
        cost = Cost0,
        payer_session_info = PayerSessionInfo,
        external_id = ExternalID,
        context = Context,
        transaction_info = TransactionInfo1,
        risk_score = RiskScore0,
        %% Not sure what to do with it
        occurred_at = _OccurredAt
    } = Params,
    Revision = hg_domain:head(),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    Invoice = get_invoice(Opts),
    Cost1 = genlib:define(Cost0, get_invoice_cost(Invoice)),
    {ok, Payer, _} = hg_invoice_payment:construct_payer(PayerParams, Shop),
    PaymentTool = get_payer_payment_tool(Payer),
    VS0 = collect_validation_varset(Party, Shop, Cost1, PaymentTool),
    PaymentInstitutionRef = get_payment_institution_ref(Opts),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS0, Revision),

    Payment = construct_payment(
        PaymentID,
        CreatedAt,
        Cost1,
        Payer,
        PaymentTool,
        Party,
        Shop,
        PayerSessionInfo,
        Context,
        ExternalID,
        VS0,
        Revision
    ),
    RiskScore1 = maybe_get_risk_score(RiskScore0, PaymentInstitution, Revision, Shop, Invoice, Payment),
    VS1 = VS0#{risk_score => RiskScore1},
    FinalCashflow = build_final_cashflow(
        Invoice,
        Payment,
        Route,
        Party,
        Shop,
        PaymentInstitution,
        CreatedAt,
        VS1,
        Revision
    ),

    TransactionInfo2 = maybe_transaction_info(TransactionInfo1),
    Events = [
        ?payment_started(Payment),
        ?risk_score_changed(RiskScore1),
        ?route_changed(Route),
        ?cash_flow_changed(FinalCashflow),
        ?session_ev(?processed(), ?session_started()),
        ?session_ev(?processed(), ?trx_bound(TransactionInfo2)),
        ?session_ev(?processed(), ?session_finished(?session_succeeded())),
        ?payment_status_changed(?processed()),
        ?payment_capture_started(#payproc_InvoicePaymentCaptureData{
            reason = ?CAPTURE_REASON,
            cash = Cost1
        }),
        ?session_ev(?captured(?CAPTURE_REASON, Cost1), ?session_started()),
        ?session_ev(?captured(?CAPTURE_REASON, Cost1), ?session_finished(?session_succeeded()))
    ],
    {hg_invoice_payment:collapse_changes(Events, undefined, #{}), {Events, hg_machine_action:new()}}.

-spec merge_change(
    hg_invoice_payment:change(),
    hg_invoice_payment:st() | undefined,
    hg_invoice_payment:change_opts()
) -> hg_invoice_payment:st().
merge_change(Change = ?session_ev(?captured(?CAPTURE_REASON, _Cost), ?session_started()), #st{} = St, Opts) ->
    _ = hg_invoice_payment:validate_transition([{payment, processing_session}], Change, St, Opts),
    St#st{
        activity = {payment, finish_registration}
    }.

-spec process_finishing_registration(hg_invoice_payment:action(), hg_invoice_payment:st()) ->
    hg_invoice_payment:machine_result().
process_finishing_registration(Action, St) ->
    Route = hg_invoice_payment:get_route(St),
    Invoice = hg_invoice_payment:get_invoice(St),
    Opts = hg_invoice_payment:get_opts(St),
    FinalCashflow = hg_invoice_payment:get_final_cashflow(St),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    #domain_InvoicePayment{
        cost = Cost,
        payer = Payer,
        domain_revision = Revision
    } = Payment = hg_invoice_payment:get_payment(St),
    PaymentTool = get_payer_payment_tool(Payer),
    VS = collect_validation_varset(Party, Shop, Cost, PaymentTool),
    ok = commit_payment_limits(Route, Invoice, Payment, Cost, VS, Revision),
    PlanID = construct_payment_plan_id(Invoice, Payment),
    _ = hg_accounting:commit(PlanID, [{1, FinalCashflow}]),
    {done, {[?payment_status_changed(?captured(?CAPTURE_REASON, Cost))], Action}}.

maybe_get_risk_score(undefined, PaymentInstitution, Revision, Shop, Invoice, Payment) ->
    InspectorRef = get_selector_value(inspector, PaymentInstitution#domain_PaymentInstitution.inspector),
    Inspector = hg_domain:get(Revision, {inspector, InspectorRef}),
    hg_inspector:inspect(Shop, Invoice, Payment, Inspector);
maybe_get_risk_score(RiskScore, _PaymentInstitution, _Revision, _Shop, _Invoice, _Payment) ->
    RiskScore.

build_final_cashflow(Invoice, Payment, Route, Party, Shop, PaymentInstitution, Timestamp, VS, Revision) ->
    Provider = get_route_provider(Route, Revision),
    TermSet = get_merchant_terms(Party, Shop, Revision, Timestamp, VS),
    Amount = Payment#domain_InvoicePayment.cost,

    MerchantTerms = TermSet#domain_TermSet.payments,
    MerchantCashflowSelector = MerchantTerms#domain_PaymentsServiceTerms.fees,
    MerchantCashflow = get_selector_value(merchant_payment_fees, MerchantCashflowSelector),
    FinalTransactionCashflow = construct_cashflow(
        MerchantCashflow,
        Party,
        Shop,
        Route,
        Amount,
        Revision,
        Payment,
        Provider,
        VS
    ),

    ProviderTerms = get_provider_terminal_terms(Route, VS, Revision),
    ProviderCashflowSelector = ProviderTerms#domain_PaymentsProvisionTerms.cash_flow,
    ProviderCashflow = get_selector_value(provider_payment_cash_flow, ProviderCashflowSelector),
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
    CashflowContext = #{
        operation_amount => Amount
    },
    FinalProviderCashflow = hg_cashflow:finalize(ProviderCashflow, CashflowContext, AccountMap),

    FinalCashflow = FinalTransactionCashflow ++ FinalProviderCashflow,
    PlanID = construct_payment_plan_id(Invoice, Payment),
    _Clock = hg_accounting:hold(
        PlanID,
        {1, FinalCashflow}
    ),
    FinalCashflow.

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

-spec get_provider_terminal_terms(hg_routing:payment_route(), hg_varset:varset(), hg_domain:revision()) ->
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

commit_payment_limits(Route, Invoice, Payment, Cash, VS, Revision) ->
    ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
    TurnoverLimits = get_turnover_limits(ProviderTerms),
    hg_limiter:commit_payment_limits(TurnoverLimits, Route, Invoice, Payment, Cash).

get_turnover_limits(ProviderTerms) ->
    TurnoverLimitSelector = ProviderTerms#domain_PaymentsProvisionTerms.turnover_limits,
    hg_limiter:get_turnover_limits(TurnoverLimitSelector).

assert_contract_active(#domain_Contract{status = {active, _}}) ->
    ok;
assert_contract_active(#domain_Contract{status = Status}) ->
    throw(#payproc_InvalidContractStatus{status = Status}).

construct_payment(
    PaymentID,
    CreatedAt,
    Cost,
    Payer,
    PaymentTool,
    Party,
    Shop,
    PayerSessionInfo,
    Context,
    ExternalID,
    VS,
    Revision
) ->
    Terms = get_merchant_terms(Party, Shop, Revision, CreatedAt, VS),
    #domain_TermSet{payments = PaymentTerms} = Terms,
    ok = validate_payment_tool(
        PaymentTool,
        PaymentTerms#domain_PaymentsServiceTerms.payment_methods
    ),
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

collect_validation_varset(Party, Shop, Cost, PaymentTool) ->
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
        flow => instant
    }.

%%

construct_final_cashflow(Cashflow, Context, AccountMap) ->
    hg_cashflow:finalize(Cashflow, Context, AccountMap).

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

construct_cashflow(MerchantCashflow, Party, Shop, Route, Amount, Revision, Payment, Provider, VS) ->
    Contract = hg_party:get_contract(Shop#domain_Shop.contract_id, Party),
    PaymentInstitutionRef = Contract#domain_Contract.payment_institution,
    PaymentInstitution = hg_payment_institution:compute_payment_institution(
        PaymentInstitutionRef,
        VS,
        Revision
    ),
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

-spec throw_invalid_request(binary()) -> no_return().
throw_invalid_request(Why) ->
    throw(#base_InvalidRequest{errors = [Why]}).

%%

get_route_provider_ref(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

get_route_provider(Route, Revision) ->
    hg_domain:get(Revision, {provider, get_route_provider_ref(Route)}).

maybe_transaction_info(undefined) ->
    #domain_TransactionInfo{
        id = <<"1">>,
        extra = #{}
    };
maybe_transaction_info(#domain_TransactionInfo{} = TI) ->
    TI.

%% Business metrics logging

get_party_client() ->
    HgContext = hg_context:load(),
    Client = hg_context:get_party_client(HgContext),
    Context = hg_context:get_party_client_context(HgContext),
    {Client, Context}.
