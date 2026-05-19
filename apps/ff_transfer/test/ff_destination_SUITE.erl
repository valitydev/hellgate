-module(ff_destination_SUITE).

-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("stdlib/include/assert.hrl").

% Common test API
-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

% Tests
-export([create_destination_ok_test/1]).
-export([create_destination_party_notfound_fail_test/1]).
-export([create_destination_currency_notfound_fail_test/1]).
-export([get_destination_ok_test/1]).
-export([get_destination_notfound_fail_test/1]).

-type config() :: ct_helper:config().
-type test_case_name() :: ct_helper:test_case_name().
-type group_name() :: ct_helper:group_name().
-type test_return() :: _ | no_return().

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        {group, default}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {default, [], [
            create_destination_ok_test,
            create_destination_party_notfound_fail_test,
            create_destination_currency_notfound_fail_test,
            get_destination_ok_test,
            get_destination_notfound_fail_test
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

%% Default group test cases

-spec create_destination_ok_test(config()) -> test_return().
create_destination_ok_test(_C) ->
    PartyID = ct_objects:create_party(),
    _DestinationID = ct_objects:create_destination(PartyID, undefined),
    ok.

-spec create_destination_party_notfound_fail_test(config()) -> test_return().
create_destination_party_notfound_fail_test(_C) ->
    ResourceBankCard = ct_cardstore:bank_card(<<"4150399999000900">>, {12, 2025}),
    Resource = {bank_card, #{bank_card => ResourceBankCard}},
    AuthData = #{sender => <<"SenderToken">>, receiver => <<"ReceiverToken">>},
    Params = #{
        id => genlib:unique(),
        party_id => <<"BadPartyID">>,
        realm => live,
        name => <<"XDestination">>,
        currency => <<"RUB">>,
        resource => Resource,
        auth_data => AuthData
    },
    CreateResult = ff_destination_machine:create(Params, ff_entity_context:new()),
    ?assertEqual({error, {party, notfound}}, CreateResult).

-spec create_destination_currency_notfound_fail_test(config()) -> test_return().
create_destination_currency_notfound_fail_test(_C) ->
    PartyID = ct_objects:create_party(),
    ResourceBankCard = ct_cardstore:bank_card(<<"4150399999000900">>, {12, 2025}),
    Resource = {bank_card, #{bank_card => ResourceBankCard}},
    AuthData = #{sender => <<"SenderToken">>, receiver => <<"ReceiverToken">>},
    Params = #{
        id => genlib:unique(),
        party_id => PartyID,
        realm => live,
        name => <<"XDestination">>,
        currency => <<"BadUnknownCurrency">>,
        resource => Resource,
        auth_data => AuthData
    },
    CreateResult = ff_destination_machine:create(Params, ff_entity_context:new()),
    ?assertEqual({error, {currency, notfound}}, CreateResult).

-spec get_destination_ok_test(config()) -> test_return().
get_destination_ok_test(_C) ->
    PartyID = ct_objects:create_party(),
    DestinationID = ct_objects:create_destination(PartyID, undefined),
    {ok, DestinationMachine} = ff_destination_machine:get(DestinationID),
    Destination = ff_destination_machine:destination(DestinationMachine),
    ?assertMatch(#{account := #{currency := <<"RUB">>}}, Destination).

-spec get_destination_notfound_fail_test(config()) -> test_return().
get_destination_notfound_fail_test(_C) ->
    ?assertEqual({error, notfound}, ff_destination_machine:get(<<"BadID">>)).
