-module(hg_container).

-type complex_key() :: #{
    module := module_key(),
    function := function_key(),
    key := key()
}.

-type value() :: term().
-type key() :: term().
-type function_key() :: atom().
-type module_key() :: atom().

-export_type([key/0]).
-export_type([value/0]).

%% Assert API

-export([assert/1]).

%% Global API

-export([global_bind_or_update/2]).
-export([global_inject/1]).
-export([global_unbind/1]).

%% API

-export([make_complex_key/3]).

-export([bind_or_update_many/2]).
-export([bind_or_update/2]).

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

%% Assert API

-spec assert(complex_key()) -> ok | no_return().
assert(Key) ->
    case maybe_inject(Key) of
        undefined ->
            erlang:error({inject_assertion_failed, Key, get()});
        _Value ->
            ok
    end.

%% Global API

-spec global_bind_or_update(key(), value()) -> ok.
global_bind_or_update(Key, Value) ->
    bind_or_update(make_global_complex_key(Key), Value).

-spec global_inject(key()) -> value().
global_inject(Key) ->
    inject(make_global_complex_key(Key)).

-spec global_unbind(key()) -> value().
global_unbind(Key) ->
    unbind(make_global_complex_key(Key)).

make_global_complex_key(Key) ->
    make_complex_key(global, global, Key).

%% API

-spec make_complex_key(module_key(), function_key(), key()) -> complex_key().
make_complex_key(Module, Function, Key) ->
    #{module => Module, function => Function, key => Key}.

-spec bind_or_update_many([complex_key()], value()) -> ok.
bind_or_update_many(Keys, Value) ->
    lists:foreach(fun(Key) -> bind_or_update(Key, Value) end, Keys).

-spec bind_or_update(complex_key(), value()) -> ok.
bind_or_update(Key, Value) ->
    case maybe_inject(Key) of
        undefined ->
            bind(Key, Value);
        _OldValue ->
            update(Key, Value)
    end.

-spec bind(complex_key(), value()) -> ok.
bind(Key, Value) ->
    case put(Key, wrap(Value)) of
        undefined ->
            ok;
        _ ->
            _ = logger:warning("The same key: ~p was bound", [Key]),
            ok
    end.

-spec maybe_bind(complex_key(), value()) -> ok.
maybe_bind(_Key, undefined) ->
    ok;
maybe_bind(Key, Value) ->
    bind(Key, Value).

-spec update(complex_key(), value()) -> ok.
update(Key, Value) ->
    case put(Key, wrap(Value)) of
        undefined ->
            _ = logger:warning("The key: ~p wasn't bound before update", [Key]),
            ok;
        _ ->
            ok
    end.

-spec maybe_update(complex_key(), value()) -> ok.
maybe_update(_Key, undefined) ->
    ok;
maybe_update(Key, Value) ->
    update(Key, Value).

-spec maybe_inject(complex_key()) -> value().
maybe_inject(Key) ->
    case get(Key) of
        undefined ->
            undefined;
        Value ->
            unwrap(Value)
    end.

-spec inject(complex_key()) -> value().
inject(Key) ->
    case maybe_inject(Key) of
        undefined ->
            _ = logger:error("Failed to inject unbound key: ~p", [Key]),
            undefined;
        Value ->
            Value
    end.

-spec unbind(complex_key()) -> ok.
unbind(Key) ->
    case erase(Key) of
        undefined ->
            _ = logger:warning("The key: ~p wasn't bound before erase", [Key]),
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
