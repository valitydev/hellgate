-module(ff_transfer_SUITE).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_thrift.hrl").
-include_lib("fistful_proto/include/fistful_source_thrift.hrl").
-include_lib("fistful_proto/include/fistful_deposit_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("fistful_proto/include/fistful_msgp_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([get_missing_fails/1]).
-export([deposit_withdrawal_ok/1]).
-export([deposit_quote_withdrawal_ok/1]).
-export([deposit_withdrawal_to_crypto_wallet/1]).
-export([deposit_withdrawal_to_digital_wallet/1]).
-export([deposit_withdrawal_to_generic/1]).

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
        {default, [], [
            get_missing_fails,
            deposit_withdrawal_ok,
            deposit_quote_withdrawal_ok,
            deposit_withdrawal_to_crypto_wallet,
            deposit_withdrawal_to_digital_wallet,
            deposit_withdrawal_to_generic
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

%%

-spec get_missing_fails(config()) -> test_return().
get_missing_fails(_C) ->
    ID = genlib:bsuuid(),
    {error, {unknown_withdrawal, ID}} = ff_withdrawal_machine:get(ID).

-spec deposit_withdrawal_ok(config()) -> test_return().
deposit_withdrawal_ok(C) ->
    #{
        wallet_id := WalID,
        destination_id := DestID,
        party_id := Party
    } = prepare_standard_environment({10000, <<"RUB">>}, C),
    WdrID = process_withdrawal(Party, WalID, DestID),
    Events = get_withdrawal_events(WdrID),
    [1] = route_changes(Events).

-spec deposit_withdrawal_to_crypto_wallet(config()) -> test_return().
deposit_withdrawal_to_crypto_wallet(C) ->
    #{
        wallet_id := WalID,
        party_id := Party
    } = prepare_standard_environment({10000, <<"RUB">>}, C),
    DestID = create_crypto_destination(Party, C),
    WdrID = process_withdrawal(Party, WalID, DestID),
    Events = get_withdrawal_events(WdrID),
    [2] = route_changes(Events).

-spec deposit_withdrawal_to_digital_wallet(config()) -> test_return().
deposit_withdrawal_to_digital_wallet(C) ->
    #{
        wallet_id := WalID,
        party_id := Party
    } = prepare_standard_environment({10000, <<"RUB">>}, C),
    DestID = create_digital_destination(Party, C),
    WdrID = process_withdrawal(Party, WalID, DestID),
    Events = get_withdrawal_events(WdrID),
    [2] = route_changes(Events).

-spec deposit_withdrawal_to_generic(config()) -> test_return().
deposit_withdrawal_to_generic(C) ->
    #{
        wallet_id := WalID,
        party_id := Party
    } = prepare_standard_environment({10000, <<"RUB">>}, C),
    DestID = create_generic_destination(Party, C),
    WdrID = process_withdrawal(Party, WalID, DestID),
    Events = get_withdrawal_events(WdrID),
    [2] = route_changes(Events).

-spec deposit_quote_withdrawal_ok(config()) -> test_return().
deposit_quote_withdrawal_ok(C) ->
    #{
        wallet_id := WalID,
        destination_id := DestID,
        party_id := Party
    } = prepare_standard_environment({10000, <<"RUB">>}, C),
    WdrID = process_withdrawal(Party, WalID, DestID, #{
        wallet_id => WalID,
        destination_id => DestID,
        body => {4240, <<"RUB">>},
        quote => #{
            cash_from => {4240, <<"RUB">>},
            cash_to => {2120, <<"USD">>},
            created_at => <<"2016-03-22T06:12:27Z">>,
            expires_on => <<"2016-03-22T06:12:27Z">>,
            quote_data => #{<<"test">> => <<"test">>},
            route => ff_withdrawal_routing:make_route(1, 1),
            domain_revision => ct_domain_config:head(),
            operation_timestamp => ff_time:from_rfc3339(<<"2016-03-22T06:12:27Z">>)
        }
    }),
    Events = get_withdrawal_events(WdrID),
    [1] = route_changes(Events).

%% Utils

prepare_standard_environment({Amount, Currency}, C) ->
    PartyID = ct_objects:create_party(),
    WalID = create_wallet(PartyID, <<"WalletName">>, Currency, C),
    ok = ct_objects:await_wallet_balance({0, Currency}, WalID),
    DestID = ct_objects:create_destination(PartyID, undefined),
    SrcID = ct_objects:create_source(PartyID, Currency),
    ok = process_deposit(PartyID, SrcID, WalID, {Amount, Currency}),
    ok = ct_objects:await_wallet_balance({Amount, Currency}, WalID),
    #{
        party_id => PartyID,
        wallet_id => WalID,
        destination_id => DestID,
        source_id => SrcID
    }.

create_wallet(Party, _Name, Currency, _C) ->
    TermsRef = #domain_TermSetHierarchyRef{id = 1},
    PaymentInstRef = #domain_PaymentInstitutionRef{id = 1},
    ct_objects:create_wallet(Party, Currency, TermsRef, PaymentInstRef).

