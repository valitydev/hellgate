-module(ff_codec).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_repairer_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_evsink_thrift.hrl").

-export([unmarshal/2]).
-export([unmarshal/3]).

-export([marshal/2]).
-export([marshal/3]).

%% Types

-type type_name() :: atom() | {list, atom()} | {set, atom()}.
-type codec() :: module().

-type encoded_value() :: encoded_value(any()).
-type encoded_value(T) :: T.

-type decoded_value() :: decoded_value(any()).
-type decoded_value(T) :: T.

-export_type([codec/0]).
-export_type([type_name/0]).
-export_type([encoded_value/0]).
-export_type([encoded_value/1]).
-export_type([decoded_value/0]).
-export_type([decoded_value/1]).

%% Callbacks

-callback unmarshal(type_name(), encoded_value()) -> decoded_value().
-callback marshal(type_name(), decoded_value()) -> encoded_value().

%% API

-spec unmarshal(codec(), type_name(), encoded_value()) -> decoded_value().
unmarshal(Codec, Type, Value) ->
    Codec:unmarshal(Type, Value).

-spec marshal(codec(), type_name(), decoded_value()) -> encoded_value().
marshal(Codec, Type, Value) ->
    Codec:marshal(Type, Value).

%% Generic codec

-spec marshal(type_name(), decoded_value()) -> encoded_value().
marshal({list, T}, V) ->
    [marshal(T, E) || E <- V];
marshal({set, T}, V) ->
    ordsets:from_list([marshal(T, E) || E <- ordsets:to_list(V)]);
marshal(id, V) ->
    marshal(string, V);
marshal(event_id, V) ->
    marshal(integer, V);
marshal(provider_id, V) ->
    marshal(integer, V);
marshal(terminal_id, V) ->
    marshal(integer, V);
marshal(blocking, blocked) ->
    blocked;
marshal(blocking, unblocked) ->
    unblocked;
marshal(identity_provider, Provider) when is_binary(Provider) ->
    Provider;
marshal(withdrawal_method, #{id := {generic, #{payment_service := PaymentService}}}) ->
    {generic, marshal(payment_service, PaymentService)};
marshal(withdrawal_method, #{id := {digital_wallet, PaymentService}}) ->
    {digital_wallet, marshal(payment_service, PaymentService)};
marshal(withdrawal_method, #{id := {crypto_currency, CryptoCurrencyRef}}) ->
    {crypto_currency, marshal(crypto_currency, CryptoCurrencyRef)};
marshal(withdrawal_method, #{id := {bank_card, #{payment_system := PaymentSystem}}}) ->
    {bank_card, #'fistful_BankCardWithdrawalMethod'{
        payment_system = marshal(payment_system, PaymentSystem)
    }};
marshal(
    transaction_info,
    #{
        id := TransactionID,
        extra := Extra
    } = TransactionInfo
) ->
    Timestamp = maps:get(timestamp, TransactionInfo, undefined),
    AddInfo = maps:get(additional_info, TransactionInfo, undefined),
    #'fistful_base_TransactionInfo'{
        id = marshal(id, TransactionID),
        timestamp = marshal(timestamp, Timestamp),
        extra = Extra,
        additional_info = marshal(additional_transaction_info, AddInfo)
    };
marshal(additional_transaction_info, #{} = AddInfo) ->
    #'fistful_base_AdditionalTransactionInfo'{
        rrn = marshal(string, maps:get(rrn, AddInfo, undefined)),
        approval_code = marshal(string, maps:get(approval_code, AddInfo, undefined)),
        acs_url = marshal(string, maps:get(acs_url, AddInfo, undefined)),
        pareq = marshal(string, maps:get(pareq, AddInfo, undefined)),
        md = marshal(string, maps:get(md, AddInfo, undefined)),
        term_url = marshal(string, maps:get(term_url, AddInfo, undefined)),
        pares = marshal(string, maps:get(pares, AddInfo, undefined)),
        eci = marshal(string, maps:get(eci, AddInfo, undefined)),
        cavv = marshal(string, maps:get(cavv, AddInfo, undefined)),
        xid = marshal(string, maps:get(xid, AddInfo, undefined)),
        cavv_algorithm = marshal(string, maps:get(cavv_algorithm, AddInfo, undefined)),
        three_ds_verification = marshal(
            three_ds_verification,
            maps:get(three_ds_verification, AddInfo, undefined)
        )
    };
marshal(three_ds_verification, Value) when
    Value =:= authentication_successful orelse
        Value =:= attempts_processing_performed orelse
        Value =:= authentication_failed orelse
        Value =:= authentication_could_not_be_performed
->
    Value;
marshal(account_change, {created, Account}) ->
    {created, marshal(account, Account)};
marshal(account, #{
    id := ID,
    identity := IdentityID,
    currency := CurrencyID,
    accounter_account_id := AAID
}) ->
    #'account_Account'{
        id = marshal(id, ID),
        identity = marshal(id, IdentityID),
        currency = marshal(currency_ref, CurrencyID),
        accounter_account_id = marshal(event_id, AAID)
    };
