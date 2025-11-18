-module(ff_destination_codec).

-behaviour(ff_codec).

-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").

-export([unmarshal_destination_params/1]).
-export([marshal_destination_state/2]).

-export([marshal_event/1]).

-export([marshal/2]).
-export([unmarshal/2]).

%% API

-spec unmarshal_destination_params(fistful_destination_thrift:'DestinationParams'()) -> ff_destination:params().
unmarshal_destination_params(Params) ->
    genlib_map:compact(#{
        id => unmarshal(id, Params#destination_DestinationParams.id),
        realm => Params#destination_DestinationParams.realm,
        party_id => unmarshal(id, Params#destination_DestinationParams.party_id),
        name => unmarshal(string, Params#destination_DestinationParams.name),
        currency => unmarshal(string, Params#destination_DestinationParams.currency),
        resource => unmarshal(resource, Params#destination_DestinationParams.resource),
        external_id => maybe_unmarshal(id, Params#destination_DestinationParams.external_id),
        metadata => maybe_unmarshal(ctx, Params#destination_DestinationParams.metadata),
        auth_data => maybe_unmarshal(auth_data, Params#destination_DestinationParams.auth_data)
    }).

-spec marshal_destination_state(ff_destination:destination_state(), ff_entity_context:context()) ->
    fistful_destination_thrift:'DestinationState'().
marshal_destination_state(DestinationState, Context) ->
    Blocking =
        case ff_destination:is_accessible(DestinationState) of
            {ok, accessible} ->
                unblocked;
            _ ->
                blocked
        end,
    #destination_DestinationState{
        id = marshal(id, ff_destination:id(DestinationState)),
        realm = ff_destination:realm(DestinationState),
        party_id = marshal(id, ff_destination:party_id(DestinationState)),
        name = marshal(string, ff_destination:name(DestinationState)),
        resource = maybe_marshal(resource, ff_destination:resource(DestinationState)),
        external_id = maybe_marshal(id, ff_destination:external_id(DestinationState)),
        account = maybe_marshal(account, ff_destination:account(DestinationState)),
        created_at = maybe_marshal(timestamp_ms, ff_destination:created_at(DestinationState)),
        blocking = Blocking,
        metadata = maybe_marshal(ctx, ff_destination:metadata(DestinationState)),
        context = maybe_marshal(ctx, Context),
        auth_data = maybe_marshal(auth_data, ff_destination:auth_data(DestinationState))
    }.

-spec marshal_event(ff_destination_machine:event()) -> fistful_destination_thrift:'Event'().
marshal_event({EventID, {ev, Timestamp, Change}}) ->
    #destination_Event{
        event_id = ff_codec:marshal(event_id, EventID),
        occured_at = ff_codec:marshal(timestamp, Timestamp),
        change = marshal(change, Change)
    }.

-spec marshal(ff_codec:type_name(), ff_codec:decoded_value()) -> ff_codec:encoded_value().
marshal(timestamped_change, {ev, Timestamp, Change}) ->
    #destination_TimestampedChange{
        change = marshal(change, Change),
        occured_at = ff_codec:marshal(timestamp, Timestamp)
    };
marshal(change, {created, Destination}) ->
    {created, marshal(create_change, Destination)};
marshal(change, {account, AccountChange}) ->
    {account, marshal(account_change, AccountChange)};
marshal(change, {status_changed, StatusChange}) ->
    {status, marshal(status_change, StatusChange)};
marshal(
    create_change,
    #{
        name := Name,
        resource := Resource
    } = Destination
) ->
    #destination_Destination{
        id = marshal(id, ff_destination:id(Destination)),
        realm = ff_destination:realm(Destination),
        party_id = marshal(id, ff_destination:party_id(Destination)),
        name = Name,
        resource = marshal(resource, Resource),
        created_at = maybe_marshal(timestamp_ms, maps:get(created_at, Destination, undefined)),
        external_id = maybe_marshal(id, maps:get(external_id, Destination, undefined)),
        metadata = maybe_marshal(ctx, maps:get(metadata, Destination, undefined)),
        auth_data = maybe_marshal(auth_data, maps:get(auth_data, Destination, undefined))
    };
marshal(ctx, Ctx) ->
    marshal(context, Ctx);
marshal(auth_data, #{
    sender := SenderToken,
    receiver := ReceiverToken
}) ->
    {sender_receiver, #destination_SenderReceiverAuthData{
        sender = marshal(string, SenderToken),
        receiver = marshal(string, ReceiverToken)
    }};
