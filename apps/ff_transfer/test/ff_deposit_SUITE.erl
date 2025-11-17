-module(ff_deposit_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

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

-export([limit_check_fail_test/1]).
-export([create_bad_amount_test/1]).
-export([create_negative_amount_test/1]).
-export([create_currency_validation_error_test/1]).
-export([create_source_notfound_test/1]).
-export([create_wallet_notfound_test/1]).
-export([create_party_mismatch_test/1]).
-export([preserve_revisions_test/1]).
-export([create_ok_test/1]).
-export([unknown_test/1]).

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
        {default, [], [
            limit_check_fail_test,
            create_bad_amount_test,
            create_negative_amount_test,
            create_currency_validation_error_test,
            create_source_notfound_test,
            create_wallet_notfound_test,
            create_party_mismatch_test,
            preserve_revisions_test,
            create_ok_test,
            unknown_test
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

-spec limit_check_fail_test(config()) -> test_return().
limit_check_fail_test(C) ->
    #{
        wallet_id := WalletID,
        source_id := SourceID,
        party_id := PartyID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositParams = #{
        id => DepositID,
        body => {20000000, <<"RUB">>},
        source_id => SourceID,
        wallet_id => WalletID,
        party_id => PartyID,
        external_id => genlib:unique()
    },
    ok = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    Result = await_final_deposit_status(DepositID),
    ?assertMatch(
        {failed, #{
            code := <<"account_limit_exceeded">>,
            sub := #{
                code := <<"amount">>
            }
        }},
        Result
    ).

-spec create_bad_amount_test(config()) -> test_return().
create_bad_amount_test(C) ->
    #{
        wallet_id := WalletID,
        source_id := SourceID,
        party_id := PartyID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositParams = #{
        id => DepositID,
        body => {0, <<"RUB">>},
        source_id => SourceID,
        wallet_id => WalletID,
        party_id => PartyID,
        external_id => genlib:unique()
    },
    Result = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    ?assertMatch({error, {bad_deposit_amount, {0, <<"RUB">>}}}, Result).

-spec create_negative_amount_test(config()) -> test_return().
create_negative_amount_test(C) ->
    #{
        wallet_id := WalletID,
        source_id := SourceID,
        party_id := PartyID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositCash = {-100, <<"RUB">>},
    DepositParams = #{
        id => DepositID,
        body => DepositCash,
        source_id => SourceID,
        wallet_id => WalletID,
        party_id => PartyID,
        external_id => genlib:unique()
    },
    ok = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    succeeded = await_final_deposit_status(DepositID),
    ok = ct_objects:await_wallet_balance({0, <<"RUB">>}, WalletID).

-spec create_currency_validation_error_test(config()) -> test_return().
create_currency_validation_error_test(C) ->
    #{
        wallet_id := WalletID,
        source_id := SourceID,
        party_id := PartyID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositParams = #{
        id => DepositID,
        body => {5000, <<"EUR">>},
        source_id => SourceID,
        wallet_id => WalletID,
        party_id => PartyID,
        external_id => genlib:unique()
    },
    Result = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    Details = {
        #domain_CurrencyRef{symbolic_code = <<"EUR">>},
        [
            #domain_CurrencyRef{symbolic_code = <<"RUB">>},
            #domain_CurrencyRef{symbolic_code = <<"USD">>}
        ]
    },
    ?assertMatch({error, {terms_violation, {not_allowed_currency, Details}}}, Result).

-spec create_source_notfound_test(config()) -> test_return().
create_source_notfound_test(C) ->
    #{
        party_id := PartyID,
        wallet_id := WalletID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositParams = #{
        id => DepositID,
        body => {5000, <<"RUB">>},
        source_id => <<"unknown_source">>,
        wallet_id => WalletID,
        party_id => PartyID,
        external_id => genlib:unique()
    },
    Result = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    ?assertMatch({error, {source, notfound}}, Result).

-spec create_wallet_notfound_test(config()) -> test_return().
create_wallet_notfound_test(C) ->
    #{
        source_id := SourceID,
        party_id := PartyID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositParams = #{
        id => DepositID,
        body => {5000, <<"RUB">>},
        source_id => SourceID,
        wallet_id => <<"unknown_wallet">>,
        party_id => PartyID,
        external_id => genlib:unique()
    },
    Result = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    ?assertMatch({error, {wallet, notfound}}, Result).

-spec create_party_mismatch_test(config()) -> test_return().
create_party_mismatch_test(C) ->
    #{
        wallet_id := WalletID,
        source_id := SourceID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositParams = #{
        id => DepositID,
        body => {5000, <<"RUB">>},
        source_id => SourceID,
        wallet_id => WalletID,
        party_id => <<"unknown_party">>,
        external_id => genlib:unique()
    },
    Result = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    ?assertMatch({error, {wallet, notfound}}, Result).

-spec preserve_revisions_test(config()) -> test_return().
preserve_revisions_test(C) ->
    #{
        wallet_id := WalletID,
        source_id := SourceID,
        party_id := PartyID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositCash = {5000, <<"RUB">>},
    DepositParams = #{
        id => DepositID,
        body => DepositCash,
        source_id => SourceID,
        wallet_id => WalletID,
        party_id => PartyID,
        external_id => DepositID
    },
    ok = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    Deposit = get_deposit(DepositID),
    ?assertNotEqual(undefined, ff_deposit:domain_revision(Deposit)),
    ?assertNotEqual(undefined, ff_deposit:created_at(Deposit)).

-spec create_ok_test(config()) -> test_return().
create_ok_test(C) ->
    #{
        wallet_id := WalletID,
        source_id := SourceID,
        party_id := PartyID
    } = prepare_standard_environment(C),
    DepositID = genlib:unique(),
    DepositCash = {5000, <<"RUB">>},
    DepositParams = #{
        id => DepositID,
        body => DepositCash,
        source_id => SourceID,
        wallet_id => WalletID,
        party_id => PartyID,
        external_id => DepositID
    },
    ok = ff_deposit_machine:create(DepositParams, ff_entity_context:new()),
    succeeded = await_final_deposit_status(DepositID),
    %% 100 added by setup env
    ok = ct_objects:await_wallet_balance({5000 + 100, <<"RUB">>}, WalletID),
    Deposit = get_deposit(DepositID),
    DepositCash = ff_deposit:body(Deposit),
    WalletID = ff_deposit:wallet_id(Deposit),
    SourceID = ff_deposit:source_id(Deposit),
    DepositID = ff_deposit:external_id(Deposit).

-spec unknown_test(config()) -> test_return().
unknown_test(_C) ->
    DepositID = <<"unknown_deposit">>,
    Result = ff_deposit_machine:get(DepositID),
    ?assertMatch({error, {unknown_deposit, DepositID}}, Result).

%% Utils

prepare_standard_environment(_C) ->
    Ctx = ct_objects:build_default_ctx(),
    ct_objects:prepare_standard_environment(Ctx).

get_deposit(DepositID) ->
    {ok, Machine} = ff_deposit_machine:get(DepositID),
    ff_deposit_machine:deposit(Machine).

get_deposit_status(DepositID) ->
    ff_deposit:status(get_deposit(DepositID)).

await_final_deposit_status(DepositID) ->
    finished = ct_helper:await(
        finished,
        fun() ->
            {ok, Machine} = ff_deposit_machine:get(DepositID),
            Deposit = ff_deposit_machine:deposit(Machine),
            case ff_deposit:is_finished(Deposit) of
                false ->
                    {not_finished, Deposit};
                true ->
                    finished
            end
        end,
        genlib_retry:linear(20, 1000)
    ),
    get_deposit_status(DepositID).