marshal(resource, {bank_card, #{bank_card := BankCard} = ResourceBankCard}) ->
    {bank_card, #'fistful_base_ResourceBankCard'{
        bank_card = marshal(bank_card, BankCard),
        auth_data = maybe_marshal(bank_card_auth_data, maps:get(auth_data, ResourceBankCard, undefined))
    }};
marshal(resource, {crypto_wallet, #{crypto_wallet := CryptoWallet}}) ->
    {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{
        crypto_wallet = marshal(crypto_wallet, CryptoWallet)
    }};
marshal(resource, {digital_wallet, #{digital_wallet := DigitalWallet}}) ->
    {digital_wallet, #'fistful_base_ResourceDigitalWallet'{
        digital_wallet = marshal(digital_wallet, DigitalWallet)
    }};
marshal(resource, {generic, #{generic := Generic}}) ->
    {generic, #'fistful_base_ResourceGeneric'{
        generic = marshal(generic_resource, Generic)
    }};
marshal(resource_descriptor, {bank_card, BinDataID}) ->
    {bank_card, #'fistful_base_ResourceDescriptorBankCard'{
        bin_data_id = marshal(msgpack, BinDataID)
    }};
marshal(bank_card, #{token := Token} = BankCard) ->
    Bin = maps:get(bin, BankCard, undefined),
    PaymentSystem = ff_resource:payment_system(BankCard),
    MaskedPan = ff_resource:masked_pan(BankCard),
    BankName = ff_resource:bank_name(BankCard),
    IssuerCountry = ff_resource:issuer_country(BankCard),
    CardType = ff_resource:card_type(BankCard),
    ExpDate = ff_resource:exp_date(BankCard),
    CardholderName = ff_resource:cardholder_name(BankCard),
    BinDataID = ff_resource:bin_data_id(BankCard),
    #'fistful_base_BankCard'{
        token = marshal(string, Token),
        bin = marshal(string, Bin),
        masked_pan = marshal(string, MaskedPan),
        bank_name = marshal(string, BankName),
        payment_system = maybe_marshal(payment_system, PaymentSystem),
        issuer_country = maybe_marshal(issuer_country, IssuerCountry),
        card_type = maybe_marshal(card_type, CardType),
        exp_date = maybe_marshal(exp_date, ExpDate),
        cardholder_name = maybe_marshal(string, CardholderName),
        bin_data_id = maybe_marshal(msgpack, BinDataID)
    };
marshal(bank_card_auth_data, {session, #{session_id := ID}}) ->
    {session_data, #'fistful_base_SessionAuthData'{
        id = marshal(string, ID)
    }};
marshal(crypto_wallet, #{id := ID, currency := Currency} = CryptoWallet) ->
    #'fistful_base_CryptoWallet'{
        id = marshal(string, ID),
        currency = marshal(crypto_currency, Currency),
        tag = maybe_marshal(string, maps:get(tag, CryptoWallet, undefined))
    };
marshal(digital_wallet, #{id := ID, payment_service := PaymentService} = Wallet) ->
    #'fistful_base_DigitalWallet'{
        id = marshal(string, ID),
        token = maybe_marshal(string, maps:get(token, Wallet, undefined)),
        payment_service = marshal(payment_service, PaymentService),
        account_name = maybe_marshal(string, maps:get(account_name, Wallet, undefined)),
        account_identity_number = maybe_marshal(string, maps:get(account_identity_number, Wallet, undefined))
    };
marshal(generic_resource, #{provider := PaymentService} = Generic) ->
    #'fistful_base_ResourceGenericData'{
        provider = marshal(payment_service, PaymentService),
        data = maybe_marshal(content, maps:get(data, Generic, undefined))
    };
marshal(exp_date, {Month, Year}) ->
    #'fistful_base_BankCardExpDate'{
        month = marshal(integer, Month),
        year = marshal(integer, Year)
    };
marshal(crypto_currency, #{id := Ref}) when is_binary(Ref) ->
    #'fistful_base_CryptoCurrencyRef'{
        id = Ref
    };
marshal(payment_service, #{id := Ref}) when is_binary(Ref) ->
    #'fistful_base_PaymentServiceRef'{
        id = Ref
    };
marshal(payment_system, #{id := Ref}) when is_binary(Ref) ->
    #'fistful_base_PaymentSystemRef'{
        id = Ref
    };
marshal(issuer_country, V) when is_atom(V) ->
    V;
marshal(card_type, V) when is_atom(V) ->
    V;
marshal(cash, {Amount, CurrencyRef}) ->
    #'fistful_base_Cash'{
        amount = marshal(amount, Amount),
        currency = marshal(currency_ref, CurrencyRef)
    };
marshal(content, #{type := Type, data := Data}) ->
    #'fistful_base_Content'{
        type = marshal(string, Type),
        data = Data
    };
marshal(cash_range, {{BoundLower, CashLower}, {BoundUpper, CashUpper}}) ->
    #'fistful_base_CashRange'{
        lower = {BoundLower, marshal(cash, CashLower)},
        upper = {BoundUpper, marshal(cash, CashUpper)}
    };
marshal(currency_ref, CurrencyID) when is_binary(CurrencyID) ->
    #'fistful_base_CurrencyRef'{
        symbolic_code = CurrencyID
    };
marshal(amount, V) ->
    marshal(integer, V);
marshal(event_range, {After, Limit}) ->
    #'fistful_base_EventRange'{
        'after' = maybe_marshal(integer, After),
        limit = maybe_marshal(integer, Limit)
    };
