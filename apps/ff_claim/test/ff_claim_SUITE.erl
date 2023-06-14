-module(ff_claim_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("damsel/include/dmsl_claimmgmt_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-include("ff_claim_management.hrl").

%% Common test API

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-define(TEST_IDENTITY_CREATION(IdentityID, Params), #claimmgmt_IdentityModificationUnit{
    id = IdentityID,
    modification = {creation, Params}
}).

-define(TEST_WALLET_CREATION(WalletID, Params), #claimmgmt_NewWalletModificationUnit{
    id = WalletID,
    modification = {creation, Params}
}).

-define(USER_INFO, #claimmgmt_UserInfo{
    id = <<"id">>,
    email = <<"email">>,
    username = <<"username">>,
    type = {internal_user, #claimmgmt_InternalUser{}}
}).

-define(CLAIM(PartyID, Claim), #claimmgmt_Claim{
    id = 1,
    party_id = PartyID,
    status = {pending, #claimmgmt_ClaimPending{}},
    revision = 1,
    created_at = <<"2026-03-22T06:12:27Z">>,
    changeset = [Claim]
}).

%% Tests

-export([accept_identity_creation/1]).
-export([accept_identity_creation_already_exists/1]).
-export([apply_identity_creation/1]).

-export([accept_wallet_creation/1]).
-export([accept_wallet_creation_already_exists/1]).
-export([apply_wallet_creation/1]).

%% Internal types

-type config() :: ct_helper:config().
-type test_case_name() :: ct_helper:test_case_name().
-type group_name() :: ct_helper:group_name().
-type test_return() :: _ | no_return().

%% API

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [{group, default}].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {default, [parallel], [
            accept_identity_creation,
            accept_identity_creation_already_exists,
            apply_identity_creation,
            accept_wallet_creation,
            accept_wallet_creation_already_exists,
            apply_wallet_creation
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

%% Tests

-spec accept_identity_creation(config()) -> test_return().
accept_identity_creation(_C) ->
    #{party_id := PartyID} = prepare_standard_environment(),
    IdentityID = genlib:bsuuid(),
    Claim = make_identity_creation_claim(PartyID, IdentityID, <<"good-one">>),
    {ok, ok} = call_service('Accept', {PartyID, ?CLAIM(PartyID, Claim)}),
    ok.

-spec accept_identity_creation_already_exists(config()) -> test_return().
accept_identity_creation_already_exists(_C) ->
    #{party_id := PartyID, identity_id := IdentityID} = prepare_standard_environment(),
    Claim = make_identity_creation_claim(PartyID, IdentityID, <<"good-one">>),
    ?assertMatch(
        {exception, #claimmgmt_InvalidChangeset{reason = ?cm_invalid_identity_already_exists(IdentityID)}},
        call_service('Accept', {PartyID, ?CLAIM(PartyID, Claim)})
    ).

-spec apply_identity_creation(config()) -> test_return().
apply_identity_creation(_C) ->
    #{party_id := PartyID} = prepare_standard_environment(),
    IdentityID = genlib:bsuuid(),
    Claim = make_identity_creation_claim(PartyID, IdentityID, <<"good-one">>),
    {ok, ok} = call_service('Commit', {PartyID, ?CLAIM(PartyID, Claim)}),
    _Identity = get_identity(IdentityID),
    ok.

-spec accept_wallet_creation(config()) -> test_return().
accept_wallet_creation(_C) ->
    #{
        party_id := PartyID,
        identity_id := IdentityID
    } = prepare_standard_environment(),
    WalletID = genlib:bsuuid(),
    Claim = make_wallet_creation_claim(WalletID, IdentityID, <<"RUB">>),
    {ok, ok} = call_service('Accept', {PartyID, ?CLAIM(PartyID, Claim)}),
    ok.

-spec accept_wallet_creation_already_exists(config()) -> test_return().
accept_wallet_creation_already_exists(_C) ->
    #{
        party_id := PartyID,
        identity_id := IdentityID,
        wallet_id := WalletID
    } = prepare_standard_environment(),
    Claim = make_wallet_creation_claim(WalletID, IdentityID, <<"RUB">>),
    ?assertMatch(
        {exception, #claimmgmt_InvalidChangeset{reason = ?cm_invalid_wallet_already_exists(WalletID)}},
        call_service('Accept', {PartyID, ?CLAIM(PartyID, Claim)})
    ).

-spec apply_wallet_creation(config()) -> test_return().
apply_wallet_creation(_C) ->
    #{
        party_id := PartyID,
        identity_id := IdentityID
    } = prepare_standard_environment(),
    WalletID = genlib:bsuuid(),
    Claim = make_wallet_creation_claim(WalletID, IdentityID, <<"RUB">>),
    {ok, ok} = call_service('Commit', {PartyID, ?CLAIM(PartyID, Claim)}),
    _Wallet = get_wallet(WalletID),
    ok.

%% Utils

call_service(Fun, Args) ->
    Service = {dmsl_claimmgmt_thrift, 'ClaimCommitter'},
    Request = {Service, Fun, Args},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:8022/v1/claim_committer">>,
        event_handler => ff_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).

prepare_standard_environment() ->
    PartyID = create_party(),
    IdentityID = create_identity(PartyID),
    WalletID = create_wallet(IdentityID, <<"My wallet">>, <<"RUB">>),
    #{
        wallet_id => WalletID,
        identity_id => IdentityID,
        party_id => PartyID
    }.

create_party() ->
    ID = genlib:bsuuid(),
    _ = ff_party:create(ID),
    ID.
create_identity(Party) ->
    Name = <<"Identity Name">>,
    ID = genlib:unique(),
    ok = ff_identity_machine:create(
        #{id => ID, name => Name, party => Party, provider => <<"good-one">>},
        #{<<"com.rbkmoney.wapi">> => #{<<"name">> => Name, <<"owner">> => Party}}
    ),
    ID.

get_identity(ID) ->
    {ok, Machine} = ff_identity_machine:get(ID),
    ff_identity_machine:identity(Machine).

create_wallet(IdentityID, Name, Currency) ->
    ID = genlib:unique(),
    ok = ff_wallet_machine:create(
        #{id => ID, identity => IdentityID, name => Name, currency => Currency},
        ff_entity_context:new()
    ),
    ID.

get_wallet(ID) ->
    {ok, Machine} = ff_wallet_machine:get(ID),
    ff_wallet_machine:wallet(Machine).

make_identity_creation_claim(PartyID, IdentityID, Provider) ->
    Params = #claimmgmt_IdentityParams{
        name = <<"SomeName">>,
        party_id = PartyID,
        provider = Provider
    },
    Mod = ?TEST_IDENTITY_CREATION(IdentityID, Params),
    ?cm_identity_modification(1, <<"2026-03-22T06:12:27Z">>, Mod, ?USER_INFO).

make_wallet_creation_claim(WalletID, IdentityID, CurrencyID) ->
    Params = #claimmgmt_NewWalletParams{
        name = <<"SomeWalletName">>,
        identity_id = IdentityID,
        currency = #domain_CurrencyRef{
            symbolic_code = CurrencyID
        }
    },
    Mod = ?TEST_WALLET_CREATION(WalletID, Params),
    ?cm_wallet_modification(1, <<"2026-03-22T06:12:27Z">>, Mod, ?USER_INFO).
