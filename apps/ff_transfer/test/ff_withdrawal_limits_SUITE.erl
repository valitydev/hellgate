-module(ff_withdrawal_limits_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("ff_cth/include/ct_domain.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").
-include_lib("limiter_proto/include/limproto_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").
-include_lib("validator_personal_data_proto/include/validator_personal_data_validator_personal_data_thrift.hrl").
-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").

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
-export([sender_receiver_limit_success/1]).
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
            sender_receiver_limit_success,
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
            ct_payment_system:setup()
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
    ct_helper:trace_testcase(?MODULE, Name, C2).

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
    ok = ct_helper:end_trace(C),
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
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID,
        party_id => PartyID
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

-spec sender_receiver_limit_success(config()) -> test_return().
sender_receiver_limit_success(C) ->
    %% mock validator
    ok = meck:expect(ff_woody_client, call, fun
        (validator, {_, _, {Token}}) ->
            {ok, #validator_personal_data_ValidationResponse{
                validation_id = <<"ID">>,
                token = Token,
                validation_status = valid
            }};
        (Service, Request) ->
            meck:passthrough([Service, Request])
    end),
    Cash = {_Amount, Currency} = {3002000, <<"RUB">>},
    #{
        wallet_id := WalletID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    AuthData = #{
        sender => <<"SenderToken">>,
        receiver => <<"ReceiverToken">>
    },
    MarshaledAuthData = AuthData,
    DestinationID = create_destination(PartyID, Currency, AuthData, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID,
        party_id => PartyID
    },
    PreviousAmount = get_limit_amount(
        Cash, WalletID, DestinationID, ?LIMIT_TURNOVER_NUM_SENDER_ID1, MarshaledAuthData, C
    ),
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID)),
    Withdrawal = get_withdrawal(WithdrawalID),
    ?assertEqual(
        PreviousAmount + 1,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_NUM_SENDER_ID1, ct_helper:cfg('$limits_domain_revision', C), Withdrawal, C
        )
    ),
    meck:unload(ff_woody_client).

-spec limit_overflow(config()) -> test_return().
limit_overflow(C) ->
    Cash = {900900, <<"RUB">>},
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
        body => Cash,
        external_id => WithdrawalID,
        party_id => PartyID
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
            context_type = {withdrawal_processing, #limiter_LimitContextTypeWithdrawalProcessing{}}
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
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID,
        party_id => PartyID
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
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID,
        party_id => PartyID
    },
    ok = ff_withdrawal_machine:create(WithdrawalParams, ff_entity_context:new()),
    Result = await_final_withdrawal_status(WithdrawalID),
    ?assertMatch({failed, #{code := <<"no_route_found">>}}, Result).

-spec choose_provider_without_limit_overflow(config()) -> test_return().
choose_provider_without_limit_overflow(C) ->
    Cash = {901000, <<"RUB">>},
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
        body => Cash,
        external_id => WithdrawalID,
        party_id => PartyID
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
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(TotalCash, C),

    %% First withdrawal goes to limit 1 and spents half of its amount
    WithdrawalID1 = genlib:bsuuid(),
    WithdrawalParams1 = #{
        id => WithdrawalID1,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash1,
        external_id => WithdrawalID1,
        party_id => PartyID
    },
    PreviousAmount1 = get_limit_amount(Cash1, WalletID, DestinationID, ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams1, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID1)),
    Withdrawal1 = get_withdrawal(WithdrawalID1),
    ?assertEqual(
        PreviousAmount1 + 902000,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, ct_helper:cfg('$limits_domain_revision', C), Withdrawal1, C
        )
    ),

    %% Second withdrawal goes to limit 2 as limit 1 doesn't have enough and spents all its amount
    WithdrawalID2 = genlib:bsuuid(),
    WithdrawalParams2 = #{
        id => WithdrawalID2,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash2,
        external_id => WithdrawalID2,
        party_id => PartyID
    },
    PreviousAmount2 = get_limit_amount(Cash2, WalletID, DestinationID, ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams2, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID2)),
    Withdrawal2 = get_withdrawal(WithdrawalID2),
    ?assertEqual(
        PreviousAmount2 + 903000,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, ct_helper:cfg('$limits_domain_revision', C), Withdrawal2, C
        )
    ),

    %% Third withdrawal goes to limit 1 and spents all its amount
    WithdrawalID3 = genlib:bsuuid(),
    WithdrawalParams3 = #{
        id => WithdrawalID3,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash1,
        external_id => WithdrawalID3,
        party_id => PartyID
    },
    _ = get_limit_amount(Cash1, WalletID, DestinationID, ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, C),
    ok = ff_withdrawal_machine:create(WithdrawalParams3, ff_entity_context:new()),
    ?assertEqual(succeeded, await_final_withdrawal_status(WithdrawalID3)),
    Withdrawal3 = get_withdrawal(WithdrawalID3),
    ExpectedAmount3 = PreviousAmount1 + 902000 + 902000,
    ?assertEqual(
        ExpectedAmount3,
        ff_limiter_helper:get_limit_amount(
            ?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, ct_helper:cfg('$limits_domain_revision', C), Withdrawal3, C
        )
    ),

    %% Last withdrawal can't find route cause all limits are drained
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash1,
        external_id => WithdrawalID,
        party_id => PartyID
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
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment(Cash, C),
    WithdrawalID = genlib:bsuuid(),
    WithdrawalParams = #{
        id => WithdrawalID,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => Cash,
        external_id => WithdrawalID,
        party_id => PartyID
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
        destination_id := DestinationID,
        party_id := PartyID
    } = prepare_standard_environment({TotalAmount, Currency}, C),
    WithdrawalID1 = genlib:bsuuid(),
    WithdrawalParams1 = #{
        id => WithdrawalID1,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => {FirstAmount, Currency},
        external_id => WithdrawalID1,
        party_id => PartyID
    },
    WithdrawalID2 = genlib:bsuuid(),
    WithdrawalParams2 = #{
        id => WithdrawalID2,
        destination_id => DestinationID,
        wallet_id => WalletID,
        body => {SecondAmount, Currency},
        external_id => WithdrawalID2,
        party_id => PartyID
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