marshal(failure, Failure) ->
    #'fistful_base_Failure'{
        code = marshal(string, ff_failure:code(Failure)),
        reason = maybe_marshal(string, ff_failure:reason(Failure)),
        sub = maybe_marshal(sub_failure, ff_failure:sub_failure(Failure))
    };
marshal(sub_failure, Failure) ->
    #'fistful_base_SubFailure'{
        code = marshal(string, ff_failure:code(Failure)),
        sub = maybe_marshal(sub_failure, ff_failure:sub_failure(Failure))
    };
marshal(fees, Fees) ->
    #'fistful_base_Fees'{
        fees = maps:map(fun(_Constant, Value) -> marshal(cash, Value) end, maps:get(fees, Fees))
    };
marshal(timer, {timeout, Timeout}) ->
    {timeout, marshal(integer, Timeout)};
marshal(timer, {deadline, Deadline}) ->
    {deadline, marshal(timestamp, Deadline)};
marshal(timestamp, {DateTime, USec}) ->
    DateTimeinSeconds = genlib_time:daytime_to_unixtime(DateTime),
    {TimeinUnit, Unit} =
        case USec of
            0 ->
                {DateTimeinSeconds, second};
            USec ->
                MicroSec = erlang:convert_time_unit(DateTimeinSeconds, second, microsecond),
                {MicroSec + USec, microsecond}
        end,
    genlib_rfc3339:format_relaxed(TimeinUnit, Unit);
marshal(timestamp_ms, V) ->
    ff_time:to_rfc3339(V);
marshal(domain_revision, V) when is_integer(V) ->
    V;
marshal(party_revision, V) when is_integer(V) ->
    V;
marshal(string, V) when is_binary(V) ->
    V;
