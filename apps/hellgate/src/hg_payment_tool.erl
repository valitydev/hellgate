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
    not ordsets:is_disjoint(get_possible_methods(PaymentTool), SupportedMethods).

-spec get_possible_methods(t()) -> ordsets:ordset(method()).
get_possible_methods(
    {bank_card, #domain_BankCard{payment_system_deprecated = PS, is_cvv_empty = true} = BankCard}
) ->
    ordsets:add_element(
        #domain_PaymentMethodRef{id = {empty_cvv_bank_card_deprecated, PS}},
        get_possible_bank_card_methods(BankCard)
    );
get_possible_methods(
    {bank_card, #domain_BankCard{payment_system_deprecated = PS, token_provider_deprecated = undefined} = BankCard}
) ->
    ordsets:add_element(
        #domain_PaymentMethodRef{id = {bank_card_deprecated, PS}},
        get_possible_bank_card_methods(BankCard)
    );
get_possible_methods(
    {bank_card,
        #domain_BankCard{
            payment_system_deprecated = PaymentSystem,
            token_provider_deprecated = TokenProvider,
            tokenization_method = none
        } = BankCard}
) when PaymentSystem /= undefined andalso TokenProvider /= undefined ->
    ordsets:add_element(
        #domain_PaymentMethodRef{id = {bank_card_deprecated, PaymentSystem}},
        get_possible_bank_card_methods(BankCard)
    );
get_possible_methods(
    {bank_card,
        #domain_BankCard{
            payment_system_deprecated = PaymentSystem,
            token_provider_deprecated = TokenProvider
        } = BankCard}
) when PaymentSystem /= undefined andalso TokenProvider /= undefined ->
    ordsets:add_element(
        #domain_PaymentMethodRef{
            id =
                {tokenized_bank_card_deprecated, #domain_TokenizedBankCard{
                    payment_system_deprecated = PaymentSystem,
                    token_provider_deprecated = TokenProvider,
                    tokenization_method = undefined
                }}
        },
        get_possible_bank_card_methods(BankCard)
    );
%% ===== payment_terminal
get_possible_methods({payment_terminal, PaymentTerminal}) ->
    filtermap_payment_methods_to_set([
        {payment_terminal_deprecated, PaymentTerminal#domain_PaymentTerminal.terminal_type_deprecated},
        {payment_terminal, PaymentTerminal#domain_PaymentTerminal.payment_service}
    ]);
%% ===== digital_wallet
get_possible_methods({digital_wallet, DigitalWallet}) ->
    filtermap_payment_methods_to_set([
        {digital_wallet_deprecated, DigitalWallet#domain_DigitalWallet.provider_deprecated},
        {digital_wallet, DigitalWallet#domain_DigitalWallet.payment_service}
    ]);
%% ===== crypto_currency
get_possible_methods({crypto_currency_deprecated, CC}) ->
    ordsets:from_list([
        #domain_PaymentMethodRef{id = {crypto_currency_deprecated, CC}}
    ]);
get_possible_methods({crypto_currency, CC}) ->
    ordsets:from_list([
        #domain_PaymentMethodRef{id = {crypto_currency, CC}}
    ]);
%% ===== mobile_commerce
get_possible_methods({mobile_commerce, MobileCommerce}) ->
    filtermap_payment_methods_to_set([
        {mobile_deprecated, MobileCommerce#domain_MobileCommerce.operator_deprecated},
        {mobile, MobileCommerce#domain_MobileCommerce.operator}
    ]).

get_possible_bank_card_methods(BankCard) ->
    filtermap_payment_methods_to_set([
        {bank_card, maybe_legacy_bank_card(BankCard)},
        {bank_card, maybe_bank_card(BankCard)}
    ]).

filtermap_payment_methods_to_set(ItemList) ->
    ordsets:from_list(
        lists:filtermap(
            fun
                ({_K, undefined}) -> false;
                (V) -> {true, #domain_PaymentMethodRef{id = V}}
            end,
            ItemList
        )
    ).

maybe_legacy_bank_card(#domain_BankCard{payment_system_deprecated = PS} = BC) when PS /= undefined ->
    #domain_BankCardPaymentMethod{
        payment_system_deprecated = BC#domain_BankCard.payment_system_deprecated,
        is_cvv_empty = genlib:define(BC#domain_BankCard.is_cvv_empty, false),
        token_provider_deprecated = BC#domain_BankCard.token_provider_deprecated,
        tokenization_method = BC#domain_BankCard.tokenization_method
    };
maybe_legacy_bank_card(_) ->
    undefined.

maybe_bank_card(#domain_BankCard{payment_system = PS} = BC) when PS /= undefined ->
    #domain_BankCardPaymentMethod{
        payment_system = PS,
        is_cvv_empty = genlib:define(BC#domain_BankCard.is_cvv_empty, false),
        payment_token = BC#domain_BankCard.payment_token,
        tokenization_method = BC#domain_BankCard.tokenization_method
    };
maybe_bank_card(_) ->
    undefined.
