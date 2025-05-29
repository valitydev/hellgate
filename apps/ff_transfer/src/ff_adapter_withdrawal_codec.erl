-module(ff_adapter_withdrawal_codec).

-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_msgpack_thrift.hrl").

-export([marshal/2]).
-export([maybe_marshal/2]).
-export([unmarshal/2]).
-export([marshal_msgpack/1]).
-export([unmarshal_msgpack/1]).

-type type_name() :: atom() | {list, atom()}.
-type codec() :: module().

-type encoded_value() :: encoded_value(any()).
-type encoded_value(T) :: T.

-type decoded_value() :: decoded_value(any()).
-type decoded_value(T) :: T.

%% as stolen from `machinery_msgpack`
-type md() ::
    nil
    | boolean()
    | integer()
    | float()
    %% string
    | binary()
    %% binary
    | {binary, binary()}
    | [md()]
    | #{md() => md()}.

-export_type([codec/0]).
-export_type([type_name/0]).
-export_type([encoded_value/0]).
-export_type([encoded_value/1]).
-export_type([decoded_value/0]).
-export_type([decoded_value/1]).

%% @TODO: Make supported types for marshall and unmarshall symmetrical

-spec marshal(type_name(), decoded_value()) -> encoded_value().
marshal(adapter_state, undefined) ->
    {nl, #msgpack_Nil{}};
marshal(adapter_state, ASt) ->
    marshal_msgpack(ASt);
marshal(body, {Amount, CurrencyID}) ->
    {ok, Currency} = ff_currency:get(CurrencyID),
    DomainCurrency = marshal(currency, Currency),
    #wthd_provider_Cash{amount = Amount, currency = DomainCurrency};
marshal(callback, #{
    tag := Tag,
    payload := Payload
}) ->
    #wthd_provider_Callback{
        tag = Tag,
        payload = Payload
    };
marshal(
    callback_result,
    #{
        intent := Intent,
        response := Response
    } = Params
) ->
    NextState = genlib_map:get(next_state, Params),
    TransactionInfo = genlib_map:get(transaction_info, Params),
    #wthd_provider_CallbackResult{
        intent = marshal(intent, Intent),
        response = marshal(callback_response, Response),
        next_state = maybe_marshal(adapter_state, NextState),
        trx = maybe_marshal(transaction_info, TransactionInfo)
    };
marshal(callback_response, #{payload := Payload}) ->
    #wthd_provider_CallbackResponse{payload = Payload};
marshal(currency, #{
    name := Name,
    symcode := Symcode,
    numcode := Numcode,
    exponent := Exponent
}) ->
    #domain_Currency{
        name = Name,
        symbolic_code = Symcode,
        numeric_code = Numcode,
        exponent = Exponent
    };
marshal(exp_date, {Month, Year}) ->
    #domain_BankCardExpDate{
        month = Month,
        year = Year
    };
marshal(payment_system, #{id := Ref}) when is_binary(Ref) ->
    #domain_PaymentSystemRef{
        id = Ref
    };
marshal(payment_service, #{id := Ref}) when is_binary(Ref) ->
    #domain_PaymentServiceRef{
        id = Ref
    };
marshal(intent, {finish, success}) ->
    {finish, #wthd_provider_FinishIntent{
        status = {success, #wthd_provider_Success{}}
    }};
marshal(intent, {finish, {success, TrxInfo}}) ->
    {finish, #wthd_provider_FinishIntent{
        status =
            {success, #wthd_provider_Success{
                trx_info = marshal(transaction_info, TrxInfo)
            }}
    }};
marshal(intent, {finish, {failed, Failure}}) ->
    {finish, #wthd_provider_FinishIntent{
        status = {failure, ff_dmsl_codec:marshal(failure, Failure)}
    }};
marshal(intent, {sleep, V = #{timer := Timer}}) ->
    {sleep, #wthd_provider_SleepIntent{
        timer = ff_codec:marshal(timer, Timer),
        callback_tag = maps:get(tag, V, undefined)
    }};
marshal(process_callback_result, {succeeded, CallbackResponse}) ->
    {succeeded, #wthd_provider_ProcessCallbackSucceeded{
        response = marshal(callback_response, CallbackResponse)
    }};
marshal(
    process_callback_result,
    {finished, #{
        withdrawal := Withdrawal,
        state := AdapterState,
        opts := Options
    }}
) ->
    {finished, #wthd_provider_ProcessCallbackFinished{
        withdrawal = marshal(withdrawal, Withdrawal),
        state = marshal(adapter_state, AdapterState),
        opts = Options
    }};
marshal(
    quote_params,
    #{
        currency_from := CurrencyIDFrom,
        currency_to := CurrencyIDTo,
        body := Body
    } = Params
) ->
    ExternalID = maps:get(external_id, Params, undefined),
    Resource = maps:get(resource, Params, undefined),
    {ok, CurrencyFrom} = ff_currency:get(CurrencyIDFrom),
    {ok, CurrencyTo} = ff_currency:get(CurrencyIDTo),
    #wthd_provider_GetQuoteParams{
        idempotency_id = ExternalID,
        destination = maybe_marshal(resource, Resource),
        currency_from = marshal(currency, CurrencyFrom),
        currency_to = marshal(currency, CurrencyTo),
        exchange_cash = marshal(body, Body)
    };