marshal(integer, V) when is_integer(V) ->
    V;
marshal(bool, V) when is_boolean(V) ->
    V;
marshal(context, V) when is_map(V) ->
    ff_entity_context_codec:marshal(V);
marshal(msgpack, V) ->
    ff_msgpack_codec:marshal(msgpack, V);
% Catch this up in thrift validation
marshal(_, Other) ->
    Other.

-spec unmarshal(type_name(), encoded_value()) -> decoded_value().
unmarshal({list, T}, V) ->
    [marshal(T, E) || E <- V];
unmarshal({set, T}, V) ->
    ordsets:from_list([unmarshal(T, E) || E <- ordsets:to_list(V)]);
unmarshal(id, V) ->
    unmarshal(string, V);
unmarshal(event_id, V) ->
    unmarshal(integer, V);
unmarshal(provider_id, V) ->
    unmarshal(integer, V);
unmarshal(terminal_id, V) ->
    unmarshal(integer, V);
unmarshal(blocking, blocked) ->
    blocked;
unmarshal(blocking, unblocked) ->
    unblocked;
unmarshal(transaction_info, #'fistful_base_TransactionInfo'{
    id = TransactionID,
    timestamp = Timestamp,
    extra = Extra,
    additional_info = AddInfo
}) ->
    genlib_map:compact(#{
        id => unmarshal(string, TransactionID),
        timestamp => maybe_unmarshal(string, Timestamp),
        extra => Extra,
        additional_info => maybe_unmarshal(additional_transaction_info, AddInfo)
    });
unmarshal(additional_transaction_info, #'fistful_base_AdditionalTransactionInfo'{
    rrn = RRN,
    approval_code = ApprovalCode,
    acs_url = AcsURL,
    pareq = Pareq,
    md = MD,
    term_url = TermURL,
    pares = Pares,
    eci = ECI,
    cavv = CAVV,
    xid = XID,
    cavv_algorithm = CAVVAlgorithm,
    three_ds_verification = ThreeDSVerification
}) ->
    genlib_map:compact(#{
        rrn => maybe_unmarshal(string, RRN),
        approval_code => maybe_unmarshal(string, ApprovalCode),
        acs_url => maybe_unmarshal(string, AcsURL),
        pareq => maybe_unmarshal(string, Pareq),
        md => maybe_unmarshal(string, MD),
        term_url => maybe_unmarshal(string, TermURL),
        pares => maybe_unmarshal(string, Pares),
        eci => maybe_unmarshal(string, ECI),
        cavv => maybe_unmarshal(string, CAVV),
        xid => maybe_unmarshal(string, XID),
        cavv_algorithm => maybe_unmarshal(string, CAVVAlgorithm),
        three_ds_verification => maybe_unmarshal(three_ds_verification, ThreeDSVerification)
    });
unmarshal(three_ds_verification, Value) when
    Value =:= authentication_successful orelse
        Value =:= attempts_processing_performed orelse
        Value =:= authentication_failed orelse
        Value =:= authentication_could_not_be_performed
->
    Value;
unmarshal(complex_action, #repairer_ComplexAction{
    timer = TimerAction,
    remove = RemoveAction
}) ->
    unmarshal(timer_action, TimerAction) ++ unmarshal(remove_action, RemoveAction);
unmarshal(timer_action, undefined) ->
    [];
unmarshal(timer_action, {set_timer, SetTimerAction}) ->
    [{set_timer, unmarshal(set_timer_action, SetTimerAction)}];
unmarshal(timer_action, {unset_timer, #repairer_UnsetTimerAction{}}) ->
    [unset_timer];
unmarshal(remove_action, undefined) ->
    [];
unmarshal(remove_action, #repairer_RemoveAction{}) ->
    [remove];
unmarshal(set_timer_action, #repairer_SetTimerAction{
    timer = Timer
}) ->
    unmarshal(timer, Timer);
unmarshal(timer, {timeout, Timeout}) ->
    {timeout, unmarshal(integer, Timeout)};
unmarshal(timer, {deadline, Deadline}) ->
    {deadline, unmarshal(timestamp, Deadline)};
unmarshal(account_change, {created, Account}) ->
    {created, unmarshal(account, Account)};
unmarshal(account, #'account_Account'{
    id = ID,
    identity = IdentityID,
    currency = CurrencyRef,
    accounter_account_id = AAID
}) ->
    #{
        id => unmarshal(id, ID),
        identity => unmarshal(id, IdentityID),
        currency => unmarshal(currency_ref, CurrencyRef),
        accounter_account_id => unmarshal(accounter_account_id, AAID)
    };
