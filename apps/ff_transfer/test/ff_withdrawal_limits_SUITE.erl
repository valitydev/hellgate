-module(ff_withdrawal_limits_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("ff_cth/include/ct_domain.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").

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
-export([limit_success/1]).
-export([limit_overflow/1]).
-export([limit_hold_currency_error/1]).
-export([limit_hold_operation_error/1]).
-export([limit_hold_paytool_error/1]).
-export([limit_hold_error_two_routes_failure/1]).
-export([choose_provider_without_limit_overflow/1]).
-export([provider_limits_exhaust_orderly/1]).
-export([provider_retry/1]).
-export([limit_exhaust_on_provider_retry/1]).
-export([first_limit_exhaust_on_provider_retry/1]).

%% Internal types

-type config() :: ct_helper:config().
-type test_case_name() :: ct_helper:test_case_name().
-type group_name() :: ct_helper:group_name().
-type test_return() :: _ | no_return().

%% API

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        {group, default}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {default, [sequence], [
            limit_success,
            limit_overflow,
            limit_hold_currency_error,
            limit_hold_operation_error,
            limit_hold_paytool_error,
            limit_hold_error_two_routes_failure,
            choose_provider_without_limit_overflow,
            provider_limits_exhaust_orderly,
            provider_retry,
            limit_exhaust_on_provider_retry,
            first_limit_exhaust_on_provider_retry
        ]}
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    ff_ct_machine:load_per_suite(),
    ct_helper:makeup_cfg(
        [
            ct_helper:test_case_name(init),
            ct_payment_system:setup(#{
                setup_dominant => fun ff_limiter_helper:init_per_suite/1
            })
        ],
        C
    ).

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    ff_ct_machine:unload_per_suite(),
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
init_per_testcase(Name, C0) when
    Name =:= limit_hold_currency_error orelse
        Name =:= limit_hold_operation_error orelse
        Name =:= limit_hold_paytool_error orelse
        Name =:= limit_hold_error_two_routes_failure
->
    C1 = do_init_per_testcase(Name, C0),
    meck:new(ff_woody_client, [no_link, passthrough]),
    C1;
init_per_testcase(Name, C0) ->
    do_init_per_testcase(Name, C0).

do_init_per_testcase(Name, C0) ->
    C1 = ct_helper:makeup_cfg(
        [
            ct_helper:test_case_name(Name),
            ct_helper:woody_ctx()
        ],
        C0
    ),
    ok = ct_helper:set_context(C1),
    PartyID = create_party(C1),
    C2 = ct_helper:cfg('$party', PartyID, C1),
    case Name of
        Name when
            Name =:= provider_retry orelse
                Name =:= limit_exhaust_on_provider_retry orelse
                Name =:= first_limit_exhaust_on_provider_retry
        ->
            _ = set_retryable_errors(PartyID, [<<"authorization_error">>]);
        _ ->
            ok
    end,
    C2.

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(Name, C) when
    Name =:= limit_hold_currency_error orelse
        Name =:= limit_hold_operation_error orelse
        Name =:= limit_hold_paytool_error orelse
        Name =:= limit_hold_error_two_routes_failure
->
    meck:unload(ff_woody_client),
    do_end_per_testcase(Name, C);
end_per_testcase(Name, C) ->
    do_end_per_testcase(Name, C).

do_end_per_testcase(Name, C) ->
    case Name of
        Name when
            Name =:= provider_retry orelse
                Name =:= limit_exhaust_on_provider_retry orelse
                Name =:= first_limit_exhaust_on_provider_retry
        ->
            PartyID = ct_helper:cfg('$party', C),
            _ = set_retryable_errors(PartyID, []);
        _ ->
            ok
    end,
    ct_helper:unset_context().

%% Tests

