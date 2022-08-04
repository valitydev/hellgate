-module(ff_destination_handler_SUITE).

-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([create_bank_card_destination_ok/1]).
-export([create_crypto_wallet_destination_ok/1]).
-export([create_ripple_wallet_destination_ok/1]).
-export([create_digital_wallet_destination_ok/1]).
-export([create_generic_destination_ok/1]).
-export([create_destination_forbidden_withdrawal_method_fail/1]).

-type config() :: ct_helper:config().
-type test_case_name() :: ct_helper:test_case_name().
-type group_name() :: ct_helper:group_name().
-type test_return() :: _ | no_return().

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [{group, default}].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {default, [parallel], [
            create_bank_card_destination_ok,
            create_crypto_wallet_destination_ok,
            create_ripple_wallet_destination_ok,
            create_digital_wallet_destination_ok,
            create_generic_destination_ok,
            create_destination_forbidden_withdrawal_method_fail
        ]}
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    ct_helper:makeup_cfg(
        [
            ct_helper:test_case_name(init),
            ct_payment_system:setup()
        ],
        C
    ).

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    ok = ct_payment_system:shutdown(C).

%%

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_, _) ->
    ok.

%%

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    C1 = ct_helper:makeup_cfg([ct_helper:test_case_name(Name), ct_helper:woody_ctx()], C),
    ok = ct_helper:set_context(C1),
    C1.

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, _C) ->
    ok = ct_helper:unset_context().

-spec create_bank_card_destination_ok(config()) -> test_return().
create_bank_card_destination_ok(C) ->
    Resource =
        {bank_card, #'fistful_base_ResourceBankCard'{
            bank_card = #'fistful_base_BankCard'{
                token = <<"TOKEN shmOKEN">>
            }
        }},
    create_destination_ok(Resource, C).

-spec create_crypto_wallet_destination_ok(config()) -> test_return().
create_crypto_wallet_destination_ok(C) ->
    Resource =
        {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{
            crypto_wallet = #'fistful_base_CryptoWallet'{
                id = <<"f195298af836f41d072cb390ee62bee8">>,
                currency = #'fistful_base_CryptoCurrencyRef'{id = <<"bitcoin_cash">>}
            }
        }},
    create_destination_ok(Resource, C).

-spec create_ripple_wallet_destination_ok(config()) -> test_return().
create_ripple_wallet_destination_ok(C) ->
    Resource =
        {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{
            crypto_wallet = #'fistful_base_CryptoWallet'{
                id = <<"ab843336bf7738dc697522fbb90508de">>,
                currency = #'fistful_base_CryptoCurrencyRef'{id = <<"ripple">>}
            }
        }},
    create_destination_ok(Resource, C).

-spec create_digital_wallet_destination_ok(config()) -> test_return().
create_digital_wallet_destination_ok(C) ->
    Resource =
        {digital_wallet, #'fistful_base_ResourceDigitalWallet'{
            digital_wallet = #'fistful_base_DigitalWallet'{
                id = <<"f195298af836f41d072cb390ee62bee8">>,
                token = <<"a30e277c07400c9940628828949efd48">>,
                payment_service = #'fistful_base_PaymentServiceRef'{id = <<"webmoney">>}
            }
        }},
    create_destination_ok(Resource, C).

-spec create_generic_destination_ok(config()) -> test_return().
create_generic_destination_ok(C) ->
    Resource =
        {generic, #'fistful_base_ResourceGeneric'{
            generic = #'fistful_base_ResourceGenericData'{
                data = #'fistful_base_Content'{type = <<"application/json">>, data = <<"{}">>},
                provider = #'fistful_base_PaymentServiceRef'{id = <<"IND">>}
            }
        }},
    create_destination_ok(Resource, C).

-spec create_destination_forbidden_withdrawal_method_fail(config()) -> test_return().
create_destination_forbidden_withdrawal_method_fail(C) ->
    Resource =
        {generic, #'fistful_base_ResourceGeneric'{
            generic = #'fistful_base_ResourceGenericData'{
                data = #'fistful_base_Content'{type = <<"application/json">>, data = <<"{}">>},
                provider = #'fistful_base_PaymentServiceRef'{id = <<"qiwi">>}
            }
        }},
    Party = create_party(C),
    Currency = <<"RUB">>,
    DstName = <<"loSHara card">>,
    ID = genlib:unique(),
    ExternalId = genlib:unique(),
    IdentityID = create_identity(Party, C),
    Ctx = ff_entity_context_codec:marshal(#{<<"NS">> => #{}}),
    Metadata = ff_entity_context_codec:marshal(#{<<"metadata">> => #{<<"some key">> => <<"some data">>}}),
    Params = #destination_DestinationParams{
        id = ID,
        identity = IdentityID,
        name = DstName,
        currency = Currency,
        resource = Resource,
        external_id = ExternalId,
        metadata = Metadata
    },
    {exception, #fistful_ForbiddenWithdrawalMethod{}} = call_service('Create', {Params, Ctx}).

%%----------------------------------------------------------------------
%%  Internal functions
%%----------------------------------------------------------------------

create_destination_ok(Resource, C) ->
    Party = create_party(C),
    Currency = <<"RUB">>,
    DstName = <<"loSHara card">>,
    ID = genlib:unique(),
    ExternalId = genlib:unique(),
    IdentityID = create_identity(Party, C),
    Ctx = ff_entity_context_codec:marshal(#{<<"NS">> => #{}}),
    Metadata = ff_entity_context_codec:marshal(#{<<"metadata">> => #{<<"some key">> => <<"some data">>}}),
    Params = #destination_DestinationParams{
        id = ID,
        identity = IdentityID,
        name = DstName,
        currency = Currency,
        resource = Resource,
        external_id = ExternalId,
        metadata = Metadata
    },
    {ok, Dst} = call_service('Create', {Params, Ctx}),
    DstName = Dst#destination_DestinationState.name,
    ID = Dst#destination_DestinationState.id,
    Resource = Dst#destination_DestinationState.resource,
    ExternalId = Dst#destination_DestinationState.external_id,
    Metadata = Dst#destination_DestinationState.metadata,
    Ctx = Dst#destination_DestinationState.context,

    Account = Dst#destination_DestinationState.account,
    IdentityID = Account#account_Account.identity,
    #'fistful_base_CurrencyRef'{symbolic_code = Currency} = Account#account_Account.currency,

    {authorized, #destination_Authorized{}} = ct_helper:await(
        {authorized, #destination_Authorized{}},
        fun() ->
            {ok, #destination_DestinationState{status = Status}} =
                call_service('Get', {ID, #'fistful_base_EventRange'{}}),
            Status
        end,
        genlib_retry:linear(15, 1000)
    ),

    {ok, #destination_DestinationState{}} = call_service('Get', {ID, #'fistful_base_EventRange'{}}).

call_service(Fun, Args) ->
    Service = {fistful_destination_thrift, 'Management'},
    Request = {Service, Fun, Args},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:8022/v1/destination">>,
        event_handler => scoper_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).

create_party(_C) ->
    ID = genlib:bsuuid(),
    _ = ff_party:create(ID),
    ID.

create_identity(Party, C) ->
    create_identity(Party, <<"good-one">>, C).

create_identity(Party, ProviderID, C) ->
    create_identity(Party, <<"Identity Name">>, ProviderID, C).

create_identity(Party, Name, ProviderID, _C) ->
    ID = genlib:unique(),
    ok = ff_identity_machine:create(
        #{id => ID, name => Name, party => Party, provider => ProviderID},
        #{<<"com.rbkmoney.wapi">> => #{<<"name">> => Name}}
    ),
    ID.