unmarshal(accounter_account_id, V) ->
    unmarshal(integer, V);
unmarshal(
    resource,
    {bank_card, #'fistful_base_ResourceBankCard'{
        bank_card = BankCard,
        auth_data = AuthData
    }}
) ->
    {bank_card,
        genlib_map:compact(#{
            bank_card => unmarshal(bank_card, BankCard),
            auth_data => maybe_unmarshal(bank_card_auth_data, AuthData)
        })};
unmarshal(resource, {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{crypto_wallet = CryptoWallet}}) ->
    {crypto_wallet, #{
        crypto_wallet => unmarshal(crypto_wallet, CryptoWallet)
    }};
unmarshal(resource, {digital_wallet, #'fistful_base_ResourceDigitalWallet'{digital_wallet = DigitalWallet}}) ->
    {digital_wallet, #{
        digital_wallet => unmarshal(digital_wallet, DigitalWallet)
    }};
unmarshal(resource, {generic, #'fistful_base_ResourceGeneric'{generic = GenericResource}}) ->
    {generic, #{
        generic => unmarshal(generic_resource, GenericResource)
    }};
unmarshal(resource_descriptor, {bank_card, BankCard}) ->
    {bank_card, unmarshal(msgpack, BankCard#'fistful_base_ResourceDescriptorBankCard'.bin_data_id)};
unmarshal(bank_card_auth_data, {session_data, #'fistful_base_SessionAuthData'{id = ID}}) ->
    {session, #{
        session_id => unmarshal(string, ID)
    }};
unmarshal(bank_card, #'fistful_base_BankCard'{
    token = Token,
    bin = Bin,
    masked_pan = MaskedPan,
    bank_name = BankName,
    payment_system = PaymentSystem,
    issuer_country = IssuerCountry,
    card_type = CardType,
    bin_data_id = BinDataID,
    exp_date = ExpDate,
    cardholder_name = CardholderName
}) ->
    genlib_map:compact(#{
        token => unmarshal(string, Token),
        payment_system => maybe_unmarshal(payment_system, PaymentSystem),
        bin => maybe_unmarshal(string, Bin),
        masked_pan => maybe_unmarshal(string, MaskedPan),
        bank_name => maybe_unmarshal(string, BankName),
        issuer_country => maybe_unmarshal(issuer_country, IssuerCountry),
        card_type => maybe_unmarshal(card_type, CardType),
        exp_date => maybe_unmarshal(exp_date, ExpDate),
        cardholder_name => maybe_unmarshal(string, CardholderName),
        bin_data_id => maybe_unmarshal(msgpack, BinDataID)
    });
unmarshal(exp_date, #'fistful_base_BankCardExpDate'{
    month = Month,
    year = Year
}) ->
    {unmarshal(integer, Month), unmarshal(integer, Year)};
unmarshal(payment_system, #'fistful_base_PaymentSystemRef'{id = Ref}) when is_binary(Ref) ->
    #{
        id => Ref
    };
unmarshal(issuer_country, V) when is_atom(V) ->
    V;
unmarshal(card_type, V) when is_atom(V) ->
    V;
unmarshal(crypto_wallet, #'fistful_base_CryptoWallet'{
    id = CryptoWalletID,
    currency = Currency,
    tag = Tag
}) ->
    genlib_map:compact(#{
        id => unmarshal(string, CryptoWalletID),
        currency => unmarshal(crypto_currency, Currency),
        tag => maybe_unmarshal(string, Tag)
    });