marshal(T, V) ->
    ff_codec:marshal(T, V).

-spec unmarshal(ff_codec:type_name(), ff_codec:encoded_value()) -> ff_codec:decoded_value().
unmarshal({list, T}, V) ->
    [unmarshal(T, E) || E <- V];
unmarshal(repair_scenario, {add_events, #destination_AddEventsRepair{events = Events, action = Action}}) ->
    {add_events,
        genlib_map:compact(#{
            events => unmarshal({list, change}, Events),
            action => maybe_unmarshal(complex_action, Action)
        })};
unmarshal(timestamped_change, TimestampedChange) ->
    Timestamp = ff_codec:unmarshal(timestamp, TimestampedChange#destination_TimestampedChange.occured_at),
    Change = unmarshal(change, TimestampedChange#destination_TimestampedChange.change),
    {ev, Timestamp, Change};
unmarshal(change, {created, Destination}) ->
    {created, unmarshal(destination, Destination)};
unmarshal(change, {account, AccountChange}) ->
    {account, unmarshal(account_change, AccountChange)};
unmarshal(change, {status, StatusChange}) ->
    {status_changed, unmarshal(status_change, StatusChange)};
unmarshal(destination, Dest) ->
    genlib_map:compact(#{
        version => 5,
        id => unmarshal(id, Dest#destination_Destination.id),
        realm => Dest#destination_Destination.realm,
        party_id => unmarshal(id, Dest#destination_Destination.party_id),
        resource => unmarshal(resource, Dest#destination_Destination.resource),
        name => unmarshal(string, Dest#destination_Destination.name),
        created_at => maybe_unmarshal(timestamp_ms, Dest#destination_Destination.created_at),
        external_id => maybe_unmarshal(id, Dest#destination_Destination.external_id),
        metadata => maybe_unmarshal(ctx, Dest#destination_Destination.metadata),
        auth_data => maybe_unmarshal(auth_data, Dest#destination_Destination.auth_data)
    });
unmarshal(ctx, Ctx) ->
    maybe_unmarshal(context, Ctx);
unmarshal(
    auth_data,
    {sender_receiver, #destination_SenderReceiverAuthData{
        sender = SenderToken,
        receiver = ReceiverToken
    }}
) ->
    #{
        sender => unmarshal(string, SenderToken),
        receiver => unmarshal(string, ReceiverToken)
    };
unmarshal(T, V) ->
    ff_codec:unmarshal(T, V).

%% Internals

maybe_marshal(_Type, undefined) ->
    undefined;
maybe_marshal(Type, Value) ->
    marshal(Type, Value).

maybe_unmarshal(_Type, undefined) ->
    undefined;
maybe_unmarshal(Type, Value) ->
    unmarshal(Type, Value).

%% TESTS

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec destination_test() -> _.

destination_test() ->
    Resource =
        {bank_card, #{
            bank_card => #{
                token => <<"token auth">>
            }
        }},
    In = #{
        version => 5,
        id => <<"9e6245a7a6e15f75769a4d87183b090a">>,
        realm => live,
        party_id => <<"9e6245a7a6e15f75769a4d87183b090a">>,
        name => <<"Wallet">>,
        resource => Resource
    },

    ?assertEqual(In, unmarshal(destination, marshal(create_change, In))).

-spec crypto_wallet_resource_test() -> _.
crypto_wallet_resource_test() ->
    Resource =
        {crypto_wallet, #{
            crypto_wallet => #{
                id => <<"9e6245a7a6e15f75769a4d87183b090a">>,
                currency => #{id => <<"bitcoin">>}
            }
        }},
    ?assertEqual(Resource, unmarshal(resource, marshal(resource, Resource))).

-spec digital_wallet_resource_test() -> _.
digital_wallet_resource_test() ->
    Resource =
        {digital_wallet, #{
            digital_wallet => #{
                id => <<"a30e277c07400c9940628828949efd48">>,
                token => <<"a30e277c07400c9940628828949efd48">>,
                payment_service => #{id => <<"webmoney">>},
                account_name => <<"accountName">>,
                account_identity_number => <<"accountIdentityNumber">>
            }
        }},
    ?assertEqual(Resource, unmarshal(resource, marshal(resource, Resource))).

-endif.
