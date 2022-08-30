-module(hg_container).

-type key() :: term().
-type value() :: term().

-export_type([key/0]).
-export_type([value/0]).

%% API

-export([bind/2]).
-export([maybe_bind/2]).
-export([update/2]).
-export([maybe_update/2]).

-export([maybe_inject/1]).
-export([inject/1]).

-export([unbind/1]).

%% Internal types

-type wrapped_value() :: #{
    value := value()
}.

%% API

-spec bind(key(), value()) -> ok.
bind(Key, Value) ->
    case put(Key, wrap(Value)) of
        undefined ->
            ok;
        _ ->
            %% TODO log warning cause bind we use only onece
            ok
    end.

-spec maybe_bind(key(), value()) -> ok.
maybe_bind(_Key, undefined) ->
    ok;
maybe_bind(Key, Value) ->
    bind(Key, Value).

-spec update(key(), value()) -> ok.
update(Key, Value) ->
    case put(Key, wrap(Value)) of
        undefined ->
            %% TODO log warning cause update we use only after bind
            ok;
        _ ->
            ok
    end.

-spec maybe_update(key(), value()) -> ok.
maybe_update(_Key, undefined) ->
    ok;
maybe_update(Key, Value) ->
    update(Key, Value).

-spec maybe_inject(key()) -> value().
maybe_inject(Key) ->
    get(Key).

-spec inject(key()) -> value().
inject(Key) ->
    case maybe_inject(Key) of
        undefined ->
            %% TODO log error cause we try to inject unbinded value
            undefined;
        Value ->
            unwrap(Value)
    end.

-spec unbind(key()) -> ok.
unbind(Key) ->
    case erase(Key) of
        undefined ->
            %% TODO log warning cause we try to erase unused key
            ok;
        _ ->
            ok
    end.

%% Internal

-spec wrap(value()) -> wrapped_value().
wrap(Value) ->
    #{
        value => Value
    }.

-spec unwrap(wrapped_value()) -> value().
unwrap(#{value := Value}) ->
    Value.