unmarshal(digital_wallet, #'fistful_base_DigitalWallet'{
    id = ID,
    payment_service = PaymentService,
    token = Token,
    account_name = AccountName,
    account_identity_number = AccountIdentityNumber
}) ->
    genlib_map:compact(#{
        id => unmarshal(string, ID),
        payment_service => unmarshal(payment_service, PaymentService),
        token => maybe_unmarshal(string, Token),
        account_name => maybe_unmarshal(string, AccountName),
        account_identity_number => maybe_unmarshal(string, AccountIdentityNumber)
    });
unmarshal(generic_resource, #'fistful_base_ResourceGenericData'{provider = PaymentService, data = Data}) ->
    genlib_map:compact(#{
        provider => unmarshal(payment_service, PaymentService),
        data => maybe_unmarshal(content, Data)
    });
unmarshal(content, #'fistful_base_Content'{type = Type, data = Data}) ->
    genlib_map:compact(#{
        type => unmarshal(string, Type),
        data => Data
    });
unmarshal(payment_service, #'fistful_base_PaymentServiceRef'{id = Ref}) when is_binary(Ref) ->
    #{
        id => Ref
    };
unmarshal(crypto_currency, #'fistful_base_CryptoCurrencyRef'{id = Ref}) when is_binary(Ref) ->
    #{
        id => Ref
    };
unmarshal(cash, #'fistful_base_Cash'{
    amount = Amount,
    currency = CurrencyRef
}) ->
    {unmarshal(amount, Amount), unmarshal(currency_ref, CurrencyRef)};
unmarshal(cash_range, #'fistful_base_CashRange'{
    lower = {BoundLower, CashLower},
    upper = {BoundUpper, CashUpper}
}) ->
    {
        {BoundLower, unmarshal(cash, CashLower)},
        {BoundUpper, unmarshal(cash, CashUpper)}
    };
unmarshal(currency_ref, #'fistful_base_CurrencyRef'{
    symbolic_code = SymbolicCode
}) ->
    unmarshal(string, SymbolicCode);
unmarshal(amount, V) ->
    unmarshal(integer, V);
