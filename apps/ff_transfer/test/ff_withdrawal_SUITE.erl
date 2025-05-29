-module(ff_withdrawal_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("ff_cth/include/ct_domain.hrl").
-include_lib("fistful_proto/include/fistful_wthd_session_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_status_thrift.hrl").
-include_lib("fistful_proto/include/fistful_repairer_thrift.hrl").

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
-export([session_fail_test/1]).
-export([session_repair_test/1]).
-export([quote_fail_test/1]).
-export([route_not_found_fail_test/1]).
-export([provider_operations_forbidden_fail_test/1]).
-export([misconfigured_terminal_fail_test/1]).
-export([limit_check_fail_test/1]).
-export([create_cashlimit_validation_error_test/1]).
-export([create_wallet_currency_validation_error_test/1]).
-export([create_realms_mismatch_error_test/1]).
-export([create_destination_currency_validation_error_test/1]).
-export([create_currency_validation_error_test/1]).
-export([create_destination_resource_no_bindata_ok_test/1]).
-export([create_destination_resource_no_bindata_fail_test/1]).
-export([create_destination_notfound_test/1]).
-export([create_wallet_notfound_test/1]).
-export([create_ok_test/1]).
-export([create_with_generic_ok_test/1]).
-export([quote_ok_test/1]).
-export([crypto_quote_ok_test/1]).
-export([quote_with_destination_ok_test/1]).
-export([preserve_revisions_test/1]).
-export([use_quote_revisions_test/1]).
-export([unknown_test/1]).
-export([provider_callback_test/1]).
-export([provider_terminal_terms_merging_test/1]).
-export([force_status_change_test/1]).

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

-define(assertRouteNotFound(Result, ReasonSubstring), begin
    ?assertMatch({failed, #{code := <<"no_route_found">>, reason := _Reason}}, Result),
    {failed, #{reason := FailureReason}} = Result,
    ?assert(
        nomatch =/= binary:match(FailureReason, ReasonSubstring),
        <<"Failure reason '", FailureReason/binary, "' for 'no_route_found' doesn't match '", ReasonSubstring/binary,
            "'">>
    )
end).

%% API

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        {group, default},
        {group, non_parallel}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {default, [], [
            session_fail_test,
            session_repair_test,
            quote_fail_test,
            route_not_found_fail_test,
            provider_operations_forbidden_fail_test,
            misconfigured_terminal_fail_test,
            limit_check_fail_test,
            create_cashlimit_validation_error_test,
            create_wallet_currency_validation_error_test,
            create_destination_currency_validation_error_test,
            create_currency_validation_error_test,
            create_realms_mismatch_error_test,
            create_destination_resource_no_bindata_ok_test,
            create_destination_resource_no_bindata_fail_test,
            create_destination_notfound_test,
            create_wallet_notfound_test,
            create_ok_test,
            create_with_generic_ok_test,
            quote_ok_test,
            crypto_quote_ok_test,
            quote_with_destination_ok_test,
            preserve_revisions_test,
            unknown_test,
            provider_callback_test,
            provider_terminal_terms_merging_test
        ]},
        {non_parallel, [], [
            use_quote_revisions_test
        ]},
        {withdrawal_repair, [], [
            force_status_change_test
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
init_per_group(withdrawal_repair, C) ->
    Termset = withdrawal_misconfig_termset_fixture(),
    TermsetHierarchy = ct_domain:term_set_hierarchy(?trms(1), [ct_domain:timed_term_set(Termset)]),
    _ = ct_domain_config:update(TermsetHierarchy),
    C;
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_, _) ->
    ok.

%%

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    C1 = ct_helper:makeup_cfg(
        [
            ct_helper:test_case_name(Name),
            ct_helper:woody_ctx()
        ],
        C
    ),
    ok = ct_helper:set_context(C1),
    C1.

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, _C) ->
    ok = ct_helper:unset_context().

%% Tests

-spec session_fail_test(config()) -> test_return().
session_fail_test(_C) ->
    Env = ct_objects:prepare_standard_environment(ct_objects:build_default_ctx()),
    Body = {100, <<"RUB">>},
    PartyID = maps:get(party_id, Env),
    WalletID = ct_objects:create_wallet(
        PartyID,
        <<"RUB">>,
        #domain_TermSetHierarchyRef{id = 1},
        #domain_PaymentInstitutionRef{id = 2}
    ),
    _ = ct_objects:create_deposit(PartyID, WalletID, maps:get(source_id, Env), Body),
    ok = ct_objects:await_wallet_balance(Body, WalletID),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        party_id => PartyID,
        destination_id => maps:get(destination_id, Env),
        wallet_id => WalletID,
        body => {100, <<"RUB">>},
        quote => #{
            cash_from => {4240, <<"RUB">>},
            cash_to => {2120, <<"USD">>},
            created_at => <<"2016-03-22T06:12:27Z">>,
            expires_on => <<"2016-03-22T06:12:27Z">>,
            route => ff_withdrawal_routing:make_route(3, 301),
            quote_data => #{<<"test">> => <<"error">>},
            operation_timestamp => ff_time:now()
        }
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"test_error">>}}, Result).

