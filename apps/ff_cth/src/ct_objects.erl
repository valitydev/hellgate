-module(ct_objects).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_source_thrift.hrl").
-include_lib("fistful_proto/include/fistful_deposit_thrift.hrl").
-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([build_default_ctx/0]).
-export([prepare_standard_environment_with/2]).
-export([prepare_standard_environment/1]).
-export([create_wallet/4]).
-export([create_party/0]).
-export([await_wallet_balance/2]).
-export([get_wallet_balance/1]).
-export([get_wallet/1]).

-export([await_final_withdrawal_status/1]).
-export([create_destination/2]).
-export([create_destination_/2]).
-export([create_deposit/0]).
-export([create_deposit/4]).
-export([create_source/2]).
-export([create_source/3]).

-type standard_environment_ctx() :: #{
    body => _Body,
    token => _Token,
    currency := _Currency,
    terms_ref := _TermsRef,
    payment_inst_ref := _PaymentInstRef
}.

-type standard_environment() :: #{
    body := _Body,
    party_id := _PartyID,
    wallet_id := _WalletID,
    source_id := _SourceID,
    deposit_id := _DepositID,
    deposit_context := _DepositContext,
    destination_id := _DestinationID,
    withdrawal_id := _WithdrawalID,
    withdrawal_context := _WithdrawalContext
}.

%%
-spec build_default_ctx() -> standard_environment_ctx().
build_default_ctx() ->
    #{
        body => make_cash({100, <<"RUB">>}),
        currency => <<"RUB">>,
        terms_ref => #domain_TermSetHierarchyRef{id = 1},
        payment_inst_ref => #domain_PaymentInstitutionRef{id = 1}
    }.

-spec prepare_standard_environment_with(standard_environment_ctx(), _) -> standard_environment().
prepare_standard_environment_with(Ctx, Fun) ->
    Result = prepare_standard_environment(Ctx),
    Fun(Result).

-spec prepare_standard_environment(standard_environment_ctx()) -> standard_environment().
prepare_standard_environment(
    #{
        currency := Currency,
        terms_ref := TermsRef,
        payment_inst_ref := PaymentInstRef
    } = Ctx
) ->
    PartyID = create_party(),
    WalletID = create_wallet(PartyID, Currency, TermsRef, PaymentInstRef),
    ok = await_wallet_balance({0, Currency}, WalletID),
    SourceID = create_source(PartyID, Currency),
    Body1 =
        case maps:get(body, Ctx) of
            undefined ->
                make_cash({100, <<"RUB">>});
            Body0 ->
                Body0
        end,
    {Amount0, BodyCurrency} = remake_cash(Body1),
    DepositBody = make_cash({2 * Amount0, BodyCurrency}),
    {DepositID, DepositContext} = create_deposit(PartyID, WalletID, SourceID, DepositBody),
    ok = await_wallet_balance(remake_cash(DepositBody), WalletID),
    DestinationID = create_destination(PartyID, maps:get(token, Ctx, undefined)),
    {WithdrawalID, WithdrawalContext} = create_withdrawal(Body1, PartyID, WalletID, DestinationID),
    #{
        body => Body1,
        party_id => PartyID,
        wallet_id => WalletID,
        source_id => SourceID,
        deposit_id => DepositID,
        deposit_context => DepositContext,
        destination_id => DestinationID,
        withdrawal_id => WithdrawalID,
        withdrawal_context => WithdrawalContext
    }.

%%----------------------------------------------------------------------

-spec create_wallet(_PartyID, _Currency, _TermsRef, _PaymentInstRef) -> _WalletID.
create_wallet(PartyID, Currency, TermsRef, PaymentInstRef) ->
    ID = genlib:unique(),
    _ = ct_domain:create_wallet(ID, PartyID, Currency, TermsRef, PaymentInstRef),
    ID.

-spec await_wallet_balance({_Amount, _Currency}, _ID) -> _.
await_wallet_balance({Amount, Currency}, ID) ->
    Balance = {Amount, {{inclusive, Amount}, {inclusive, Amount}}, Currency},
    Balance = ct_helper:await(
        Balance,
        fun() -> get_wallet_balance(ID) end,
        genlib_retry:linear(3, 500)
    ),
    ok.