unmarshal(event_range, #'fistful_base_EventRange'{'after' = After, limit = Limit}) ->
    {maybe_unmarshal(integer, After), maybe_unmarshal(integer, Limit)};
unmarshal(failure, Failure) ->
    genlib_map:compact(#{
        code => unmarshal(string, Failure#'fistful_base_Failure'.code),
        reason => maybe_unmarshal(string, Failure#'fistful_base_Failure'.reason),
        sub => maybe_unmarshal(sub_failure, Failure#'fistful_base_Failure'.sub)
    });
unmarshal(sub_failure, Failure) ->
    genlib_map:compact(#{
        code => unmarshal(string, Failure#'fistful_base_SubFailure'.code),
        sub => maybe_unmarshal(sub_failure, Failure#'fistful_base_SubFailure'.sub)
    });
unmarshal(context, V) ->
    ff_entity_context_codec:unmarshal(V);
unmarshal(range, #evsink_EventRange{
    'after' = Cursor,
    limit = Limit
}) ->
    {Cursor, Limit, forward};
unmarshal(fees, Fees) ->
    #{
        fees => maps:map(fun(_Constant, Value) -> unmarshal(cash, Value) end, Fees#'fistful_base_Fees'.fees)
    };
unmarshal(timestamp, Timestamp) when is_binary(Timestamp) ->
    parse_timestamp(Timestamp);
unmarshal(timestamp_ms, V) ->
    ff_time:from_rfc3339(V);
unmarshal(domain_revision, V) when is_integer(V) ->
    V;
unmarshal(party_revision, V) when is_integer(V) ->
    V;
unmarshal(string, V) when is_binary(V) ->
    V;
unmarshal(integer, V) when is_integer(V) ->
    V;
unmarshal(msgpack, V) ->
    ff_msgpack_codec:unmarshal(msgpack, V);
unmarshal(range, #'fistful_base_EventRange'{
    'after' = Cursor,
    limit = Limit
}) ->
    {Cursor, Limit, forward};
unmarshal(bool, V) when is_boolean(V) ->
    V.

maybe_unmarshal(_Type, undefined) ->
    undefined;
maybe_unmarshal(Type, Value) ->
    unmarshal(Type, Value).

maybe_marshal(_Type, undefined) ->
    undefined;
maybe_marshal(Type, Value) ->
    marshal(Type, Value).

-spec parse_timestamp(binary()) -> machinery:timestamp().
parse_timestamp(Bin) ->
    try
        MicroSeconds = genlib_rfc3339:parse(Bin, microsecond),
        case genlib_rfc3339:is_utc(Bin) of
            false ->
                erlang:error({bad_timestamp, not_utc}, [Bin]);
            true ->
                USec = MicroSeconds rem 1000000,
                DateTime = calendar:system_time_to_universal_time(MicroSeconds, microsecond),
                {DateTime, USec}
        end
    catch
        error:Error:St ->
            erlang:raise(error, {bad_timestamp, Bin, Error}, St)
    end.

%% TESTS

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec bank_card_codec_test() -> _.

bank_card_codec_test() ->
    BankCard = #{
        token => <<"token">>,
        payment_system => #{id => <<"foo">>},
        bin => <<"12345">>,
        masked_pan => <<"7890">>,
        bank_name => <<"bank">>,
        issuer_country => zmb,
        card_type => credit_or_debit,
        exp_date => {12, 3456},
        cardholder_name => <<"name">>,
        bin_data_id => #{<<"foo">> => 1}
    },
    ResourceBankCard =
        {bank_card, #{
            bank_card => BankCard,
            auth_data => {session, #{session_id => <<"session_id">>}}
        }},
    {bank_card, MarshalledResourceBankCard} = marshal(resource, ResourceBankCard),
    Type = {struct, struct, {fistful_fistful_base_thrift, 'ResourceBankCard'}},
    Binary = ff_proto_utils:serialize(Type, MarshalledResourceBankCard),
    Decoded = ff_proto_utils:deserialize(Type, Binary),
    ?assertEqual(
        Decoded,
        #fistful_base_ResourceBankCard{
            bank_card = #'fistful_base_BankCard'{
                token = <<"token">>,
                payment_system = #'fistful_base_PaymentSystemRef'{id = <<"foo">>},
                bin = <<"12345">>,
                masked_pan = <<"7890">>,
                bank_name = <<"bank">>,
                issuer_country = zmb,
                card_type = credit_or_debit,
                exp_date = #'fistful_base_BankCardExpDate'{month = 12, year = 3456},
                cardholder_name = <<"name">>,
                bin_data_id = {obj, #{{str, <<"foo">>} => {i, 1}}}
            },
            auth_data =
                {session_data, #'fistful_base_SessionAuthData'{
                    id = <<"session_id">>
                }}
        }
    ),
    ?assertEqual(ResourceBankCard, unmarshal(resource, {bank_card, Decoded})).

-spec generic_resource_codec_test() -> _.
generic_resource_codec_test() ->
    GenericResource = #{
        provider => #{id => <<"foo">>},
        data => #{type => <<"type">>, data => <<"data">>}
    },
    Type = {struct, struct, {fistful_fistful_base_thrift, 'ResourceGenericData'}},
    Binary = ff_proto_utils:serialize(Type, marshal(generic_resource, GenericResource)),
    Decoded = ff_proto_utils:deserialize(Type, Binary),
    ?assertEqual(
        Decoded,
        #'fistful_base_ResourceGenericData'{
            provider = #'fistful_base_PaymentServiceRef'{id = <<"foo">>},
            data = #'fistful_base_Content'{type = <<"type">>, data = <<"data">>}
        }
    ),
    ?assertEqual(GenericResource, unmarshal(generic_resource, Decoded)).

-spec fees_codec_test() -> _.
fees_codec_test() ->
    Expected = #{
        fees => #{
            operation_amount => {100, <<"RUB">>},
            surplus => {200, <<"RUB">>}
        }
    },
    Type = {struct, struct, {fistful_fistful_base_thrift, 'Fees'}},
    Binary = ff_proto_utils:serialize(Type, marshal(fees, Expected)),
    Decoded = ff_proto_utils:deserialize(Type, Binary),
    ?assertEqual(Expected, unmarshal(fees, Decoded)).

-endif.