process_deposit(PartyID, SrcID, WalID, {Amount, Currency}) ->
    Body = #'fistful_base_Cash'{
        amount = Amount,
        currency = #'fistful_base_CurrencyRef'{symbolic_code = Currency}
    },
    {_DepID, _} = ct_objects:create_deposit(PartyID, WalID, SrcID, Body),
    ok.

create_crypto_destination(PartyID, _C) ->
    Resource =
        {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{
            crypto_wallet = #'fistful_base_CryptoWallet'{
                id = <<"a30e277c07400c9940628828949efd48">>,
                currency = #'fistful_base_CryptoCurrencyRef'{id = <<"Litecoin">>}
            }
        }},
    ct_objects:create_destination_(PartyID, Resource).

create_digital_destination(PartyID, _C) ->
    Resource =
        {digital_wallet, #'fistful_base_ResourceDigitalWallet'{
            digital_wallet = #'fistful_base_DigitalWallet'{
                id = <<"a30e277c07400c9940628828949efd48">>,
                token = <<"a30e277c07400c9940628828949efd48">>,
                payment_service = #'fistful_base_PaymentServiceRef'{id = <<"webmoney">>}
            }
        }},
    ct_objects:create_destination_(PartyID, Resource).

create_generic_destination(PartyID, _C) ->
    Resource =
        {generic, #'fistful_base_ResourceGeneric'{
            generic = #'fistful_base_ResourceGenericData'{
                data = #'fistful_base_Content'{type = <<"application/json">>, data = <<"{}">>},
                provider = #'fistful_base_PaymentServiceRef'{id = <<"IND">>}
            }
        }},
    ct_objects:create_destination_(PartyID, Resource).

process_withdrawal(PartyID, WalID, DestID) ->
    process_withdrawal(PartyID, WalID, DestID, #{
        wallet_id => WalID, destination_id => DestID, body => {4240, <<"RUB">>}
    }).

process_withdrawal(PartyID, WalID, DestID, Params) ->
    Body = make_cash({4240, <<"RUB">>}),
    Quote =
        case maps:get(quote, Params, undefined) of
            undefined ->
                undefined;
            QuoteData ->
                ff_withdrawal_codec:marshal(quote, QuoteData)
        end,
    WithdrawalParams = #wthd_WithdrawalParams{
        id = genlib:bsuuid(),
        party_id = PartyID,
        wallet_id = WalID,
        destination_id = DestID,
        body = Body,
        quote = Quote,
        external_id = genlib:bsuuid()
    },
    Ctx = ff_entity_context_codec:marshal(#{<<"NS">> => #{}}),
    {ok, State} = call_withdrawal('Create', {WithdrawalParams, Ctx}),
    #wthd_WithdrawalState{id = WdrID} = State,
    succeeded = await_final_withdrawal_status(WdrID),
    ok = ct_objects:await_wallet_balance({10000 - 4240, <<"RUB">>}, WalID),
    WdrID.

make_cash({Amount, Currency}) ->
    #'fistful_base_Cash'{
        amount = Amount,
        currency = #'fistful_base_CurrencyRef'{symbolic_code = Currency}
    }.

get_withdrawal(WithdrawalID) ->
    {ok, Machine} = ff_withdrawal_machine:get(WithdrawalID),
    ff_withdrawal_machine:withdrawal(Machine).

get_withdrawal_status(WithdrawalID) ->
    ff_withdrawal:status(get_withdrawal(WithdrawalID)).

await_final_withdrawal_status(WithdrawalID) ->
    ct_helper:await(
        succeeded,
        fun() -> get_withdrawal_status(WithdrawalID) end,
        genlib_retry:linear(10, 1000)
    ).

call_withdrawal(Fun, Args) ->
    Service = {fistful_wthd_thrift, 'Management'},
    Request = {Service, Fun, Args},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:8022/v1/withdrawal">>,
        event_handler => ff_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).

%%%

get_withdrawal_events(WdrID) ->
    Service = {{fistful_wthd_thrift, 'Management'}, <<"/v1/withdrawal">>},
    {ok, Events} = call('GetEvents', Service, {WdrID, #'fistful_base_EventRange'{'after' = 0, limit = 1000}}),
    Events.

call(Function, Service, Args) ->
    call(Function, Service, Args, <<"8022">>).

call(Function, {Service, Path}, Args, Port) ->
    Request = {Service, Function, Args},
    Client = ff_woody_client:new(#{
        url => <<"http://localhost:", Port/binary, Path/binary>>,
        event_handler => ff_woody_event_handler
    }),
    ff_woody_client:call(Client, Request).

route_changes(Events) ->
    lists:filtermap(
        fun
            (#wthd_Event{change = {route, RouteChange}}) ->
                #wthd_RouteChange{route = #wthd_Route{provider_id = ProviderID}} = RouteChange,
                {true, ProviderID};
            (_Other) ->
                false
        end,
        Events
    ).