-spec quote_fail_test(config()) -> test_return().
quote_fail_test(_C) ->
    Env = ct_objects:prepare_standard_environment(ct_objects:build_default_ctx()),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        party_id => maps:get(party_id, Env),
        destination_id => maps:get(destination_id, Env),
        wallet_id => maps:get(wallet_id, Env),
        body => {100, <<"RUB">>},
        quote => #{
            cash_from => {4240, <<"RUB">>},
            cash_to => {2120, <<"USD">>},
            created_at => <<"2016-03-22T06:12:27Z">>,
            expires_on => <<"2016-03-22T06:12:27Z">>,
            route => ff_withdrawal_routing:make_route(10, 10),
            quote_data => #{<<"test">> => <<"test">>},
            operation_timestamp => ff_time:now()
        }
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"unknown">>}}, Result).

-spec route_not_found_fail_test(config()) -> test_return().
route_not_found_fail_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, <<"USD_COUNTRY">>, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"no_route_found">>}}, Result).

-spec provider_operations_forbidden_fail_test(config()) -> test_return().
provider_operations_forbidden_fail_test(C) ->
    Cash = {123123, <<"RUB">>},
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
        body => Cash
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"no_route_found">>}}, Result).

-spec misconfigured_terminal_fail_test(config()) -> test_return().
misconfigured_terminal_fail_test(C) ->
    Cash = {3500000, <<"RUB">>},
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
        body => Cash
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertRouteNotFound(Result, <<"{terms_violation,{not_allowed_currency,">>).

-spec limit_check_fail_test(config()) -> test_return().
limit_check_fail_test(C) ->
    Cash = {100, <<"RUB">>},
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
        body => {200, <<"RUB">>}
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch(
        {failed, #{
            code := <<"account_limit_exceeded">>,
            sub := #{
                code := <<"amount">>
            }
        }},
        Result
    ),
    ?assertEqual(?FINAL_BALANCE(Cash), get_wallet_balance(WalletID)).

-spec create_cashlimit_validation_error_test(config()) -> test_return().
create_cashlimit_validation_error_test(C) ->
    Cash = {100, <<"RUB">>},
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
        body => {20000000, <<"RUB">>}
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    CashRange = {{inclusive, {0, <<"RUB">>}}, {exclusive, {10000001, <<"RUB">>}}},
    Details = {terms_violation, {cash_range, {{20000000, <<"RUB">>}, CashRange}}},
    ?assertMatch({error, {terms, Details}}, Result).

-spec create_wallet_currency_validation_error_test(config()) -> test_return().
create_wallet_currency_validation_error_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WalletID = ct_objects:create_wallet(
        PartyID, <<"USD">>, #domain_TermSetHierarchyRef{id = 1}, #domain_PaymentInstitutionRef{id = 1}
    ),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        party_id => PartyID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => {100, <<"RUB">>}
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch({error, {inconsistent_currency, {<<"RUB">>, <<"USD">>, <<"RUB">>}}}, Result).