-spec get_wallet_balance(_ID) -> {_Amount, _Range, _Currency}.
get_wallet_balance(ID) ->
    WalletConfig = ct_domain_config:get({wallet_config, #domain_WalletConfigRef{id = ID}}),
    {SettlementID, Currency} = ff_party:get_wallet_account(WalletConfig),
    {ok, {Amounts, Currency}} = ff_accounting:balance(SettlementID, Currency),
    {ff_indef:current(Amounts), ff_indef:to_range(Amounts), Currency}.

-spec get_wallet(_ID) -> _WalletConfig.
get_wallet(ID) ->
    ct_domain_config:get({wallet_config, #domain_WalletConfigRef{id = ID}}).

%%----------------------------------------------------------------------

-spec create_withdrawal(_Body, _PartyID, _WalletID, _DestinationID) -> _WithdrawalID.
create_withdrawal(Body, PartyID, WalletID, DestinationID) ->
    WithdrawalID = genlib:unique(),
    ExternalID = genlib:unique(),
    Ctx0 = #{<<"NS">> => #{genlib:unique() => genlib:unique()}},
    Ctx1 = ff_entity_context_codec:marshal(Ctx0),
    Metadata = ff_entity_context_codec:marshal(#{<<"metadata">> => #{<<"some key">> => <<"some data">>}}),
    Params = #wthd_WithdrawalParams{
        id = WithdrawalID,
        party_id = PartyID,
        wallet_id = WalletID,
        destination_id = DestinationID,
        body = Body,
        metadata = Metadata,
        external_id = ExternalID
    },
    {ok, _WithdrawalState} = call_withdrawal('Create', {Params, Ctx1}),
    succeeded = await_final_withdrawal_status(WithdrawalID),
    {WithdrawalID, Ctx0}.

-spec await_final_withdrawal_status(_WithdrawalID) -> _.
await_final_withdrawal_status(WithdrawalID) ->
    ct_helper:await(
        succeeded,
        fun() -> get_withdrawal_status(WithdrawalID) end,
        genlib_retry:linear(10, 1000)
    ).

get_withdrawal_status(WithdrawalID) ->
    ff_withdrawal:status(get_withdrawal(WithdrawalID)).

get_withdrawal(WithdrawalID) ->
    {ok, Machine} = ff_withdrawal_machine:get(WithdrawalID),
    ff_withdrawal_machine:withdrawal(Machine).

-spec create_destination(_PartyID, _Token) -> _DestinationID.
create_destination(PartyID, Token) ->
    StoreSource = ct_cardstore:bank_card(<<"4150399999000900">>, {12, 2025}),
    NewStoreResource =
        case Token of
            undefined ->
                StoreSource;
            Token ->
                StoreSource#{token => Token}
        end,
    Resource =
        {bank_card, #'fistful_base_ResourceBankCard'{
            bank_card = #'fistful_base_BankCard'{
                token = maps:get(token, NewStoreResource),
                bin = maps:get(bin, NewStoreResource, undefined),
                masked_pan = maps:get(masked_pan, NewStoreResource, undefined),
                exp_date = #'fistful_base_BankCardExpDate'{
                    month = 12,
                    year = 2025
                },
                cardholder_name = maps:get(cardholder_name, NewStoreResource, undefined)
            }
        }},
    Currency =
        case Token of
            <<"USD_CURRENCY">> ->
                <<"USD">>;
            _ ->
                <<"RUB">>
        end,
    create_destination_(PartyID, Resource, Currency).

-spec create_destination_(_PartyID, _Resource) -> _DestinationID.
create_destination_(PartyID, Resource) ->
    create_destination_(PartyID, Resource, <<"RUB">>).

-spec create_destination_(_PartyID, _Resource, _Currency) -> _DestinationID.
create_destination_(PartyID, Resource, Currency) ->
    AuthData =
        {sender_receiver, #destination_SenderReceiverAuthData{
            sender = <<"SenderToken">>,
            receiver = <<"ReceiverToken">>
        }},
    DstName = <<"loSHara card">>,
    ID = genlib:unique(),
    ExternalID = genlib:unique(),
    Ctx = ff_entity_context_codec:marshal(#{<<"NS">> => #{}}),
    Metadata = ff_entity_context_codec:marshal(#{<<"metadata">> => #{<<"some key">> => <<"some data">>}}),
    Params = #destination_DestinationParams{
        id = ID,
        party_id = PartyID,
        realm = live,
        name = DstName,
        currency = Currency,
        resource = Resource,
        external_id = ExternalID,
        metadata = Metadata,
        auth_data = AuthData
    },
    {ok, _Dst} = call_destination('Create', {Params, Ctx}),
    ID.

-spec create_deposit() -> {_DepositID, _Context}.
create_deposit() ->
    Body = make_cash({100, <<"RUB">>}),
    #{
        party_id := PartyID,
        wallet_id := WalletID,
        source_id := SourceID
    } = prepare_standard_environment(build_default_ctx()),
    create_deposit(PartyID, WalletID, SourceID, Body).

