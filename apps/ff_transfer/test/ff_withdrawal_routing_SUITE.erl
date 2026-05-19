-module(ff_withdrawal_routing_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%% Common test API

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

%% Tests

-export([allow_route_test/1]).
-export([not_allow_route_test/1]).
-export([not_reduced_allow_route_test/1]).
-export([not_global_allow_route_test/1]).
-export([adapter_unreachable_route_test/1]).
-export([adapter_unreachable_route_retryable_test/1]).
-export([adapter_unreachable_quote_test/1]).
-export([attempt_limit_test/1]).
-export([termial_priority_test/1]).

%% Internal types

-type config() :: ct_helper:config().
-type test_case_name() :: ct_helper:test_case_name().
-type group_name() :: ct_helper:group_name().
-type test_return() :: _ | no_return().

%% Macro helpers

-define(FINAL_BALANCE(Cash), {
    element(1, Cash),
    {
        {inclusive, element(1, Cash)},
        {inclusive, element(1, Cash)}
    },
    element(2, Cash)
}).

-define(FINAL_BALANCE(Amount, Currency), ?FINAL_BALANCE({Amount, Currency})).

%% Common test API implementation

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        {group, default}
    ].

-spec groups() -> [{group_name(), [test_case_name()]}].
groups() ->
    [
        {default, [
            allow_route_test,
            not_allow_route_test,
            not_reduced_allow_route_test,
            not_global_allow_route_test,
            adapter_unreachable_route_test,
            adapter_unreachable_route_retryable_test,
            adapter_unreachable_quote_test,
            attempt_limit_test,
            termial_priority_test
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

-spec allow_route_test(config()) -> test_return().
allow_route_test(C) ->
    Currency = <<"RUB">>,
    Cash = {910000, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)).

-spec not_allow_route_test(config()) -> test_return().
not_allow_route_test(C) ->
    Currency = <<"RUB">>,
    Cash = {920000, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch(
        {failed, #{code := <<"no_route_found">>}},
        await_final_withdrawal_status(WithdrawalID)
    ).

-spec not_reduced_allow_route_test(config()) -> test_return().
not_reduced_allow_route_test(C) ->
    Currency = <<"RUB">>,
    Cash = {930000, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch(
        {failed, #{code := <<"no_route_found">>}},
        await_final_withdrawal_status(WithdrawalID)
    ).

-spec not_global_allow_route_test(config()) -> test_return().
not_global_allow_route_test(C) ->
    Currency = <<"RUB">>,
    Cash = {940000, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch(
        {failed, #{code := <<"no_route_found">>}},
        await_final_withdrawal_status(WithdrawalID)
    ).

-spec adapter_unreachable_route_test(config()) -> test_return().
adapter_unreachable_route_test(C) ->
    Currency = <<"RUB">>,
    Cash = {100500, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch(
        {failed, #{code := <<"authorization_error">>}},
        await_final_withdrawal_status(WithdrawalID)
    ).

-spec adapter_unreachable_route_retryable_test(config()) -> test_return().
adapter_unreachable_route_retryable_test(C) ->
    Currency = <<"RUB">>,
    Cash = {100500, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    _ = set_retryable_errors(PartyID, [<<"authorization_error">>]),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)),
    ?assertEqual(?FINAL_BALANCE(0, Currency), ct_objects:get_wallet_balance(WalletID)),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(WalletID, ff_withdrawal:wallet_id(Withdrawal)),
    ?assertEqual(DestinationID, ff_withdrawal:destination_id(Withdrawal)),
    ?assertEqual(Cash, ff_withdrawal:body(Withdrawal)),
    ?assertEqual(WithdrawalID, ff_withdrawal:external_id(Withdrawal)),
    _ = set_retryable_errors(PartyID, []).

-spec adapter_unreachable_quote_test(config()) -> test_return().
adapter_unreachable_quote_test(C) ->
    Currency = <<"RUB">>,
    Cash = {100500, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID,
        quote => #{
            cash_from => Cash,
            cash_to => {2120, <<"USD">>},
            created_at => <<"2020-03-22T06:12:27Z">>,
            expires_on => <<"2020-03-22T06:12:27Z">>,
            route => ff_withdrawal_routing:make_route(4, 401),
            quote_data => #{<<"test">> => <<"test">>},
            operation_timestamp => ff_time:now()
        }
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch(
        {failed, #{code := <<"authorization_error">>}},
        await_final_withdrawal_status(WithdrawalID)
    ).

-spec attempt_limit_test(config()) -> test_return().
attempt_limit_test(C) ->
    Currency = <<"RUB">>,
    Cash = {500100, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch(
        {failed, #{code := <<"authorization_error">>}},
        await_final_withdrawal_status(WithdrawalID)
    ).

-spec termial_priority_test(config()) -> test_return().
termial_priority_test(C) ->
    Currency = <<"RUB">>,
    Cash = {500500, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    _ = set_retryable_errors(PartyID, [<<"authorization_error">>]),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(
        {failed, #{code => <<"not_expected_error">>}},
        await_final_withdrawal_status(WithdrawalID)
    ),
    _ = set_retryable_errors(PartyID, []).

%% Utils
set_retryable_errors(PartyID, ErrorList) ->
    application:set_env(ff_transfer, withdrawal, #{
        party_transient_errors => #{
            PartyID => ErrorList
        }
    }).

get_withdrawal(WithdrawalID) ->
    {ok, Machine} = ff_withdrawal_machine:get(WithdrawalID),
    ff_withdrawal_machine:withdrawal(Machine).

get_withdrawal_status(WithdrawalID) ->
    ff_withdrawal:status(get_withdrawal(WithdrawalID)).

await_final_withdrawal_status(WithdrawalID) ->
    finished = ct_helper:await(
        finished,
        fun() ->
            {ok, Machine} = ff_withdrawal_machine:get(WithdrawalID),
            Withdrawal = ff_withdrawal_machine:withdrawal(Machine),
            case ff_withdrawal:is_finished(Withdrawal) of
                false ->
                    {not_finished, Withdrawal};
                true ->
                    finished
            end
        end,
        genlib_retry:linear(10, 1000)
    ),
    get_withdrawal_status(WithdrawalID).

prepare_standard_environment({_Amount, Currency} = WithdrawalCash, C) ->
    PartyID = create_party(C),
    TermsRef = #domain_TermSetHierarchyRef{id = 1},
    PaymentInstRef = #domain_PaymentInstitutionRef{id = 1},
    WalletID = ct_objects:create_wallet(PartyID, Currency, TermsRef, PaymentInstRef),
    ok = ct_objects:await_wallet_balance({0, Currency}, WalletID),
    DestinationID = ct_objects:create_destination(PartyID, undefined),
    ok = set_wallet_balance(WithdrawalCash, PartyID, WalletID),
    #{
        party_id => PartyID,
        wallet_id => WalletID,
        destination_id => DestinationID
    }.

create_party(_C) ->
    ID = genlib:bsuuid(),
    _ = ct_domain:create_party(ID),
    ID.

set_wallet_balance({Amount, Currency}, PartyID, WalletID) ->
    SourceID = ct_objects:create_source(PartyID, Currency),
    {_DepositID, _} = ct_objects:create_deposit(PartyID, WalletID, SourceID, {Amount, Currency}),
    ok = ct_objects:await_wallet_balance({Amount, Currency}, WalletID),
    ok.
