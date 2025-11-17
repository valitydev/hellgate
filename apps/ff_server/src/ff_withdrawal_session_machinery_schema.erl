-module(ff_withdrawal_session_machinery_schema).

%% Storage schema behaviour
-behaviour(machinery_mg_schema).

-export([get_version/1]).
-export([marshal/3]).
-export([unmarshal/3]).

%% Constants

-define(CURRENT_EVENT_FORMAT_VERSION, 1).

%% Internal types

-type type() :: machinery_mg_schema:t().
-type value(T) :: machinery_mg_schema:v(T).
-type value_type() :: machinery_mg_schema:vt().
-type context() :: machinery_mg_schema:context().

-type event() :: ff_machine:timestamped_event(ff_withdrawal_session:event()).
-type aux_state() :: ff_machine:auxst().
-type call_args() :: term().
-type call_response() :: term().

-type data() ::
    aux_state()
    | event()
    | call_args()
    | call_response().

%% machinery_mg_schema callbacks

-spec get_version(value_type()) -> machinery_mg_schema:version().
get_version(event) ->
    ?CURRENT_EVENT_FORMAT_VERSION;
get_version(aux_state) ->
    undefined.

-spec marshal(type(), value(data()), context()) -> {machinery_msgpack:t(), context()}.
marshal({event, Format}, TimestampedChange, Context) ->
    marshal_event(Format, TimestampedChange, Context);
marshal(T, V, C) when
    T =:= {args, init} orelse
        T =:= {args, call} orelse
        T =:= {args, repair} orelse
        T =:= {aux_state, undefined} orelse
        T =:= {response, call} orelse
        T =:= {response, {repair, success}} orelse
        T =:= {response, {repair, failure}}
->
    machinery_mg_schema_generic:marshal(T, V, C).

-spec unmarshal(type(), machinery_msgpack:t(), context()) -> {data(), context()}.
unmarshal({event, FormatVersion}, EncodedChange, Context) ->
    unmarshal_event(FormatVersion, EncodedChange, Context);
unmarshal({aux_state, FormatVersion}, EncodedChange, Context) ->
    unmarshal_aux_state(FormatVersion, EncodedChange, Context);
unmarshal(T, V, C) when
    T =:= {args, init} orelse
        T =:= {args, call} orelse
        T =:= {args, repair} orelse
        T =:= {response, call} orelse
        T =:= {response, {repair, success}} orelse
        T =:= {response, {repair, failure}}
->
    machinery_mg_schema_generic:unmarshal(T, V, C).

%% Internals

-spec marshal_event(machinery_mg_schema:version(), event(), context()) -> {machinery_msgpack:t(), context()}.

marshal_event(1, TimestampedChange, Context) ->
    ThriftChange = ff_withdrawal_session_codec:marshal(timestamped_change, TimestampedChange),
    Type = {struct, struct, {fistful_wthd_session_thrift, 'TimestampedChange'}},
    {{bin, ff_proto_utils:serialize(Type, ThriftChange)}, Context}.

-spec unmarshal_event(machinery_mg_schema:version(), machinery_msgpack:t(), context()) -> {event(), context()}.
unmarshal_event(1, EncodedChange, Context) ->
    {bin, EncodedThriftChange} = EncodedChange,
    Type = {struct, struct, {fistful_wthd_session_thrift, 'TimestampedChange'}},
    ThriftChange = ff_proto_utils:deserialize(Type, EncodedThriftChange),
    {ff_withdrawal_session_codec:unmarshal(timestamped_change, ThriftChange), Context}.

-spec unmarshal_aux_state(machinery_mg_schema:version(), machinery_msgpack:t(), context()) -> {aux_state(), context()}.
unmarshal_aux_state(undefined = Version, EncodedAuxState, Context0) ->
    machinery_mg_schema_generic:unmarshal({aux_state, Version}, EncodedAuxState, Context0).
