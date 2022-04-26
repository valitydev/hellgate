%%% Payment tools

-module(hg_payment_tool).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%%

-export([get_payment_service/2]).

-export([has_any_payment_method/2]).

%%

-type t() :: dmsl_domain_thrift:'PaymentTool'().
-type method() :: dmsl_domain_thrift:'PaymentMethodRef'().

-spec get_payment_service(t(), hg_domain:revision()) -> dmsl_domain_thrift:'PaymentService'() | undefined.
get_payment_service({digital_wallet, #domain_DigitalWallet{payment_service = Ref}}, Revision) ->
    try_get_payment_service_w_ref(Ref, Revision);
get_payment_service({payment_terminal, #domain_PaymentTerminal{payment_service = Ref}}, Revision) ->
    try_get_payment_service_w_ref(Ref, Revision);
get_payment_service({_, _}, _Revision) ->
    undefined.

try_get_payment_service_w_ref(undefined, _Revision) ->
    undefined;
try_get_payment_service_w_ref(Ref, Revision) ->
    hg_domain:get(Revision, {payment_service, Ref}).

-spec has_any_payment_method(t(), ordsets:ordset(method())) -> boolean().
has_any_payment_method(PaymentTool, SupportedMethods) ->
    ordsets:is_element(get_possible_method(PaymentTool), SupportedMethods).

-spec get_possible_method(t()) -> method().
get_possible_method({bank_card, #domain_BankCard{payment_system = PS} = BC}) ->
    #domain_PaymentMethodRef{
        id =
            {bank_card, #domain_BankCardPaymentMethod{
                payment_system = PS,
                is_cvv_empty = genlib:define(BC#domain_BankCard.is_cvv_empty, false),
                payment_token = BC#domain_BankCard.payment_token,
                tokenization_method = BC#domain_BankCard.tokenization_method
            }}
    };
%% ===== payment_terminal
get_possible_method({payment_terminal, PaymentTerminal}) ->
    #domain_PaymentMethodRef{
        id = {payment_terminal, PaymentTerminal#domain_PaymentTerminal.payment_service}
    };
%% ===== digital_wallet
get_possible_method({digital_wallet, DigitalWallet}) ->
    #domain_PaymentMethodRef{
        id = {digital_wallet, DigitalWallet#domain_DigitalWallet.payment_service}
    };
%% ===== crypto_currency
get_possible_method({crypto_currency, CC}) ->
    #domain_PaymentMethodRef{
        id = {crypto_currency, CC}
    };
%% ===== mobile_commerce
get_possible_method({mobile_commerce, MobileCommerce}) ->
    #domain_PaymentMethodRef{
        id = {mobile, MobileCommerce#domain_MobileCommerce.operator}
    }.
