-module(ff_clock).

-include_lib("fistful_proto/include/ff_proto_transfer_thrift.hrl").

-define(VERSION, 1).
-define(TYPE_LATEST, latest).
-define(TYPE_VECTOR, vector).

-type type() :: ?TYPE_LATEST | ?TYPE_VECTOR.
-type version() :: non_neg_integer().
-type kind() :: transfer.

-opaque clock() :: #{
    version := version(),
    type := type(),
    state => binary() | undefined
}.

-export_type([type/0]).
-export_type([version/0]).
-export_type([clock/0]).

%% API
-export([marshal/2]).
-export([unmarshal/2]).
-export([latest_clock/0]).

-spec latest_clock() -> clock().
latest_clock() ->
    new(?TYPE_LATEST).

-spec marshal(kind(), clock()) ->
    ff_proto_transfer_thrift:'Clock'().
marshal(transfer, #{type := ?TYPE_LATEST = Type}) ->
    {Type, #transfer_LatestClock{}};
marshal(transfer, #{type := ?TYPE_VECTOR = Type, state := State}) ->
    {Type, #transfer_VectorClock{state = State}}.

-spec unmarshal(kind(), Clock) -> clock() when
    Clock :: ff_proto_transfer_thrift:'Clock'().
unmarshal(transfer, {?TYPE_LATEST = Type, #transfer_LatestClock{}}) ->
    new(Type);
unmarshal(transfer, {?TYPE_VECTOR = Type, #transfer_VectorClock{state = State}}) ->
    Clock = new(Type),
    Clock#{
        state => State
    }.

new(Type) ->
    #{
        version => ?VERSION,
        type => Type
    }.