-spec limit_success(config()) -> test_return().
limit_success(C) ->
    Cash = {800800, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = generate_id(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID
    },
    PreviousAmount = get_limit_amount(Cash, WalletID, DestinationID, ?LIMIT_TURNOVER_NUM_PAYTOOL_ID1, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(
        PreviousAmount + 1,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_NUM_PAYTOOL_ID1, ct_helper:cfg('$limits_domain_revision', C), Withdrawal, C
        )
    ).

-spec limit_overflow(config()) -> test_return().
limit_overflow(C) ->
    Cash = {900900, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = generate_id(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID
    },
    PreviousAmount = get_limit_amount(Cash, WalletID, DestinationID, ?LIMIT_TURNOVER_NUM_PAYTOOL_ID2, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"no_route_found">>}}, Result),
    %% we get final withdrawal status before we rollback limits so wait for it some amount of time
    ok = timer:sleep(500),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(
        PreviousAmount,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_NUM_PAYTOOL_ID2, ct_helper:cfg('$limits_domain_revision', C), Withdrawal, C
        )
    ).

-spec limit_hold_currency_error(config()) -> test_return().
limit_hold_currency_error(C) ->
    mock_limiter_trm_hold_batch(?trm(1800), fun(_LimitRequest, _Context) ->
        {exception, #limiter_InvalidOperationCurrency{currency = <<"RUB">>, expected_currency = <<"KEK">>}}
    end),
    limit_hold_error(C).

-spec limit_hold_operation_error(config()) -> test_return().
limit_hold_operation_error(C) ->
    mock_limiter_trm_hold_batch(?trm(1800), fun(_LimitRequest, _Context) ->
        {exception, #limiter_OperationContextNotSupported{
            context_type = {withdrawal_processing, #limiter_config_LimitContextTypeWithdrawalProcessing{}}
        }}
    end),
    limit_hold_error(C).

-spec limit_hold_paytool_error(config()) -> test_return().
limit_hold_paytool_error(C) ->
    mock_limiter_trm_hold_batch(?trm(1800), fun(_LimitRequest, _Context) ->
        {exception, #limiter_PaymentToolNotSupported{payment_tool = <<"unsupported paytool">>}}
    end),
    limit_hold_error(C).

-spec limit_hold_error_two_routes_failure(config()) -> test_return().
limit_hold_error_two_routes_failure(C) ->
    mock_limiter_trm_call(?trm(2000), fun(_LimitRequest, _Context) ->
        {exception, #limiter_PaymentToolNotSupported{payment_tool = <<"unsupported paytool">>}}
    end),
    %% See `?ruleset(?PAYINST1_ROUTING_POLICIES + 18)` with two candidates in `ct_payment_system:domain_config/1`.
    Cash = {901000, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = generate_id(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"no_route_found">>}}, Result).

-define(LIMITER_REQUEST(Func, TerminalRef), {
    {limproto_limiter_thrift, 'Limiter'},
    Func,
    {_LimitRequest, #limiter_LimitContext{
        withdrawal_processing = #context_withdrawal_Context{
            withdrawal = #context_withdrawal_Withdrawal{route = #base_Route{terminal = TerminalRef}}
        }
    }}
}).

-define(MOCKED_LIMITER_FUNC(CallFunc, ExpectTerminalRef, ReturnFunc), fun
    (limiter, {_, _, Args} = ?LIMITER_REQUEST(CallFunc, TerminalRef)) when TerminalRef =:= ExpectTerminalRef ->
        apply(ReturnFunc, tuple_to_list(Args));
    (Service, Request) ->
        meck:passthrough([Service, Request])
end).

mock_limiter_trm_hold_batch(ExpectTerminalRef, ReturnFunc) ->
    ok = meck:expect(ff_woody_client, call, ?MOCKED_LIMITER_FUNC('HoldBatch', ExpectTerminalRef, ReturnFunc)).

mock_limiter_trm_call(ExpectTerminalRef, ReturnFunc) ->
    ok = meck:expect(ff_woody_client, call, ?MOCKED_LIMITER_FUNC(_, ExpectTerminalRef, ReturnFunc)).

limit_hold_error(C) ->
    Cash = {800800, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = generate_id(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"no_route_found">>}}, Result).