marshal(quote, #{
    cash_from := CashFrom,
    cash_to := CashTo,
    created_at := CreatedAt,
    expires_on := ExpiresOn,
    quote_data := QuoteData
}) ->
    #wthd_provider_Quote{
        cash_from = marshal(body, CashFrom),
        cash_to = marshal(body, CashTo),
        created_at = CreatedAt,
        expires_on = ExpiresOn,
        quote_data = marshal_msgpack(QuoteData)
    };
marshal(
    resource,
    {bank_card, #{
        bank_card := #{
            token := Token,
            bin := BIN,
            masked_pan := LastDigits
        } = BankCard
    }}
) ->
    CardHolderName = maps:get(cardholder_name, BankCard, undefined),
    ExpDate = maps:get(exp_date, BankCard, undefined),
    PaymentSystem = maps:get(payment_system, BankCard, undefined),
    IssuerCountry = maps:get(issuer_country, BankCard, undefined),
    {bank_card, #domain_BankCard{
        token = Token,
        payment_system = maybe_marshal(payment_system, PaymentSystem),
        issuer_country = IssuerCountry,
        bin = BIN,
        last_digits = LastDigits,
        cardholder_name = CardHolderName,
        exp_date = maybe_marshal(exp_date, ExpDate)
    }};
marshal(
    resource,
    {crypto_wallet, #{
        crypto_wallet := CryptoWallet = #{
            id := CryptoWalletID,
            currency := Currency
        }
    }}
) ->
    {crypto_wallet, #domain_CryptoWallet{
        id = CryptoWalletID,
        crypto_currency = ff_dmsl_codec:marshal(crypto_currency, Currency),
        destination_tag = maps:get(tag, CryptoWallet, undefined)
    }};
marshal(
    resource,
    {digital_wallet, #{
        digital_wallet := Wallet = #{
            id := DigitalWalletID,
            payment_service := PaymentService
        }
    }}
) ->
    Token = maps:get(token, Wallet, undefined),
    {digital_wallet, #domain_DigitalWallet{
        id = DigitalWalletID,
        token = Token,
        payment_service = marshal(payment_service, PaymentService),
        account_name = maps:get(account_name, Wallet, undefined),
        account_identity_number = maps:get(account_identity_number, Wallet, undefined)
    }};
marshal(resource, {generic, _} = Resource) ->
    ff_dmsl_codec:marshal(payment_tool, Resource);
marshal(
    withdrawal,
    #{
        id := ID,
        cash := Cash,
        resource := Resource,
        sender := Sender,
        receiver := Receiver
    } = Withdrawal
) ->
    SesID = maps:get(session_id, Withdrawal, undefined),
    DestAuthData = maps:get(dest_auth_data, Withdrawal, undefined),
    #wthd_provider_Withdrawal{
        id = ID,
        session_id = SesID,
        body = marshal(body, Cash),
        destination = marshal(resource, Resource),
        sender = Sender,
        receiver = Receiver,
        auth_data = maybe_marshal(auth_data, DestAuthData),
        quote = maybe_marshal(quote, maps:get(quote, Withdrawal, undefined))
    };
marshal(transaction_info, TrxInfo) ->
    ff_dmsl_codec:marshal(transaction_info, TrxInfo);
marshal(auth_data, #{
    sender := SenderToken,
    receiver := ReceiverToken
}) ->
    {sender_receiver, #wthd_domain_SenderReceiverAuthData{
        sender = SenderToken,
        receiver = ReceiverToken
    }}.

%%

-spec unmarshal(ff_codec:type_name(), ff_codec:encoded_value()) -> ff_codec:decoded_value().
unmarshal(adapter_state, ASt) ->
    unmarshal_msgpack(ASt);
unmarshal(body, #wthd_provider_Cash{
    amount = Amount,
    currency = DomainCurrency
}) ->
    CurrencyID = ff_currency:id(unmarshal(currency, DomainCurrency)),
    {Amount, CurrencyID};
unmarshal(callback, #wthd_provider_Callback{
    tag = Tag,
    payload = Payload
}) ->
    #{tag => Tag, payload => Payload};
unmarshal(process_result, #wthd_provider_ProcessResult{
    intent = Intent,
    next_state = NextState,
    trx = TransactionInfo
}) ->
    genlib_map:compact(#{
        intent => unmarshal(intent, Intent),
        next_state => maybe_unmarshal(adapter_state, NextState),
        transaction_info => maybe_unmarshal(transaction_info, TransactionInfo)
    });
