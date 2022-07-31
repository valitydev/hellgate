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

-module(hg_invoice_payment_refund).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").
-include_lib("hellgate/include/allocation.hrl").

%% API

-export([get_refunds/2]).
-export([get_refund/3]).

%% Business logic

-export([refund/7]).
-export([manual_refund/7]).

%%

-type refunds() :: #{refund_id() => refund_state()}.

-record(refund_st, {
    refund :: undefined | domain_refund(),
    cash_flow :: undefined | final_cash_flow(),
    sessions = [] :: [session()],
    transaction_info :: undefined | trx_info(),
    failure :: undefined | failure()
}).

-type refund_state() :: #refund_st{}.

-type party() :: dmsl_domain_thrift:'Party'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type domain_refund() :: dmsl_domain_thrift:'InvoicePaymentRefund'().
-type payment_refund() :: dmsl_payproc_thrift:'InvoicePaymentRefund'().
-type refund_id() :: dmsl_domain_thrift:'InvoicePaymentRefundID'().
-type refund_params() :: dmsl_payproc_thrift:'InvoicePaymentRefundParams'().
-type target() :: dmsl_domain_thrift:'TargetInvoicePaymentStatus'().
-type route() :: dmsl_domain_thrift:'PaymentRoute'().
-type final_cash_flow() :: dmsl_domain_thrift:'FinalCashFlow'().
-type trx_info() :: dmsl_domain_thrift:'TransactionInfo'().
-type session_result() :: dmsl_payproc_thrift:'SessionResult'().
-type proxy_state() :: dmsl_proxy_provider_thrift:'ProxyState'().
-type tag() :: dmsl_proxy_provider_thrift:'CallbackTag'().
-type timeout_behaviour() :: dmsl_timeout_behaviour_thrift:'TimeoutBehaviour'().
-type failure() :: dmsl_domain_thrift:'OperationFailure'().
-type session_status() :: active | suspended | finished.

-type session() :: #{
    target := target(),
    status := session_status(),
    trx := trx_info(),
    tags := [tag()],
    timeout_behaviour := timeout_behaviour(),
    result => session_result(),
    proxy_state => proxy_state(),
    timings => hg_timings:t()
}.

-type opts() :: #{
    party => party(),
    invoice => invoice(),
    timestamp => hg_datetime:timestamp()
}.

%%

-include("domain.hrl").
-include("payment_events.hrl").

%%

-spec get_refunds(refunds(), payment()) -> [payment_refund()].
get_refunds(Rs, Payment) ->
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

convert_refund_sessions(#{trx := TR}) ->
    #payproc_InvoiceRefundSession{
        transaction_info = TR
    }.