-spec create_destination_currency_validation_error_test(config()) -> test_return().
create_destination_currency_validation_error_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, <<"USD_CURRENCY">>, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => {100, <<"RUB">>}
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch({error, {inconsistent_currency, {<<"RUB">>, <<"RUB">>, <<"USD">>}}}, Result).

-spec create_currency_validation_error_test(config()) -> test_return().
create_currency_validation_error_test(C) ->
    Cash = {100, <<"RUB">>},
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
        body => {100, <<"EUR">>}
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Details = {
        #domain_CurrencyRef{symbolic_code = <<"EUR">>},
        [
            #domain_CurrencyRef{symbolic_code = <<"RUB">>},
            #domain_CurrencyRef{symbolic_code = <<"USD">>}
        ]
    },
    ?assertMatch({error, {terms, {terms_violation, {not_allowed_currency, Details}}}}, Result).

-spec create_realms_mismatch_error_test(config()) -> test_return().
create_realms_mismatch_error_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WalletID = ct_objects:create_wallet(
        PartyID, <<"RUB">>, #domain_TermSetHierarchyRef{id = 1}, #domain_PaymentInstitutionRef{id = 3}
    ),
    SourceID = ct_objects:create_source(PartyID, <<"RUB">>, test),
    _ = ct_objects:create_deposit(PartyID, WalletID, SourceID, Cash),
    ok = ct_objects:await_wallet_balance(Cash, WalletID),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        party_id => PartyID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch({error, {realms_mismatch, {test, live}}}, Result).

-spec create_destination_resource_no_bindata_fail_test(config()) -> test_return().
create_destination_resource_no_bindata_fail_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, <<"TEST_NOTFOUND">>, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash
    },
    ?assertError(
        {badmatch, {error, {invalid_terms, {not_reduced, _}}}},
        ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new())
    ).

-spec create_destination_resource_no_bindata_ok_test(config()) -> test_return().
create_destination_resource_no_bindata_ok_test(C) ->
    %% As per test terms this specific cash amount results in valid cashflow without bin data
    Cash = {424242, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, <<"TEST_NOTFOUND">>, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch(ok, Result).

-spec create_destination_notfound_test(config()) -> test_return().
create_destination_notfound_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        wallet_id := WalletID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => <<"unknown_destination">>,
        wallet_id => WalletID,
        party_id => PartyID,
        body => Cash
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch({error, {destination, notfound}}, Result).

-spec create_wallet_notfound_test(config()) -> test_return().
create_wallet_notfound_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => <<"unknown_wallet">>,
        party_id => PartyID,
        body => Cash
    },
    Result = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertMatch({error, {wallet, notfound}}, Result).

-spec create_ok_test(config()) -> test_return().
create_ok_test(C) ->
    Cash = {100, <<"RUB">>},
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
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)),
    ?assertEqual(?FINAL_BALANCE(0, <<"RUB">>), get_wallet_balance(WalletID)),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(WalletID, ff_withdrawal:wallet_id(Withdrawal)),
    ?assertEqual(DestinationID, ff_withdrawal:destination_id(Withdrawal)),
    ?assertEqual(Cash, ff_withdrawal:body(Withdrawal)),
    ?assertEqual(WithdrawalID, ff_withdrawal:external_id(Withdrawal)).

-spec create_with_generic_ok_test(config()) -> test_return().
create_with_generic_ok_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        wallet_id := WalletID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    DestinationID = create_generic_destination(<<"IND">>, PartyID, C),
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
    ?assertEqual(?FINAL_BALANCE(0, <<"RUB">>), get_wallet_balance(WalletID)),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(WalletID, ff_withdrawal:wallet_id(Withdrawal)),
    ?assertEqual(DestinationID, ff_withdrawal:destination_id(Withdrawal)),
    ?assertEqual(Cash, ff_withdrawal:body(Withdrawal)),
    ?assertEqual(WithdrawalID, ff_withdrawal:external_id(Withdrawal)).

