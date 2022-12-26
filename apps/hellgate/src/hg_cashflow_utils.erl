-module(hg_cashflow_utils).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-include_lib("hellgate/include/allocation.hrl").
-include_lib("hellgate/include/domain.hrl").
-include("hg_invoice_payment.hrl").

-export([collect_cashflow/13]).
-export([collect_cashflow/14]).

-spec collect_cashflow(_, _, _, _, _, _, _, _, _, _, _, _, _) -> _.
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
-spec collect_cashflow(_, _, _, _, _, _, _, _, _, _, _, _, _, _) -> _.
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
                TermSet = hg_invoice_utils:get_merchant_terms(Party, Shop, Revision, Timestamp, VS),
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

construct_final_cashflow(Cashflow, Context, AccountMap) ->
    hg_cashflow:finalize(Cashflow, Context, AccountMap).

%% Internal

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

get_terms_cashflow(payment, MerchantPaymentsTerms) ->
    MerchantPaymentsTerms#domain_PaymentsServiceTerms.fees;
get_terms_cashflow(refund, MerchantPaymentsTerms) ->
    MerchantRefundTerms = MerchantPaymentsTerms#domain_PaymentsServiceTerms.refunds,
    MerchantRefundTerms#domain_PaymentRefundsServiceTerms.fees.

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