-spec choose_provider_without_limit_overflow(config()) -> test_return().
choose_provider_without_limit_overflow(C) ->
    Cash = {901000, <<"RUB">>},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = generate_id(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID
    },
    PreviousAmount = get_limit_amount(Cash, WalletID, DestinationID, ?LIMIT_TURNOVER_NUM_PAYTOOL_ID2, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(
        PreviousAmount + 1,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_NUM_PAYTOOL_ID2, ct_helper:cfg('$limits_domain_revision', C), Withdrawal, C
        )
    ).

-spec provider_limits_exhaust_orderly(config()) -> test_return().
provider_limits_exhaust_orderly(C) ->
    Currency = <<"RUB">>,
    Cash1 = {902000, Currency},
    Cash2 = {903000, Currency},
    %% we don't want to overflow wallet cash limit
    TotalCash = {3000000, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(TotalCash, C),

    %% First withdrawal goes to limit 1 and spents half of its amount
    WithdrawalID1 = generate_id(),
    WithdrawalParams1 = #{
        id => WithdrawalID1,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash1,
        external_id => WithdrawalID1
    },
    0 = get_limit_amount(Cash1, WalletID, DestinationID, ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams1, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID1)),
    Withdrawal1 = get_withdrawal(WithdrawalID1),
    ?assertEqual(
        902000,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, ct_helper:cfg('$limits_domain_revision', C), Withdrawal1, C
        )
    ),

    %% Second withdrawal goes to limit 2 as limit 1 doesn't have enough and spents all its amount
    WithdrawalID2 = generate_id(),
    WithdrawalParams2 = #{
        id => WithdrawalID2,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash2,
        external_id => WithdrawalID2
    },
    0 = get_limit_amount(Cash2, WalletID, DestinationID, ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams2, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID2)),
    Withdrawal2 = get_withdrawal(WithdrawalID2),
    ?assertEqual(
        903000,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, ct_helper:cfg('$limits_domain_revision', C), Withdrawal2, C
        )
    ),

    %% Third withdrawal goes to limit 1 and spents all its amount
    WithdrawalID3 = generate_id(),
    WithdrawalParams3 = #{
        id => WithdrawalID3,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash1,
        external_id => WithdrawalID3
    },
    902000 = get_limit_amount(Cash1, WalletID, DestinationID, ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams3, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID3)),
    Withdrawal3 = get_withdrawal(WithdrawalID3),
    ?assertEqual(
        1804000,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, ct_helper:cfg('$limits_domain_revision', C), Withdrawal3, C
        )
    ),

    %% Last withdrawal can't find route cause all limits are drained
    WithdrawalID = generate_id(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash1,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"no_route_found">>}}, Result).