-spec quote_ok_test(config()) -> test_return().
quote_ok_test(C) ->
    Cash = {100, <<"RUB">>},
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
        quote => #{
            cash_from => Cash,
            cash_to => {2120, <<"USD">>},
            created_at => <<"2016-03-22T06:12:27Z">>,
            expires_on => <<"2016-03-22T06:12:27Z">>,
            route => ff_withdrawal_routing:make_route(1, 1),
            quote_data => #{<<"test">> => <<"test">>},
            operation_timestamp => ff_time:now()
        }
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)).

-spec crypto_quote_ok_test(config()) -> test_return().
crypto_quote_ok_test(C) ->
    Currency = <<"RUB">>,
    Cash = {100, Currency},
    PartyID = ct_objects:create_party(),
    WalletID = ct_objects:create_wallet(
        PartyID, Currency, #domain_TermSetHierarchyRef{id = 1}, #domain_PaymentInstitutionRef{id = 1}
    ),
    ok = await_wallet_balance({0, Currency}, WalletID),
    DestinationID = create_crypto_destination(PartyID, C),
    Params = #{
        wallet_id => WalletID,
        party_id => PartyID,
        currency_from => <<"RUB">>,
        currency_to => <<"BTC">>,
        body => Cash,
        destination_id => DestinationID
    },
    {ok, _Quote} = ff_withdrawal:get_quote(Params).

-spec quote_with_destination_ok_test(config()) -> test_return().
quote_with_destination_ok_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    Params = #{
        wallet_id => WalletID,
        party_id => PartyID,
        currency_from => <<"RUB">>,
        currency_to => <<"USD">>,
        body => Cash,
        destination_id => DestinationID
    },
    {ok, #{quote_data := #{<<"destination">> := <<"bank_card">>}}} = ff_withdrawal:get_quote(Params).

-spec preserve_revisions_test(config()) -> test_return().
preserve_revisions_test(C) ->
    Cash = {100, <<"RUB">>},
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
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertNotEqual(undefined, ff_withdrawal:domain_revision(Withdrawal)),
    ?assertNotEqual(undefined, ff_withdrawal:created_at(Withdrawal)).

-spec use_quote_revisions_test(config()) -> test_return().
use_quote_revisions_test(C) ->
    Cash = {100, <<"RUB">>},
    #{
        party_id := PartyID,
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    Time = ff_time:now(),
    DomainRevision = ff_domain_config:head(),
    _ = ct_domain_config:bump_revision(),
    ?assertNotEqual(DomainRevision, ff_domain_config:head()),
    WithdrawalParams = #{
        id => WithdrawalID,
        party_id => PartyID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        quote => #{
            cash_from => Cash,
            cash_to => {2120, <<"USD">>},
            created_at => <<"2016-03-22T06:12:27Z">>,
            expires_on => <<"2016-03-22T06:12:27Z">>,
            domain_revision => DomainRevision,
            operation_timestamp => Time,
            route => ff_withdrawal_routing:make_route(1, 1),
            quote_data => #{<<"test">> => <<"test">>}
        }
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(DomainRevision, ff_withdrawal:domain_revision(Withdrawal)),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)).

