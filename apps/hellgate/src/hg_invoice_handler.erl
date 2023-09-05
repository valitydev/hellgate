-module(hg_invoice_handler).

-include("payment_events.hrl").
-include("invoice_events.hrl").
-include("domain.hrl").
-include("hg_invoice.hrl").

%% Woody handler called by hg_woody_service_wrapper

-behaviour(hg_woody_service_wrapper).

-export([handle_function/3]).

%% Internal

-import(hg_invoice_utils, [
    assert_party_operable/1,
    assert_shop_operable/1,
    assert_shop_exists/1
]).

%% API

-spec handle_function(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(
        invoicing,
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

-spec handle_function_(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function_('Create', {InvoiceParams}, _Opts) ->
    DomainRevision = hg_domain:head(),
    InvoiceID = InvoiceParams#payproc_InvoiceParams.id,
    _ = set_invoicing_meta(InvoiceID),
    PartyID = InvoiceParams#payproc_InvoiceParams.party_id,
    ShopID = InvoiceParams#payproc_InvoiceParams.shop_id,
    Party = hg_party:get_party(PartyID),
    Shop = assert_shop_exists(hg_party:get_shop(ShopID, Party)),
    _ = assert_party_shop_operable(Shop, Party),
    VS = #{
        cost => InvoiceParams#payproc_InvoiceParams.cost,
        shop_id => Shop#domain_Shop.id
    },
    MerchantTerms = hg_invoice_utils:get_merchant_terms(Party, Shop, DomainRevision, hg_datetime:format_now(), VS),
    ok = validate_invoice_params(InvoiceParams, Shop, MerchantTerms),
    AllocationPrototype = InvoiceParams#payproc_InvoiceParams.allocation,
    Cost = InvoiceParams#payproc_InvoiceParams.cost,
    Allocation = maybe_allocation(AllocationPrototype, Cost, MerchantTerms, Party, Shop),
    ok = ensure_started(InvoiceID, undefined, Party#domain_Party.revision, InvoiceParams, Allocation),
    get_invoice_state(get_state(InvoiceID));
handle_function_('CreateWithTemplate', {Params}, _Opts) ->
    DomainRevision = hg_domain:head(),
    InvoiceID = Params#payproc_InvoiceWithTemplateParams.id,
    _ = set_invoicing_meta(InvoiceID),
    TplID = Params#payproc_InvoiceWithTemplateParams.template_id,
    {Party, Shop, InvoiceParams} = make_invoice_params(Params),
    VS = #{
        cost => InvoiceParams#payproc_InvoiceParams.cost,
        shop_id => Shop#domain_Shop.id
    },
    MerchantTerms = hg_invoice_utils:get_merchant_terms(Party, Shop, DomainRevision, hg_datetime:format_now(), VS),
    ok = validate_invoice_params(InvoiceParams, Shop, MerchantTerms),
    AllocationPrototype = InvoiceParams#payproc_InvoiceParams.allocation,
    Cost = InvoiceParams#payproc_InvoiceParams.cost,
    Allocation = maybe_allocation(AllocationPrototype, Cost, MerchantTerms, Party, Shop),
    ok = ensure_started(InvoiceID, TplID, Party#domain_Party.revision, InvoiceParams, Allocation),
    get_invoice_state(get_state(InvoiceID));
handle_function_('CapturePaymentNew', Args, Opts) ->
    handle_function_('CapturePayment', Args, Opts);
handle_function_('Get', {InvoiceID, #payproc_EventRange{'after' = AfterID, limit = Limit}}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID),
    St = get_state(InvoiceID, AfterID, Limit),
    get_invoice_state(St);
handle_function_('GetEvents', {InvoiceID, Range}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID),
    get_public_history(InvoiceID, Range);
handle_function_('GetPayment', {InvoiceID, PaymentID}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID, PaymentID),
    St = get_state(InvoiceID),
    get_payment_state(get_payment_session(PaymentID, St));
handle_function_('GetPaymentRefund', {InvoiceID, PaymentID, ID}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID, PaymentID),
    St = get_state(InvoiceID),
    hg_invoice_payment:get_refund(ID, get_payment_session(PaymentID, St));
handle_function_('GetPaymentChargeback', {InvoiceID, PaymentID, ID}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID, PaymentID),
    St = get_state(InvoiceID),
    CBSt = hg_invoice_payment:get_chargeback_state(ID, get_payment_session(PaymentID, St)),
    hg_invoice_payment_chargeback:get(CBSt);
handle_function_('GetPaymentAdjustment', {InvoiceID, PaymentID, ID}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID, PaymentID),
    St = get_state(InvoiceID),
    hg_invoice_payment:get_adjustment(ID, get_payment_session(PaymentID, St));
handle_function_('ComputeTerms', {InvoiceID, PartyRevision0}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID),
    St = get_state(InvoiceID),
    Timestamp = get_created_at(St),
    VS = hg_varset:prepare_shop_terms_varset(#{
        cost => get_cost(St)
    }),
    hg_invoice_utils:compute_shop_terms(
        get_party_id(St),
        get_shop_id(St),
        Timestamp,
        hg_maybe:get_defined(PartyRevision0, {timestamp, Timestamp}),
        VS
    );
handle_function_(Fun, Args, _Opts) when
    Fun =:= 'StartPayment' orelse
        Fun =:= 'RegisterPayment' orelse
        Fun =:= 'CapturePayment' orelse
        Fun =:= 'CancelPayment' orelse
        Fun =:= 'RefundPayment' orelse
        Fun =:= 'CreateManualRefund' orelse
        Fun =:= 'CreateChargeback' orelse
        Fun =:= 'CancelChargeback' orelse
        Fun =:= 'AcceptChargeback' orelse
        Fun =:= 'RejectChargeback' orelse
        Fun =:= 'ReopenChargeback' orelse
        Fun =:= 'CreatePaymentAdjustment' orelse
        Fun =:= 'Fulfill' orelse
        Fun =:= 'Rescind'
->
    InvoiceID = erlang:element(1, Args),
    _ = set_invoicing_meta(InvoiceID),
    call(InvoiceID, Fun, Args);
handle_function_('Repair', {InvoiceID, Changes, Action, Params}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID),
    repair(InvoiceID, {changes, Changes, Action, Params});
handle_function_('RepairWithScenario', {InvoiceID, Scenario}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID),
    repair(InvoiceID, {scenario, Scenario});
handle_function_('GetPaymentRoutesLimitValues', {InvoiceID, PaymentID}, _Opts) ->
    _ = set_invoicing_meta(InvoiceID, PaymentID),
    St = get_state(InvoiceID),
    hg_invoice_payment:get_limit_values(get_payment_session(PaymentID, St), hg_invoice:get_payment_opts(St)).

ensure_started(ID, TemplateID, PartyRevision, Params, Allocation) ->
    Invoice = hg_invoice:create(ID, TemplateID, PartyRevision, Params, Allocation),
    case hg_machine:start(hg_invoice:namespace(), ID, hg_invoice:marshal_invoice(Invoice)) of
        {ok, _} -> ok;
        {error, exists} -> ok;
        {error, Reason} -> erlang:error(Reason)
    end.

call(ID, Function, Args) ->
    case hg_machine:thrift_call(hg_invoice:namespace(), ID, invoicing, {'Invoicing', Function}, Args) of
        ok -> ok;
        {ok, Reply} -> Reply;
        {exception, Exception} -> erlang:throw(Exception);
        {error, notfound} -> erlang:throw(#payproc_InvoiceNotFound{});
        {error, Error} -> erlang:error(Error)
    end.

repair(ID, Args) ->
    case hg_machine:repair(hg_invoice:namespace(), ID, Args) of
        {ok, _Result} -> ok;
        {error, notfound} -> erlang:throw(#payproc_InvoiceNotFound{});
        {error, working} -> erlang:throw(#base_InvalidRequest{errors = [<<"No need to repair">>]});
        {error, Reason} -> erlang:error(Reason)
    end.

maybe_allocation(undefined, _Cost, _MerchantTerms, _Party, _Shop) ->
    undefined;
maybe_allocation(AllocationPrototype, Cost, MerchantTerms, Party, Shop) ->
    PaymentTerms = MerchantTerms#domain_TermSet.payments,
    AllocationSelector = PaymentTerms#domain_PaymentsServiceTerms.allocations,
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

%%----------------- invoice asserts

assert_party_shop_operable(Shop, Party) ->
    _ = assert_party_operable(Party),
    _ = assert_shop_operable(Shop),
    ok.

get_invoice_state(#st{invoice = Invoice, payments = Payments}) ->
    #payproc_Invoice{
        invoice = Invoice,
        payments = [
            get_payment_state(PaymentSession)
         || {_PaymentID, PaymentSession} <- Payments
        ]
    }.

get_payment_state(PaymentSession) ->
    Refunds = hg_invoice_payment:get_refunds(PaymentSession),
    LegacyRefunds =
        lists:map(
            fun(#payproc_InvoicePaymentRefund{refund = R}) ->
                R
            end,
            Refunds
        ),
    #payproc_InvoicePayment{
        payment = hg_invoice_payment:get_payment(PaymentSession),
        adjustments = hg_invoice_payment:get_adjustments(PaymentSession),
        chargebacks = hg_invoice_payment:get_chargebacks(PaymentSession),
        route = hg_invoice_payment:get_route(PaymentSession),
        cash_flow = hg_invoice_payment:get_final_cashflow(PaymentSession),
        legacy_refunds = LegacyRefunds,
        refunds = Refunds,
        sessions = hg_invoice_payment:get_sessions(PaymentSession),
        last_transaction_info = hg_invoice_payment:get_trx(PaymentSession),
        allocation = hg_invoice_payment:get_allocation(PaymentSession)
    }.

set_invoicing_meta(InvoiceID) ->
    scoper:add_meta(#{invoice_id => InvoiceID}).

set_invoicing_meta(InvoiceID, PaymentID) ->
    scoper:add_meta(#{invoice_id => InvoiceID, payment_id => PaymentID}).

%%

get_state(ID) ->
    hg_invoice:collapse_history(get_history(ID)).

get_state(ID, AfterID, Limit) ->
    hg_invoice:collapse_history(get_history(ID, AfterID, Limit)).

get_history(ID) ->
    History = hg_machine:get_history(hg_invoice:namespace(), ID),
    hg_invoice:unmarshal_history(map_history_error(History)).

get_history(ID, AfterID, Limit) ->
    History = hg_machine:get_history(hg_invoice:namespace(), ID, AfterID, Limit),
    hg_invoice:unmarshal_history(map_history_error(History)).

get_public_history(InvoiceID, #payproc_EventRange{'after' = AfterID, limit = Limit}) ->
    [publish_invoice_event(InvoiceID, Ev) || Ev <- get_history(InvoiceID, AfterID, Limit)].

publish_invoice_event(InvoiceID, {ID, Dt, Event}) ->
    #payproc_Event{
        id = ID,
        source = {invoice_id, InvoiceID},
        created_at = Dt,
        payload = ?invoice_ev(Event)
    }.

map_history_error({ok, Result}) ->
    Result;
map_history_error({error, notfound}) ->
    throw(#payproc_InvoiceNotFound{}).

%%

get_party_id(#st{invoice = #domain_Invoice{owner_id = PartyID}}) ->
    PartyID.

get_shop_id(#st{invoice = #domain_Invoice{shop_id = ShopID}}) ->
    ShopID.

get_created_at(#st{invoice = #domain_Invoice{created_at = CreatedAt}}) ->
    CreatedAt.

get_cost(#st{invoice = #domain_Invoice{cost = Cash}}) ->
    Cash.

get_payment_session(PaymentID, St) ->
    case try_get_payment_session(PaymentID, St) of
        PaymentSession when PaymentSession /= undefined ->
            PaymentSession;
        undefined ->
            throw(#payproc_InvoicePaymentNotFound{})
    end.

try_get_payment_session(PaymentID, #st{payments = Payments}) ->
    case lists:keyfind(PaymentID, 1, Payments) of
        {PaymentID, PaymentSession} ->
            PaymentSession;
        false ->
            undefined
    end.

%%

make_invoice_params(Params) ->
    #payproc_InvoiceWithTemplateParams{
        id = InvoiceID,
        template_id = TplID,
        cost = Cost,
        context = Context,
        external_id = ExternalID
    } = Params,
    #domain_InvoiceTemplate{
        owner_id = PartyID,
        shop_id = ShopID,
        invoice_lifetime = Lifetime,
        product = Product,
        description = Description,
        details = TplDetails,
        context = TplContext
    } = hg_invoice_template:get(TplID),
    Party = hg_party:get_party(PartyID),
    Shop = assert_shop_exists(hg_party:get_shop(ShopID, Party)),
    _ = assert_party_shop_operable(Shop, Party),
    Cart = make_invoice_cart(Cost, TplDetails, Shop),
    InvoiceDetails = #domain_InvoiceDetails{
        product = Product,
        description = Description,
        cart = Cart
    },
    InvoiceCost = hg_invoice_utils:get_cart_amount(Cart),
    InvoiceDue = make_invoice_due_date(Lifetime),
    InvoiceContext = make_invoice_context(Context, TplContext),
    InvoiceParams = #payproc_InvoiceParams{
        id = InvoiceID,
        party_id = PartyID,
        shop_id = ShopID,
        details = InvoiceDetails,
        due = InvoiceDue,
        cost = InvoiceCost,
        context = InvoiceContext,
        external_id = ExternalID
    },
    {Party, Shop, InvoiceParams}.

validate_invoice_params(#payproc_InvoiceParams{cost = Cost}, Shop, MerchantTerms) ->
    ok = validate_invoice_cost(Cost, Shop, MerchantTerms),
    ok.

validate_invoice_cost(Cost, Shop, #domain_TermSet{payments = PaymentTerms}) ->
    _ = hg_invoice_utils:validate_cost(Cost, Shop),
    _ = hg_invoice_utils:assert_cost_payable(Cost, PaymentTerms),
    ok.

make_invoice_cart(_, {cart, Cart}, _Shop) ->
    Cart;
make_invoice_cart(Cost, {product, TplProduct}, Shop) ->
    #domain_InvoiceTemplateProduct{
        product = Product,
        price = TplPrice,
        metadata = Metadata
    } = TplProduct,
    #domain_InvoiceCart{
        lines = [
            #domain_InvoiceLine{
                product = Product,
                quantity = 1,
                price = get_templated_price(Cost, TplPrice, Shop),
                metadata = Metadata
            }
        ]
    }.

get_templated_price(undefined, {fixed, Cost}, Shop) ->
    get_cost(Cost, Shop);
get_templated_price(undefined, _, _Shop) ->
    throw(#base_InvalidRequest{errors = [?INVOICE_TPL_NO_COST]});
get_templated_price(Cost, {fixed, Cost}, Shop) ->
    get_cost(Cost, Shop);
get_templated_price(_Cost, {fixed, _CostTpl}, _Shop) ->
    throw(#base_InvalidRequest{errors = [?INVOICE_TPL_BAD_COST]});
get_templated_price(Cost, {range, Range}, Shop) ->
    _ = assert_cost_in_range(Cost, Range),
    get_cost(Cost, Shop);
get_templated_price(Cost, {unlim, _}, Shop) ->
    get_cost(Cost, Shop).

get_cost(Cost, Shop) ->
    ok = hg_invoice_utils:validate_cost(Cost, Shop),
    Cost.

assert_cost_in_range(
    #domain_Cash{amount = Amount, currency = Currency},
    #domain_CashRange{
        upper = {UType, #domain_Cash{amount = UAmount, currency = Currency}},
        lower = {LType, #domain_Cash{amount = LAmount, currency = Currency}}
    }
) ->
    _ = assert_less_than(LType, LAmount, Amount),
    _ = assert_less_than(UType, Amount, UAmount),
    ok;
assert_cost_in_range(_, _) ->
    throw(#base_InvalidRequest{errors = [?INVOICE_TPL_BAD_CURRENCY]}).

assert_less_than(inclusive, Less, More) when Less =< More ->
    ok;
assert_less_than(exclusive, Less, More) when Less < More ->
    ok;
assert_less_than(_, _, _) ->
    throw(#base_InvalidRequest{errors = [?INVOICE_TPL_BAD_AMOUNT]}).

make_invoice_due_date(#domain_LifetimeInterval{years = YY, months = MM, days = DD}) ->
    hg_datetime:add_interval(hg_datetime:format_now(), {YY, MM, DD}).

make_invoice_context(undefined, TplContext) ->
    TplContext;
make_invoice_context(Context, _) ->
    Context.