unmarshal(callback_result, #wthd_provider_CallbackResult{
    intent = Intent,
    next_state = NextState,
    response = Response,
    trx = TransactionInfo
}) ->
    genlib_map:compact(#{
        intent => unmarshal(intent, Intent),
        response => unmarshal(callback_response, Response),
        next_state => maybe_unmarshal(adapter_state, NextState),
        transaction_info => maybe_unmarshal(transaction_info, TransactionInfo)
    });
unmarshal(callback_response, #wthd_provider_CallbackResponse{payload = Payload}) ->
    #{payload => Payload};
unmarshal(currency, #domain_Currency{
    name = Name,
    symbolic_code = Symcode,
    numeric_code = Numcode,
    exponent = Exponent
}) ->
    #{
        id => Symcode,
        name => Name,
        symcode => Symcode,
        numcode => Numcode,
        exponent => Exponent
    };
unmarshal(exp_date, #domain_BankCardExpDate{
    month = Month,
    year = Year
}) ->
    {Month, Year};
unmarshal(
    intent, {finish, #wthd_provider_FinishIntent{status = {success, #wthd_provider_Success{trx_info = undefined}}}}
) ->
    {finish, success};
unmarshal(
    intent, {finish, #wthd_provider_FinishIntent{status = {success, #wthd_provider_Success{trx_info = TrxInfo}}}}
) ->
    {finish, {success, unmarshal(transaction_info, TrxInfo)}};
unmarshal(intent, {finish, #wthd_provider_FinishIntent{status = {failure, Failure}}}) ->
    {finish, {failed, ff_dmsl_codec:unmarshal(failure, Failure)}};
unmarshal(intent, {sleep, #wthd_provider_SleepIntent{timer = Timer, callback_tag = Tag}}) ->
    {sleep,
        genlib_map:compact(#{
            timer => ff_codec:unmarshal(timer, Timer),
            tag => Tag
        })};
unmarshal(process_callback_result, _NotImplemented) ->
    %@TODO
    erlang:error(not_implemented);
unmarshal(quote_params, _NotImplemented) ->
    %@TODO
    erlang:error(not_implemented);
unmarshal(quote, #wthd_provider_Quote{
    cash_from = CashFrom,
    cash_to = CashTo,
    created_at = CreatedAt,
    expires_on = ExpiresOn,
    quote_data = QuoteData
}) ->
    #{
        cash_from => unmarshal(body, CashFrom),
        cash_to => unmarshal(body, CashTo),
        created_at => CreatedAt,
        expires_on => ExpiresOn,
        quote_data => unmarshal_msgpack(QuoteData)
    };
unmarshal(resource, _NotImplemented) ->
    %@TODO
    erlang:error(not_implemented);
unmarshal(withdrawal, _NotImplemented) ->
    %@TODO
    erlang:error(not_implemented);
unmarshal(transaction_info, TransactionInfo) ->
    ff_dmsl_codec:unmarshal(transaction_info, TransactionInfo).

%%
-spec maybe_marshal(type_name(), decoded_value() | undefined) -> encoded_value() | undefined.
maybe_marshal(_Type, undefined) ->
    undefined;
maybe_marshal(Type, Value) ->
    marshal(Type, Value).

maybe_unmarshal(_Type, undefined) ->
    undefined;
maybe_unmarshal(Type, Value) ->
    unmarshal(Type, Value).

-spec marshal_msgpack(md()) -> tuple().
marshal_msgpack(nil) ->
    {nl, #msgpack_Nil{}};
marshal_msgpack(V) when is_boolean(V) ->
    {b, V};
marshal_msgpack(V) when is_integer(V) ->
    {i, V};
marshal_msgpack(V) when is_float(V) ->
    V;
% Assuming well-formed UTF-8 bytestring.
marshal_msgpack(V) when is_binary(V) ->
    {str, V};
marshal_msgpack({binary, V}) when is_binary(V) ->
    {bin, V};
marshal_msgpack(V) when is_list(V) ->
    {arr, [marshal_msgpack(ListItem) || ListItem <- V]};
marshal_msgpack(V) when is_map(V) ->
    {obj, maps:fold(fun(Key, Value, Map) -> Map#{marshal_msgpack(Key) => marshal_msgpack(Value)} end, #{}, V)}.

-spec unmarshal_msgpack(tuple()) -> md().
unmarshal_msgpack({nl, #msgpack_Nil{}}) ->
    nil;
unmarshal_msgpack({b, V}) when is_boolean(V) ->
    V;
unmarshal_msgpack({i, V}) when is_integer(V) ->
    V;
unmarshal_msgpack({flt, V}) when is_float(V) ->
    V;
% Assuming well-formed UTF-8 bytestring.
unmarshal_msgpack({str, V}) when is_binary(V) ->
    V;
unmarshal_msgpack({bin, V}) when is_binary(V) ->
    {binary, V};
unmarshal_msgpack({arr, V}) when is_list(V) ->
    [unmarshal_msgpack(ListItem) || ListItem <- V];
unmarshal_msgpack({obj, V}) when is_map(V) ->
    maps:fold(fun(Key, Value, Map) -> Map#{unmarshal_msgpack(Key) => unmarshal_msgpack(Value)} end, #{}, V).