-spec force_status_change_test(config()) -> test_return().
force_status_change_test(C) ->
    Cash = {100, <<"RUB">>},
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
    await_withdraval_transfer_created(WithdrawalID),
    ?assertMatch(pending, get_withdrawal_status(WithdrawalID)),
    {ok, ok} =
        call_withdrawal_repair(
            WithdrawalID,
            {add_events, #wthd_AddEventsRepair{
                events = [
                    {status_changed, #wthd_StatusChange{
                        status =
                            {failed, #wthd_status_Failed{
                                failure = #'fistful_base_Failure'{
                                    code = <<"Withdrawal failed by manual intervention">>
                                }
                            }}
                    }}
                ],
                action = #repairer_ComplexAction{
                    timer =
                        {set_timer, #repairer_SetTimerAction{
                            timer = {timeout, 10000}
                        }}
                }
            }}
        ),
    ?assertMatch(
        {failed, #{code := <<"Withdrawal failed by manual intervention">>}},
        get_withdrawal_status(WithdrawalID)
    ).

-spec unknown_test(config()) -> test_return().
unknown_test(_C) ->
    WithdrawalID = <<"unknown_withdrawal">>,
    Result = ff_withdrawal_machine:get(WithdrawalID),
    ?assertMatch({error, {unknown_withdrawal, WithdrawalID}}, Result).

-spec provider_callback_test(config()) -> test_return().
provider_callback_test(C) ->
    Currency = <<"RUB">>,
    Cash = {700700, Currency},
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
    BadCallbackTag = <<"bad">>,
    CallbackTag = <<"cb_", WithdrawalID/binary>>,
    CallbackPayload = <<"super_secret">>,
    Callback = #{
        tag => CallbackTag,
        payload => CallbackPayload
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(pending, await_session_processing_status(WithdrawalID, pending)),
    SessionID = get_session_id(WithdrawalID),
    ?assertEqual(<<"callback_processing">>, await_session_adapter_state(SessionID, <<"callback_processing">>)),
    ?assertMatch(#{id := <<"SleepyID">>, extra := #{}}, get_session_transaction_info(SessionID)),
    %% invalid tag
    ?assertEqual(
        {error, {unknown_session, {tag, BadCallbackTag}}},
        call_process_callback(Callback#{tag => BadCallbackTag})
    ),
    %% ok tag
    ?assertEqual({ok, #{payload => CallbackPayload}}, call_process_callback(Callback)),
    ?assertEqual(<<"callback_finished">>, await_session_adapter_state(SessionID, <<"callback_finished">>)),
    ?assertMatch(#{id := <<"SleepyID">>, extra := #{}}, get_session_transaction_info(SessionID)),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)),
    ?assertEqual({ok, #{payload => CallbackPayload}}, call_process_callback(Callback)),
    % Wait ff_ct_sleepy_provider timeout
    timer:sleep(5000),
    % Check that session is still alive
    ?assertEqual({ok, #{payload => CallbackPayload}}, call_process_callback(Callback)).

-spec session_repair_test(config()) -> test_return().
session_repair_test(C) ->
    Currency = <<"RUB">>,
    Cash = {700700, Currency},
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
        quote => #{
            cash_from => {700700, <<"RUB">>},
            cash_to => {700700, <<"RUB">>},
            created_at => <<"2016-03-22T06:12:27Z">>,
            expires_on => <<"2016-03-22T06:12:27Z">>,
            route => ff_withdrawal_routing:make_route(11, 1101),
            quote_data => #{<<"test">> => <<"fatal">>},
            operation_timestamp => ff_time:now()
        }
    },
    Callback = #{
        tag => <<"cb_", WithdrawalID/binary>>,
        payload => <<"super_secret">>
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(pending, await_session_processing_status(WithdrawalID, pending)),
    SessionID = get_session_id(WithdrawalID),
    ?assertEqual(<<"callback_processing">>, await_session_adapter_state(SessionID, <<"callback_processing">>)),
    ?assertError({failed, _, _}, call_process_callback(Callback)),
    timer:sleep(3000),
    ?assertEqual(pending, await_session_processing_status(WithdrawalID, pending)),
    ok = repair_withdrawal_session(WithdrawalID),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)).

-spec provider_terminal_terms_merging_test(config()) -> test_return().
provider_terminal_terms_merging_test(C) ->
    #{
        wallet_id := WalletID,
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment({601, <<"RUB">>}, C),
    ProduceWithdrawal = fun(Cash) ->
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
        Withdrawal = get_withdrawal(WithdrawalID),
        Route = ff_withdrawal:route(Withdrawal),
        #{postings := Postings} = ff_withdrawal:effective_final_cash_flow(Withdrawal),
        VolumeEntries = [Volume || #{volume := {Volume, <<"RUB">>}} <- Postings],
        {Route, VolumeEntries}
    end,
    {Route1, VolumeEntries1} = ProduceWithdrawal({300, <<"RUB">>}),
    {Route2, VolumeEntries2} = ProduceWithdrawal({301, <<"RUB">>}),
    ?assertMatch(#{provider_id := 17, terminal_id := 1701}, Route1),
    ?assertMatch(#{provider_id := 17, terminal_id := 1708}, Route2),
    ?assertEqual([300, 30, 30, 10], VolumeEntries1),
    ?assertEqual([301, 30, 30, 16], VolumeEntries2).

%% Utils

prepare_standard_environment(WithdrawalCash, C) ->
    prepare_standard_environment(WithdrawalCash, undefined, C).

prepare_standard_environment({_Amount, Currency} = WithdrawalCash, Token, _C) ->
    PartyID = ct_objects:create_party(),
    WalletID = ct_objects:create_wallet(
        PartyID, Currency, #domain_TermSetHierarchyRef{id = 1}, #domain_PaymentInstitutionRef{id = 1}
    ),
    ok = await_wallet_balance({0, Currency}, WalletID),
    DestinationID = ct_objects:create_destination(PartyID, Token),
    SourceID = ct_objects:create_source(PartyID, Currency),
    {_DepositID, _} = ct_objects:create_deposit(PartyID, WalletID, SourceID, WithdrawalCash),
    ok = await_wallet_balance(WithdrawalCash, WalletID),
    #{
        party_id => PartyID,
        wallet_id => WalletID,
        destination_id => DestinationID,
        source_id => SourceID
    }.

get_withdrawal(WithdrawalID) ->
    {ok, Machine} = ff_withdrawal_machine:get(WithdrawalID),
    ff_withdrawal_machine:withdrawal(Machine).

get_withdrawal_status(WithdrawalID) ->
    Withdrawal = get_withdrawal(WithdrawalID),
    ff_withdrawal:status(Withdrawal).

await_session_processing_status(WithdrawalID, Status) ->
    Poller = fun() -> get_session_processing_status(WithdrawalID) end,
    Retry = genlib_retry:linear(20, 1000),
    ct_helper:await(Status, Poller, Retry).

get_session_processing_status(WithdrawalID) ->
    Withdrawal = get_withdrawal(WithdrawalID),
    ff_withdrawal:get_current_session_status(Withdrawal).

get_session(SessionID) ->
    {ok, Machine} = ff_withdrawal_session_machine:get(SessionID),
    ff_withdrawal_session_machine:session(Machine).

await_session_adapter_state(SessionID, State) ->
    Poller = fun() -> get_session_adapter_state(SessionID) end,
    Retry = genlib_retry:linear(20, 1000),
    ct_helper:await(State, Poller, Retry).

get_session_adapter_state(SessionID) ->
    Session = get_session(SessionID),
    ff_withdrawal_session:adapter_state(Session).

get_session_id(WithdrawalID) ->
    Withdrawal = get_withdrawal(WithdrawalID),
    ff_withdrawal:session_id(Withdrawal).

await_withdraval_transfer_created(WithdrawalID) ->
    ct_helper:await(
        transfer_created,
        fun() ->
            {ok, Events} = ff_withdrawal_machine:events(WithdrawalID, {undefined, undefined}),
            case search_transfer_create_event(Events) of
                false ->
                    transfer_not_created;
                {value, _} ->
                    transfer_created
            end
        end,
        genlib_retry:linear(20, 1000)
    ).

search_transfer_create_event(Events) ->
    lists:search(
        fun(T) ->
            case T of
                {_N, {ev, _Timestamp, {p_transfer, {status_changed, created}}}} ->
                    true;
                _Other ->
                    false
            end
        end,
        Events
    ).

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
        genlib_retry:linear(20, 1000)
    ),
    get_withdrawal_status(WithdrawalID).

get_session_transaction_info(SessionID) ->
    Session = get_session(SessionID),
    ff_withdrawal_session:transaction_info(Session).

await_wallet_balance({Amount, Currency}, ID) ->
    ct_objects:await_wallet_balance({Amount, Currency}, ID).

get_wallet_balance(ID) ->
    ct_objects:get_wallet_balance(ID).

create_crypto_destination(PartyID, _C) ->
    ID = genlib:bsuuid(),
    Resource =
        {crypto_wallet, #{
            crypto_wallet => #{
                id => <<"a30e277c07400c9940628828949efd48">>,
                currency => #{id => <<"Litecoin">>}
            }
        }},
    Params = #{
        id => ID,
        party_id => PartyID,
        realm => live,
        name => <<"CryptoDestination">>,
        currency => <<"RUB">>,
        resource => Resource
    },
    ok = ff_destination_machine:create(Params, ff_entity_context:new()),
    ID.

create_generic_destination(Provider, IID, _C) ->
    ID = genlib:bsuuid(),
    Resource =
        {generic, #{
            generic => #{
                provider => #{id => Provider},
                data => #{type => <<"application/json">>, data => <<"{}">>}
            }
        }},
    Params = #{
        id => ID,
        party_id => IID,
        realm => live,
        name => <<"GenericDestination">>,
        currency => <<"RUB">>,
        resource => Resource
    },
    ok = ff_destination_machine:create(Params, ff_entity_context:new()),
    ID.

call_process_callback(Callback) ->
    ff_withdrawal_session_machine:process_callback(Callback).

repair_withdrawal_session(WithdrawalID) ->
    SessionID = get_session_id(WithdrawalID),
    {ok, ok} = call_session_repair(
        SessionID,
        {set_session_result, #wthd_session_SetResultRepair{
            result =
                {success, #wthd_session_SessionResultSuccess{
                    trx_info = #'fistful_base_TransactionInfo'{
                        id = SessionID,
                        extra = #{}
                    }
                }}
        }}
    ),
    ok.