-spec provider_retry(config()) -> test_return().
provider_retry(C) ->
    Currency = <<"RUB">>,
    Cash = {904000, Currency},
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = generate_id(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(WalletID, ff_withdrawal:wallet_id(Withdrawal)),
    ?assertEqual(DestinationID, ff_withdrawal:destination_id(Withdrawal)),
    ?assertEqual(Cash, ff_withdrawal:body(Withdrawal)),
    ?assertEqual(WithdrawalID, ff_withdrawal:external_id(Withdrawal)).

-spec limit_exhaust_on_provider_retry(config()) -> test_return().
limit_exhaust_on_provider_retry(C) ->
    ?assertEqual(
        {failed, #{code => <<"authorization_error">>, sub => #{code => <<"insufficient_funds">>}}},
        await_provider_retry(904000, 3000000, 4000000, C)
    ).

-spec first_limit_exhaust_on_provider_retry(config()) -> test_return().
first_limit_exhaust_on_provider_retry(C) ->
    ?assertEqual(succeeded, await_provider_retry(905000, 3001000, 4000000, C)).

await_provider_retry(FirstAmount, SecondAmount, TotalAmount, C) ->
    Currency = <<"RUB">>,
    #{
        wallet_id := WalletID,
        destination_id := DestinationID
    } = prepare_standard_environment({TotalAmount, Currency}, C),
    WithdrawalID1 = generate_id(),
    WithdrawalParams1 = #{
        id => WithdrawalID1,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => {FirstAmount, Currency},
        external_id => WithdrawalID1
    },
    WithdrawalID2 = generate_id(),
    WithdrawalParams2 = #{
        id => WithdrawalID2,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => {SecondAmount, Currency},
        external_id => WithdrawalID2
    },
    Activity = {fail, session},
    {ok, Barrier} = ff_ct_barrier:start_link(),
    ok = ff_ct_machine:set_hook(
        timeout,
        fun
            (Machine, ff_withdrawal_machine, _Args) ->
                Withdrawal = ff_machine:model(ff_machine:collapse(ff_withdrawal, Machine)),
                case {ff_withdrawal:id(Withdrawal), ff_withdrawal:activity(Withdrawal)} of
                    {WithdrawalID1, Activity} ->
                        ff_ct_barrier:enter(Barrier, _Timeout = 10000);
                    _ ->
                        ok
                end;
            (_Machine, _Handler, _Args) ->
                false
        end
    ),
    ok = ff_withdrawal_machine:create(WithdrawalParams1, ff_entity_context:new()),
    _ = await_withdrawal_activity(Activity, WithdrawalID1),
    ok = ff_withdrawal_machine:create(WithdrawalParams2, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID2)),
    ok = ff_ct_barrier:release(Barrier),
    Status = await_final_withdrawal_status(WithdrawalID1),
    ok = ff_ct_machine:clear_hook(timeout),
    ok = ff_ct_barrier:stop(Barrier),
    Status.

set_retryable_errors(PartyID, ErrorList) ->
    application:set_env(ff_transfer, withdrawal, #{
        party_transient_errors => #{
            PartyID => ErrorList
        }
    }).

get_limit_withdrawal(Cash, WalletID, DestinationID) ->
    {ok, WalletMachine} = ff_wallet_machine:get(WalletID),
    Wallet = ff_wallet_machine:wallet(WalletMachine),
    WalletAccount = ff_wallet:account(Wallet),
    {ok, SenderSt} = ff_identity_machine:get(ff_account:identity(WalletAccount)),
    SenderIdentity = ff_identity_machine:identity(SenderSt),

    #wthd_domain_Withdrawal{
        created_at = ff_codec:marshal(timestamp_ms, ff_time:now()),
        body = ff_dmsl_codec:marshal(cash, Cash),
        destination = ff_adapter_withdrawal_codec:marshal(resource, get_destination_resource(DestinationID)),
        sender = ff_adapter_withdrawal_codec:marshal(identity, #{
            id => ff_identity:id(SenderIdentity),
            owner_id => ff_identity:party(SenderIdentity)
        })
    }.

get_limit_amount(Cash, WalletID, DestinationID, LimitID, C) ->
    Withdrawal = get_limit_withdrawal(Cash, WalletID, DestinationID),
    ff_limiter_helper:get_limit_amount(LimitID, ct_helper:cfg('$limits_domain_revision', C), Withdrawal, C).

get_destination_resource(DestinationID) ->
    {ok, DestinationMachine} = ff_destination_machine:get(DestinationID),
    Destination = ff_destination_machine:destination(DestinationMachine),
    {ok, Resource} = ff_resource:create_resource(ff_destination:resource(Destination)),
    Resource.

prepare_standard_environment({_Amount, Currency} = WithdrawalCash, C) ->
    PartyID = ct_helper:cfg('$party', C),
    IdentityID = create_person_identity(PartyID, C),
    WalletID = create_wallet(IdentityID, <<"My wallet">>, Currency, C),
    ok = await_wallet_balance({0, Currency}, WalletID),
    DestinationID = create_destination(IdentityID, Currency, C),
    ok = set_wallet_balance(WithdrawalCash, WalletID),
    #{
        identity_id => IdentityID,
        party_id => PartyID,
        wallet_id => WalletID,
        destination_id => DestinationID
    }.

