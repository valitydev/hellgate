%%% Payment tools

-module(hg_payment_tool).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%%

-export([get_payment_service/2]).

-export([has_any_payment_method/2]).
-export([unmarshal/1]).

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

%% Unmarshalling

-include("legacy_structures.hrl").

-spec unmarshal(hg_msgpack_marshalling:value()) -> t().
unmarshal(PaymentTool) ->
    unmarshal(payment_tool, PaymentTool).

unmarshal(payment_tool, [3, PMV, V]) ->
    PaymentMethod = payment_method(PMV),
    {PaymentMethod, unmarshal(PaymentMethod, V)};
unmarshal(payment_tool, [2, #{<<"token">> := _} = BankCard]) ->
    {bank_card, unmarshal(bank_card, BankCard)};
unmarshal(payment_tool, [1, ?legacy_bank_card(Token, PaymentSystem, Bin, MaskedPan)]) ->
    BCard = #domain_BankCard{
        token = unmarshal(str, Token),
        bin = unmarshal(str, Bin),
        last_digits = unmarshal(str, MaskedPan)
    },
    {bank_card, set_payment_system(BCard, PaymentSystem)};
unmarshal(payment_tool, [2, TerminalType]) when is_binary(TerminalType) ->
    {payment_terminal, unmarshal(payment_terminal, TerminalType)};
unmarshal(
    bank_card = T,
    #{
        <<"token">> := Token,
        <<"payment_system">> := PaymentSystem,
        <<"bin">> := Bin,
        <<"masked_pan">> := MaskedPan
    } = V
) ->
    TokenProvider = genlib_map:get(<<"token_provider">>, V),
    IssuerCountry = genlib_map:get(<<"issuer_country">>, V),
    BankName = genlib_map:get(<<"bank_name">>, V),
    MD = genlib_map:get(<<"metadata">>, V),
    IsCVVEmpty = genlib_map:get(<<"is_cvv_empty">>, V),
    BCard = #domain_BankCard{
        token = unmarshal(str, Token),
        bin = unmarshal(str, Bin),
        last_digits = unmarshal(str, MaskedPan),
        issuer_country = unmarshal({T, issuer_country}, IssuerCountry),
        bank_name = unmarshal(str, BankName),
        metadata = unmarshal({T, metadata}, MD),
        is_cvv_empty = unmarshal({T, boolean}, IsCVVEmpty)
    },
    set_token_provider(
        set_payment_system(BCard, PaymentSystem),
        TokenProvider
    );
unmarshal(payment_terminal, TerminalType) ->
    #domain_PaymentTerminal{payment_service = #domain_PaymentServiceRef{id = TerminalType}};
unmarshal(digital_wallet, #{
    <<"provider">> := Provider,
    <<"id">> := ID
}) when is_binary(Provider) ->
    setelement(
        #domain_DigitalWallet.payment_service,
        #domain_DigitalWallet{id = unmarshal(str, ID)},
        #domain_PaymentServiceRef{id = Provider}
    );
unmarshal(crypto_currency, CC) when is_binary(CC) ->
    {crypto_currency, #domain_CryptoCurrencyRef{id = CC}};
unmarshal(mobile_commerce, #{
    <<"operator">> := Operator,
    <<"phone">> := #{cc := CC, ctn := Ctn}
}) ->
    PTool = #domain_MobileCommerce{
        phone = #domain_MobilePhone{
            cc = unmarshal(str, CC),
            ctn = unmarshal(str, Ctn)
        }
    },
    setelement(#domain_MobileCommerce.operator, PTool, #domain_MobileOperatorRef{id = Operator});
unmarshal({bank_card, issuer_country}, Residence) when is_binary(Residence) ->
    binary_to_existing_atom(unmarshal(str, Residence), utf8);
unmarshal({bank_card, metadata}, MD) when is_map(MD) ->
    maps:map(fun(_, V) -> hg_msgpack_marshalling:marshal(V) end, MD);
unmarshal({bank_card, boolean}, <<"true">>) ->
    true;
unmarshal({bank_card, boolean}, <<"false">>) ->
    false;
unmarshal(_, Other) ->
    Other.

payment_method(<<"card">>) ->
    bank_card;
payment_method(<<"payterm">>) ->
    payment_terminal;
payment_method(<<"wallet">>) ->
    digital_wallet;
payment_method(<<"crypto_currency">>) ->
    crypto_currency;
payment_method(<<"mobile_commerce">>) ->
    mobile_commerce.

set_payment_system(BCard, PSysBin) when is_binary(PSysBin) ->
    setelement(#domain_BankCard.payment_system, BCard, #domain_PaymentSystemRef{id = PSysBin}).

set_token_provider(BCard, TokenProvider) when is_binary(TokenProvider) ->
    setelement(#domain_BankCard.payment_token, BCard, #domain_BankCardTokenServiceRef{id = TokenProvider});
set_token_provider(BCard, _) ->
    BCard.