call_session_repair(SessionID, Scenario) ->
    Service = {fistful_wthd_session_thrift, 'Repairer'},
    Request = {Service, 'Repair', {SessionID, Scenario}},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:8022/v1/repair/withdrawal/session">>,
        event_handler => ff_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).

call_withdrawal_repair(SessionID, Scenario) ->
    Service = {fistful_wthd_thrift, 'Repairer'},
    Request = {Service, 'Repair', {SessionID, Scenario}},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:8022/v1/repair/withdrawal">>,
        event_handler => ff_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).

withdrawal_misconfig_termset_fixture() ->
    #domain_TermSet{
        wallets = #domain_WalletServiceTerms{
            currencies = {value, ?ordset([?cur(<<"RUB">>)])},
            wallet_limit =
                {decisions, [
                    #domain_CashLimitDecision{
                        if_ = {condition, {bin_data, #domain_BinDataCondition{}}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"RUB">>)},
                                    {exclusive, ?cash(5000001, <<"RUB">>)}
                                )}
                    }
                ]},
            withdrawals = #domain_WithdrawalServiceTerms{
                currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                attempt_limit = {value, #domain_AttemptLimit{attempts = 3}},
                cash_limit =
                    {decisions, [
                        #domain_CashLimitDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {value,
                                    ?cashrng(
                                        {inclusive, ?cash(0, <<"RUB">>)},
                                        {exclusive, ?cash(10000001, <<"RUB">>)}
                                    )}
                        }
                    ]},
                cash_flow =
                    {decisions, [
                        #domain_CashFlowDecision{
                            if_ =
                                {all_of,
                                    ?ordset([
                                        {condition, {currency_is, ?cur(<<"RUB">>)}},
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = #domain_PaymentSystemRef{
                                                                id = <<"VISA">>
                                                            }
                                                        }}
                                                }}}}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        }
                    ]}
            }
        }
    }.