get_limit_withdrawal(Cash, WalletID, DestinationID, AuthData) ->
    MarshaledAuthData =
        case AuthData of
            #{sender := _, receiver := _} ->
                {sender_receiver, #wthd_domain_SenderReceiverAuthData{
                    sender = maps:get(sender, AuthData),
                    receiver = maps:get(receiver, AuthData)
                }};
            _ ->
                AuthData
        end,
    #domain_WalletConfig{party_ref = Sender} = ct_objects:get_wallet(WalletID),
    #wthd_domain_Withdrawal{
        created_at = ff_codec:marshal(timestamp_ms, ff_time:now()),
        body = ff_dmsl_codec:marshal(cash, Cash),
        destination = ff_adapter_withdrawal_codec:marshal(resource, get_destination_resource(DestinationID)),
        sender = Sender,
        auth_data = MarshaledAuthData
    }.

get_limit_amount(Cash, WalletID, DestinationID, LimitID, C) ->
    get_limit_amount(Cash, WalletID, DestinationID, LimitID, undefined, C).
get_limit_amount(Cash, WalletID, DestinationID, LimitID, AuthData, C) ->
    Withdrawal = get_limit_withdrawal(Cash, WalletID, DestinationID, AuthData),
    ff_limiter_helper:get_limit_amount(LimitID, ct_helper:cfg('$limits_domain_revision', C), Withdrawal, C).

get_destination_resource(DestinationID) ->
    {ok, DestinationMachine} = ff_destination_machine:get(DestinationID),
    Destination = ff_destination_machine:destination(DestinationMachine),
    {ok, Resource} = ff_resource:create_resource(ff_destination:resource(Destination)),
    Resource.

prepare_standard_environment({_Amount, Currency} = WithdrawalCash, C) ->
    PartyID = ct_helper:cfg('$party', C),
    WalletID = ct_objects:create_wallet(
        PartyID, Currency, #domain_TermSetHierarchyRef{id = 1}, #domain_PaymentInstitutionRef{id = 1}
    ),
    ok = await_wallet_balance({0, Currency}, WalletID),
    DestinationID = ct_objects:create_destination(PartyID, undefined),
    SourceID = ct_objects:create_source(PartyID, Currency),
    {_DepositID, _} = ct_objects:create_deposit(PartyID, WalletID, SourceID, WithdrawalCash),
    ok = await_wallet_balance(WithdrawalCash, WalletID),
    #{
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
    _ = ct_domain:create_party(ID),
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
    ct_objects:get_wallet_balance(ID).

create_destination(IID, Currency, AuthData, _C) ->
    ID = genlib:bsuuid(),
    StoreSource = ct_cardstore:bank_card(<<"4150399999000900">>, {12, 2025}),
    Resource =
        {bank_card, #'fistful_base_ResourceBankCard'{
            bank_card = #'fistful_base_BankCard'{
                token = maps:get(token, StoreSource),
                bin = maps:get(bin, StoreSource, undefined),
                masked_pan = maps:get(masked_pan, StoreSource, undefined),
                exp_date = #'fistful_base_BankCardExpDate'{
                    month = 12,
                    year = 2025
                },
                cardholder_name = maps:get(cardholder_name, StoreSource, undefined)
            }
        }},
    Params = genlib_map:compact(#{
        id => ID,
        party_id => IID,
        name => <<"XDesination">>,
        currency => Currency,
        resource => Resource,
        auth_data => AuthData,
        realm => live
    }),
    ok = ff_destination_machine:create(Params, ff_entity_context:new()),
    ID.