-spec create_deposit(_PartyID, _WalletID, _SourceID, _Body) -> {_DepositID, _Context}.
create_deposit(PartyID, WalletID, SourceID, Body0) ->
    DepositID = genlib:unique(),
    ExternalID = genlib:unique(),
    Context = #{<<"NS">> => #{genlib:unique() => genlib:unique()}},
    Metadata = ff_entity_context_codec:marshal(#{<<"metadata">> => #{<<"some key">> => <<"some data">>}}),
    Description = <<"testDesc">>,
    Body1 =
        case Body0 of
            #'fistful_base_Cash'{} ->
                Body0;
            _ ->
                make_cash(Body0)
        end,
    Params = #deposit_DepositParams{
        id = DepositID,
        party_id = PartyID,
        body = Body1,
        source_id = SourceID,
        wallet_id = WalletID,
        metadata = Metadata,
        external_id = ExternalID,
        description = Description
    },
    {ok, _DepositState} = call_deposit('Create', {Params, ff_entity_context_codec:marshal(Context)}),
    succeeded = await_final_deposit_status(DepositID),
    {DepositID, Context}.

await_final_deposit_status(DepositID) ->
    ct_helper:await(
        succeeded,
        fun() -> get_deposit_status(DepositID) end,
        genlib_retry:linear(10, 1000)
    ).

get_deposit_status(DepositID) ->
    ff_deposit:status(get_deposit(DepositID)).

get_deposit(DepositID) ->
    {ok, Machine} = ff_deposit_machine:get(DepositID),
    ff_deposit_machine:deposit(Machine).

-spec create_source(_PartyID, _Currency) -> _SourceID.
create_source(PartyID, Currency) ->
    create_source(PartyID, Currency, live).

-spec create_source(_PartyID, _Currency, _Realm) -> _SourceID.
create_source(PartyID, Currency, Realm) ->
    Name = <<"name">>,
    ID = genlib:unique(),
    ExternalID = genlib:unique(),
    Ctx = ff_entity_context_codec:marshal(#{<<"NS">> => #{}}),
    Metadata = ff_entity_context_codec:marshal(#{<<"metadata">> => #{<<"some key">> => <<"some data">>}}),
    Resource = {internal, #source_Internal{details = <<"details">>}},
    Params = #source_SourceParams{
        id = ID,
        realm = Realm,
        party_id = PartyID,
        name = Name,
        currency = #'fistful_base_CurrencyRef'{symbolic_code = Currency},
        resource = Resource,
        external_id = ExternalID,
        metadata = Metadata
    },
    {ok, _Src} = call_source('Create', {Params, Ctx}),
    ID.

-spec create_party() -> _PartyID.
create_party() ->
    ID = genlib:bsuuid(),
    _ = ct_domain:create_party(ID),
    ID.

make_cash({Amount, Currency}) ->
    #'fistful_base_Cash'{
        amount = Amount,
        currency = #'fistful_base_CurrencyRef'{symbolic_code = Currency}
    }.

remake_cash(#'fistful_base_Cash'{
    amount = Amount,
    currency = #'fistful_base_CurrencyRef'{symbolic_code = Currency}
}) ->
    {Amount, Currency}.

%%----------------------------------------------------------------------

call_withdrawal(Fun, Args) ->
    ServiceName = withdrawal_management,
    Service = ff_services:get_service(ServiceName),
    Request = {Service, Fun, Args},
    Client = ff_woody_client:new(#{
        url => "http://localhost:8022" ++ ff_services:get_service_path(ServiceName)
    }),
    ff_woody_client:call(Client, Request).

call_destination(Fun, Args) ->
    Service = {fistful_destination_thrift, 'Management'},
    Request = {Service, Fun, Args},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:8022/v1/destination">>,
        event_handler => ff_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).

call_deposit(Fun, Args) ->
    ServiceName = deposit_management,
    Service = ff_services:get_service(ServiceName),
    Request = {Service, Fun, Args},
    Client = ff_woody_client:new(#{
        url => "http://localhost:8022" ++ ff_services:get_service_path(ServiceName)
    }),
    ff_woody_client:call(Client, Request).

call_source(Fun, Args) ->
    Service = {fistful_source_thrift, 'Management'},
    Request = {Service, Fun, Args},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:8022/v1/source">>,
        event_handler => ff_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).
