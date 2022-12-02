-ifndef(__ct_domain_hrl__).
-define(__ct_domain_hrl__, 42).

-include_lib("damsel/include/dmsl_domain_conf_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").

-define(ordset(Es), ordsets:from_list(Es)).

-define(LIMIT_TURNOVER_NUM_PAYTOOL_ID1, <<"ID1">>).
-define(LIMIT_TURNOVER_NUM_PAYTOOL_ID2, <<"ID2">>).
-define(LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, <<"ID3">>).
-define(LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, <<"ID4">>).
-define(LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID3, <<"ID5">>).
-define(LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID4, <<"ID6">>).

-define(glob(), #domain_GlobalsRef{}).
-define(cur(ID), #domain_CurrencyRef{symbolic_code = ID}).
-define(pmt(C, T), #domain_PaymentMethodRef{id = {C, T}}).
-define(pmt(Ref), #domain_PaymentMethodRef{id = Ref}).
-define(pmtsys(ID), #domain_PaymentSystemRef{id = ID}).
-define(pmtsrv(ID), #domain_PaymentServiceRef{id = ID}).
-define(crptcur(ID), #domain_CryptoCurrencyRef{id = ID}).
-define(cat(ID), #domain_CategoryRef{id = ID}).
-define(prx(ID), #domain_ProxyRef{id = ID}).
-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).
-define(tmpl(ID), #domain_ContractTemplateRef{id = ID}).
-define(trms(ID), #domain_TermSetHierarchyRef{id = ID}).
-define(sas(ID), #domain_SystemAccountSetRef{id = ID}).
-define(eas(ID), #domain_ExternalAccountSetRef{id = ID}).
-define(insp(ID), #domain_InspectorRef{id = ID}).
-define(payinst(ID), #domain_PaymentInstitutionRef{id = ID}).
-define(ruleset(ID), #domain_RoutingRulesetRef{id = ID}).
-define(trnvrlimit(ID, UpperBoundary), #domain_TurnoverLimit{id = ID, upper_boundary = UpperBoundary}).

-define(cash(Amount, SymCode), #domain_Cash{amount = Amount, currency = ?cur(SymCode)}).

-define(cashrng(Lower, Upper), #domain_CashRange{lower = Lower, upper = Upper}).

-define(fixed(Amount, SymCode),
    {fixed, #domain_CashVolumeFixed{
        cash = #domain_Cash{
            amount = Amount,
            currency = ?cur(SymCode)
        }
    }}
).

-define(share(P, Q, C),
    {share, #domain_CashVolumeShare{
        parts = #'base_Rational'{p = P, q = Q},
        'of' = C
    }}
).

-define(share(P, Q, C, RM),
    {share, #domain_CashVolumeShare{
        parts = #'base_Rational'{p = P, q = Q},
        'of' = C,
        'rounding_method' = RM
    }}
).

-define(cfpost(A1, A2, V), #domain_CashFlowPosting{
    source = A1,
    destination = A2,
    volume = V
}).

-define(cfpost(A1, A2, V, D), #domain_CashFlowPosting{
    source = A1,
    destination = A2,
    volume = V,
    details = D
}).

-define(bank_card(BankName),
    {bank_card, #domain_BankCard{
        token = <<>>,
        bin = <<>>,
        last_digits = <<>>,
        bank_name = BankName,
        payment_system = #domain_PaymentSystemRef{id = <<"VISA">>},
        issuer_country = rus
    }}
).

-define(PAYMENT_METHOD_GENERIC(ID),
    {generic, #'domain_GenericPaymentMethod'{
        payment_service = #domain_PaymentServiceRef{id = ID}
    }}
).

-define(PAYMENT_METHOD_BANK_CARD(ID),
    {bank_card, #'domain_BankCardPaymentMethod'{
        payment_system = #domain_PaymentSystemRef{id = ID}
    }}
).

-define(PAYMENT_METHOD_BANK_CARD_WITH_EMPTY_CVV(ID),
    {bank_card, #'domain_BankCardPaymentMethod'{
        payment_system = #domain_PaymentSystemRef{id = ID},
        is_cvv_empty = true
    }}
).

-define(PAYMENT_METHOD_DIGITAL_WALLET(ID),
    {digital_wallet, #domain_PaymentServiceRef{id = ID}}
).

-define(PAYMENT_METHOD_CRYPTO_CURRENCY(ID),
    {crypto_currency, #domain_CryptoCurrencyRef{id = ID}}
).

-endif.