get_withdrawal(WithdrawalID) ->
    {ok, Machine} = ff_withdrawal_machine:get(WithdrawalID),
    ff_withdrawal_machine:withdrawal(Machine).

get_withdrawal_status(WithdrawalID) ->
    Withdrawal = get_withdrawal(WithdrawalID),
    ff_withdrawal:status(Withdrawal).

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

await_withdrawal_activity(Activity, WithdrawalID) ->
    ct_helper:await(
        Activity,
        fun() ->
            {ok, Machine} = ff_withdrawal_machine:get(WithdrawalID),
            ff_withdrawal:activity(ff_withdrawal_machine:withdrawal(Machine))
        end,
        genlib_retry:linear(20, 1000)
    ).

create_party(_C) ->
    ID = genlib:bsuuid(),
    _ = ff_party:create(ID),
    ID.

create_person_identity(Party, C) ->
    create_identity(Party, <<"good-one">>, C).

create_identity(Party, ProviderID, C) ->
    create_identity(Party, <<"Identity Name">>, ProviderID, C).

create_identity(Party, Name, ProviderID, _C) ->
    ID = genlib:unique(),
    ok = ff_identity_machine:create(
        #{id => ID, name => Name, party => Party, provider => ProviderID},
        #{<<"com.valitydev.wapi">> => #{<<"name">> => Name}}
    ),
    ID.

create_wallet(IdentityID, Name, Currency, _C) ->
    ID = genlib:unique(),
    ok = ff_wallet_machine:create(
        #{id => ID, identity => IdentityID, name => Name, currency => Currency},
        ff_entity_context:new()
    ),
    ID.

await_wallet_balance({Amount, Currency}, ID) ->
    Balance = {Amount, {{inclusive, Amount}, {inclusive, Amount}}, Currency},
    Balance = ct_helper:await(
        Balance,
        fun() -> get_wallet_balance(ID) end,
        genlib_retry:linear(3, 500)
    ),
    ok.

get_wallet_balance(ID) ->
    {ok, Machine} = ff_wallet_machine:get(ID),
    get_account_balance(ff_wallet:account(ff_wallet_machine:wallet(Machine))).

get_account_balance(Account) ->
    {ok, {Amounts, Currency}} = ff_accounting:balance(Account),
    {ff_indef:current(Amounts), ff_indef:to_range(Amounts), Currency}.

generate_id() ->
    ff_id:generate_snowflake_id().

create_destination(IID, Currency, C) ->
    ID = generate_id(),
    StoreSource = ct_cardstore:bank_card(<<"4150399999000900">>, {12, 2025}, C),
    Resource = {bank_card, #{bank_card => StoreSource}},
    Params = #{id => ID, identity => IID, name => <<"XDesination">>, currency => Currency, resource => Resource},
    ok = ff_destination_machine:create(Params, ff_entity_context:new()),
    authorized = ct_helper:await(
        authorized,
        fun() ->
            {ok, Machine} = ff_destination_machine:get(ID),
            Destination = ff_destination_machine:destination(Machine),
            ff_destination:status(Destination)
        end
    ),
    ID.

set_wallet_balance({Amount, Currency}, ID) ->
    TransactionID = generate_id(),
    {ok, Machine} = ff_wallet_machine:get(ID),
    Account = ff_wallet:account(ff_wallet_machine:wallet(Machine)),
    AccounterID = ff_account:accounter_account_id(Account),
    {CurrentAmount, _, Currency} = get_account_balance(Account),
    {ok, AnotherAccounterID} = ct_helper:create_account(Currency),
    Postings = [{AnotherAccounterID, AccounterID, {Amount - CurrentAmount, Currency}}],
    {ok, _} = ff_accounting:prepare_trx(TransactionID, Postings),
    {ok, _} = ff_accounting:commit_trx(TransactionID, Postings),
    ok.