-spec get_refund(refund_id(), refunds(), payment()) -> domain_refund() | no_return().
get_refund(ID, Refunds, Payment) ->
    case try_get_refund_state(ID, Refunds) of
        #refund_st{refund = Refund} ->
            enrich_refund_with_cash(Refund, Payment);
        undefined ->
            throw(#payproc_InvoicePaymentRefundNotFound{})
    end.

%%

-type event() :: dmsl_payproc_thrift:'InvoicePaymentChangePayload'().
-type action() :: hg_machine_action:t().
-type events() :: [event()].
-type result() :: {events(), action()}.

get_merchant_payments_terms(Opts, Revision, Timestamp, VS) ->
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    TermSet = get_merchant_terms(Party, Shop, Revision, Timestamp, VS),
    TermSet#domain_TermSet.payments.

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

% Other payers has predefined routes

validate_refund_time(RefundCreatedAt, PaymentCreatedAt, TimeSpanSelector) ->
    EligibilityTime = get_selector_value(eligibility_time, TimeSpanSelector),
    RefundEndTime = hg_datetime:add_time_span(EligibilityTime, PaymentCreatedAt),
    case hg_datetime:compare(RefundCreatedAt, RefundEndTime) of
        Result when Result == earlier; Result == simultaneously ->
            ok;
        later ->
            throw(#payproc_OperationNotPermitted{})
    end.

collect_validation_varset(Payment, Opts) ->
    collect_validation_varset(get_party(Opts), get_shop(Opts), Payment, #{}).

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

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

%%

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

-spec refund(refund_params(), payment(), route(), refunds(), cash(), hg_allocation:allocation() | undefined, opts()) -> {domain_refund(), result()}.
refund(Params, Payment, Route, Refunds, RemainingPaymentBalance, Allocation, Opts = #{timestamp := CreatedAt}) ->
    Revision = hg_domain:head(),
    VS = collect_validation_varset(Payment, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS),
    Refund = make_refund(Params, Payment, Revision, CreatedAt, Refunds, RemainingPaymentBalance, Allocation, Opts),
    FinalCashflow = make_refund_cashflow(Refund, Payment, Revision, Route, Opts, MerchantTerms, VS, CreatedAt),
    Changes = [?refund_created(Refund, FinalCashflow)],
    Action = hg_machine_action:instant(),
    ID = Refund#domain_InvoicePaymentRefund.id,
    {Refund, {[?refund_ev(ID, C) || C <- Changes], Action}}.

-spec manual_refund(refund_params(), payment(), route(), refunds(), cash(), hg_allocation:allocation() | undefined, opts()) -> {domain_refund(), result()}.
manual_refund(Params, Payment, Route, Refunds, RemainingPaymentBalance, Allocation, Opts = #{timestamp := CreatedAt}) ->
    Revision = hg_domain:head(),
    VS = collect_validation_varset(Payment, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS),
    Refund = make_refund(Params, Payment, Revision, CreatedAt, Refunds, RemainingPaymentBalance, Allocation, Opts),
    FinalCashflow = make_refund_cashflow(Refund, Payment, Revision, Route, Opts, MerchantTerms, VS, CreatedAt),
    TransactionInfo = Params#payproc_InvoicePaymentRefundParams.transaction_info,
    Changes = [?refund_created(Refund, FinalCashflow, TransactionInfo)],
    Action = hg_machine_action:instant(),
    ID = Refund#domain_InvoicePaymentRefund.id,
    {Refund, {[?refund_ev(ID, C) || C <- Changes], Action}}.

make_refund(Params, Payment, Revision, CreatedAt, Refunds, RemainingPaymentBalance, Allocation, Opts) ->
    _ = assert_payment_status(captured, Payment),
    PartyRevision = get_opts_party_revision(Opts),
    _ = assert_previous_refunds_finished(Refunds),
    Cash = define_refund_cash(Params#payproc_InvoicePaymentRefundParams.cash, RemainingPaymentBalance, Payment),
    _ = assert_refund_cash(Cash, RemainingPaymentBalance),
    Cart = Params#payproc_InvoicePaymentRefundParams.cart,
    _ = assert_refund_cart(Params#payproc_InvoicePaymentRefundParams.cash, Cart, RemainingPaymentBalance),
    Timestamp = get_payment_created_at(Payment),
    VS = collect_validation_varset(Payment, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, Timestamp, VS),
    SubAllocation = maybe_allocation(
        Params#payproc_InvoicePaymentRefundParams.allocation,
        Cash,
        MerchantTerms,
        Opts
    ),
    ok = validate_allocation_refund(SubAllocation, Allocation),
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
        allocation = SubAllocation
    },
    ok = validate_refund(MerchantRefundTerms, Refund, Payment),
    Refund.

validate_allocation_refund(undefined, _Allocation) ->
    ok;
validate_allocation_refund(_SubAllocation, undefined) ->
    throw(#payproc_AllocationNotFound{});
validate_allocation_refund(SubAllocation, Allocation) ->
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

make_refund_cashflow(Refund, Payment, Revision, Route, Opts, MerchantTerms, VS, Timestamp) ->
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    PaymentInstitutionRef = get_payment_institution_ref(Opts),
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
        PaymentInstitutionRef,
        Route,
        Allocation,
        Payment,
        Refund,
        Provider,
        Revision,
        Timestamp,
        VS
    ).

assert_refund_cash(Cash, RemainingPaymentBalance) ->
    PaymentAmount = get_remaining_payment_amount(Cash, RemainingPaymentBalance),
    assert_remaining_payment_amount(PaymentAmount, RemainingPaymentBalance).

assert_remaining_payment_amount(?cash(Amount, _), _RemainingPaymentBalance) when Amount >= 0 ->
    ok;
assert_remaining_payment_amount(?cash(Amount, _), RemainingPaymentBalance) when Amount < 0 ->
    throw(#payproc_InvoicePaymentAmountExceeded{maximum = RemainingPaymentBalance}).

assert_previous_refunds_finished(Refunds) ->
    PendingRefunds = lists:filter(
        fun(#payproc_InvoicePaymentRefund{refund = R}) ->
            R#domain_InvoicePaymentRefund.status =:= ?refund_pending()
        end,
        Refunds
    ),
    case PendingRefunds of
        [] ->
            ok;
        [_R | _] ->
            throw(#payproc_OperationNotPermitted{})
    end.

assert_refund_cart(_RefundCash, undefined, _RemainingPaymentBalance) ->
    ok;
assert_refund_cart(undefined, _Cart, _RemainingPaymentBalance) ->
    throw_invalid_request(<<"Refund amount does not match with the cart total amount">>);
assert_refund_cart(RefundCash, Cart, RemainingPaymentBalance) ->
    case hg_cash:sub(RemainingPaymentBalance, RefundCash) =:= hg_invoice_utils:get_cart_amount(Cart) of
        true ->
            ok;
        _ ->
            throw_invalid_request(<<"Remaining payment amount not equal cart cost">>)
    end.

get_remaining_payment_amount(Cash, RemainingPaymentBalance) ->
    hg_cash:sub(RemainingPaymentBalance, Cash).

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
    PaymentInstitutionRef,
    Route,
    undefined,
    Payment,
    ContextSource,
    Provider,
    Revision,
    Timestamp,
    VS
) ->
    ProviderCashflowSelector = get_provider_cashflow_selector(ProvisionTerms),
    Amount = get_context_source_amount(ContextSource),
    CF = construct_transaction_cashflow(
        OpType,
        Party,
        Shop,
        Route,
        Amount,
        MerchantTerms,
        Revision,
        Timestamp,
        Payment,
        Provider,
        VS
    ),
    ProviderCashflow = construct_provider_cashflow(
        ProviderCashflowSelector,
        PaymentInstitutionRef,
        VS,
        Revision,
        Party,
        Shop,
        Route,
        ContextSource,
        Payment,
        Provider
    ),
    CF ++ ProviderCashflow;
collect_cashflow(
    OpType,
    ProvisionTerms,
    _MerchantTerms,
    Party,
    Shop,
    PaymentInstitutionRef,
    Route,
    ?allocation(Transactions),
    Payment,
    ContextSource,
    Provider,
    Revision,
    Timestamp,
    VS
) ->
    CF = lists:foldl(
        fun(?allocation_trx(_ID, Target, Amount), Acc) ->
            ?allocation_trx_target_shop(PartyID, ShopID) = Target,
            TargetParty = hg_party:get_party(PartyID),
            TargetShop = hg_party:get_shop(ShopID, TargetParty),
            construct_transaction_cashflow(
                OpType,
                TargetParty,
                TargetShop,
                Route,
                Amount,
                undefined,
                Revision,
                Timestamp,
                Payment,
                Provider,
                VS
            ) ++ Acc
        end,
        [],
        Transactions
    ),
    ProviderCashflowSelector = get_provider_cashflow_selector(ProvisionTerms),
    ProviderCashflow = construct_provider_cashflow(
        ProviderCashflowSelector,
        PaymentInstitutionRef,
        VS,
        Revision,
        Party,
        Shop,
        Route,
        ContextSource,
        Payment,
        Provider
    ),
    CF ++ ProviderCashflow.

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
    Route,
    Amount,
    MerchantPaymentsTerms0,
    Revision,
    Timestamp,
    Payment,
    Provider,
    VS0
) ->
    VS1 = VS0#{
        party_id => Party#domain_Party.id,
        shop_id => Shop#domain_Shop.id,
        cost => Amount
    },
    MerchantPaymentsTerms1 =
        case MerchantPaymentsTerms0 of
            undefined ->
                TermSet = get_merchant_terms(Party, Shop, Revision, Timestamp, VS1),
                TermSet#domain_TermSet.payments;
            _ ->
                MerchantPaymentsTerms0
        end,
    MerchantCashflowSelector = get_terms_cashflow(OpType, MerchantPaymentsTerms1),
    MerchantCashflow = get_selector_value(merchant_payment_fees, MerchantCashflowSelector),
    construct_cashflow(MerchantCashflow, Party, Shop, Route, Amount, Revision, Payment, Provider, VS1).

get_terms_cashflow(payment, MerchantPaymentsTerms) ->
    MerchantPaymentsTerms#domain_PaymentsServiceTerms.fees;
get_terms_cashflow(refund, MerchantPaymentsTerms) ->
    MerchantRefundTerms = MerchantPaymentsTerms#domain_PaymentsServiceTerms.refunds,
    MerchantRefundTerms#domain_PaymentRefundsServiceTerms.fees.

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

construct_provider_cashflow(
    ProviderCashflowSelector,
    PaymentInstitutionRef,
    VS,
    Revision,
    Party,
    Shop,
    Route,
    ContextSource,
    Payment,
    Provider
) ->
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS, Revision),
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

assert_payment_status([Status | _], #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
assert_payment_status([_ | Rest], InvoicePayment) ->
    assert_payment_status(Rest, InvoicePayment);
assert_payment_status(Status, #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
assert_payment_status(_, #domain_InvoicePayment{status = Status}) ->
    throw(#payproc_InvalidPaymentStatus{status = Status}).

-define(adjustment_target_status(Status), #domain_InvoicePaymentAdjustment{
    state =
        {status_change, #domain_InvoicePaymentAdjustmentStatusChangeState{
            scenario = #domain_InvoicePaymentAdjustmentStatusChange{target_status = Status}
        }}
}).

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

get_invoice_shop_id(#domain_Invoice{shop_id = ShopID}) ->
    ShopID.

get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

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

get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

%%

-spec throw_invalid_request(binary()) -> no_return().
throw_invalid_request(Why) ->
    throw(#base_InvalidRequest{errors = [Why]}).

%%

try_get_refund_state(ID, Rs) ->
    case Rs of
        #{ID := RefundSt} ->
            RefundSt;
        #{} ->
            undefined
    end.

define_refund_cash(undefined, RemainingPaymentBalance, _Payment) ->
    RemainingPaymentBalance;
define_refund_cash(?cash(_, SymCode) = Cash, _RemainingPaymentBalance, #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    Cash;
define_refund_cash(?cash(_, SymCode), _RemainingPaymentBalance, _Payment) ->
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

%%

get_route_provider_ref(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

get_route_provider(Route, Revision) ->
    hg_domain:get(Revision, {provider, get_route_provider_ref(Route)}).

%% Business metrics logging

get_party_client() ->
    HgContext = hg_context:load(),
    Client = hg_context:get_party_client(HgContext),
    Context = hg_context:get_party_client_context(HgContext),
    {Client, Context}.
