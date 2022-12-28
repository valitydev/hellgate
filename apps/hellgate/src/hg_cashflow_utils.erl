-module(hg_cashflow_utils).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-include_lib("hellgate/include/allocation.hrl").
-include_lib("hellgate/include/domain.hrl").
-include("hg_invoice_payment.hrl").

-type cash_flow_context() :: #{
    operation := refund | payment,
    provision_terms := dmsl_domain_thrift:'PaymentsProvisionTerms'(),
    party := party(),
    shop := shop(),
    route := route(),
    payment := payment(),
    provider := provider(),
    timestamp := hg_datetime:timestamp(),
    varset := hg_varset:varset(),
    revision := revision(),
    merchant_terms => dmsl_domain_thrift:'PaymentsServiceTerms'(),
    refund => refund(),
    allocation => hg_allocation:allocation()
}.

-export_type([cash_flow_context/0]).

-export([collect_cashflow/1]).
-export([collect_cashflow/2]).

-type party() :: dmsl_domain_thrift:'Party'().
-type shop() :: dmsl_domain_thrift:'Shop'().
-type route() :: dmsl_domain_thrift:'PaymentRoute'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type refund() :: dmsl_domain_thrift:'InvoicePaymentRefund'().
-type provider() :: dmsl_domain_thrift:'Provider'().
-type revision() :: hg_domain:revision().
-type payment_institution() :: hg_payment_institution:t().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().

-spec collect_cashflow(cash_flow_context()) -> final_cash_flow().
collect_cashflow(#{party := Party, shop := Shop, varset := VS, revision := Revision} = Context) ->
    PaymentInstitution = get_cashflow_payment_institution(Party, Shop, VS, Revision),
    collect_cashflow(PaymentInstitution, Context).

-spec collect_cashflow(payment_institution(), cash_flow_context()) -> final_cash_flow().
collect_cashflow(PaymentInstitution, Context) ->
    CF =
        case maps:get(allocation, Context, undefined) of
            undefined ->
                Amount = get_amount(Context),
                construct_transaction_cashflow(Amount, PaymentInstitution, Context);
            ?allocation(Transactions) ->
                collect_allocation_cash_flow(Transactions, Context)
        end,
    ProviderCashflow = construct_provider_cashflow(PaymentInstitution, Context),
    CF ++ ProviderCashflow.

%% Internal

collect_allocation_cash_flow(
    Transactions,
    Context = #{
        revision := Revision,
        party := Party,
        shop := Shop,
        varset := VS0
    }
) ->
    lists:foldl(
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
                Amount,
                AllocationPaymentInstitution,
                Context#{party => TargetParty, shop => TargetShop}
            ) ++ Acc
        end,
        [],
        Transactions
    ).

construct_transaction_cashflow(
    Amount,
    PaymentInstitution,
    Context = #{
        operation := OpType,
        party := Party,
        shop := Shop,
        varset := VS,
        revision := Revision,
        timestamp := Timestamp
    }
) ->
    MerchantPaymentsTerms1 =
        case maps:get(merchant_terms, Context, undefined) of
            undefined ->
                TermSet = hg_invoice_utils:get_merchant_terms(Party, Shop, Revision, Timestamp, VS),
                TermSet#domain_TermSet.payments;
            MerchantPaymentsTerms0 ->
                MerchantPaymentsTerms0
        end,
    MerchantCashflowSelector = get_terms_cashflow(OpType, MerchantPaymentsTerms1),
    MerchantCashflow = get_selector_value(merchant_payment_fees, MerchantCashflowSelector),
    AccountMap = hg_accounting:collect_account_map(make_collect_account_context(PaymentInstitution, Context)),
    construct_final_cashflow(MerchantCashflow, #{operation_amount => Amount}, AccountMap).

construct_provider_cashflow(PaymentInstitution, Context = #{provision_terms := ProvisionTerms}) ->
    ProviderCashflowSelector = get_provider_cashflow_selector(ProvisionTerms),
    ProviderCashflow = get_selector_value(provider_payment_cash_flow, ProviderCashflowSelector),
    AccountMap = hg_accounting:collect_account_map(make_collect_account_context(PaymentInstitution, Context)),
    construct_final_cashflow(ProviderCashflow, #{operation_amount => get_amount(Context)}, AccountMap).

construct_final_cashflow(Cashflow, Context, AccountMap) ->
    hg_cashflow:finalize(Cashflow, Context, AccountMap).

get_cashflow_payment_institution(Party, Shop, VS, Revision) ->
    Contract = hg_party:get_contract(Shop#domain_Shop.contract_id, Party),
    PaymentInstitutionRef = Contract#domain_Contract.payment_institution,
    hg_payment_institution:compute_payment_institution(
        PaymentInstitutionRef,
        VS,
        Revision
    ).

get_amount(#{refund := #domain_InvoicePaymentRefund{cash = Cash}}) ->
    Cash;
get_amount(#{payment := #domain_InvoicePayment{cost = Cost}}) ->
    Cost.

get_provider_cashflow_selector(#domain_PaymentsProvisionTerms{cash_flow = ProviderCashflowSelector}) ->
    ProviderCashflowSelector;
get_provider_cashflow_selector(#domain_PaymentRefundsProvisionTerms{cash_flow = ProviderCashflowSelector}) ->
    ProviderCashflowSelector.

get_terms_cashflow(payment, MerchantPaymentsTerms) ->
    MerchantPaymentsTerms#domain_PaymentsServiceTerms.fees;
get_terms_cashflow(refund, MerchantPaymentsTerms) ->
    MerchantRefundTerms = MerchantPaymentsTerms#domain_PaymentsServiceTerms.refunds,
    MerchantRefundTerms#domain_PaymentRefundsServiceTerms.fees.

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

-spec make_collect_account_context(payment_institution(), cash_flow_context()) ->
    hg_accounting:collect_account_context().
make_collect_account_context(PaymentInstitution, #{
    payment := Payment,
    party := Party,
    shop := Shop,
    route := Route,
    provider := Provider,
    varset := VS,
    revision := Revision
}) ->
    #{
        payment => Payment,
        party => Party,
        shop => Shop,
        route => Route,
        payment_institution => PaymentInstitution,
        provider => Provider,
        varset => VS,
        revision => Revision
    }.
