-module(hg_dummy_limiter).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([new/0]).
-export([get/4]).
-export([hold/3]).
-export([commit/3]).

-type client() :: woody_context:ctx().

-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_version() :: limproto_limiter_thrift:'Version'().
-type limit_change() :: limproto_limiter_thrift:'LimitChange'().
-type limit_context() :: limproto_limiter_thrift:'LimitContext'().
-type clock() :: limproto_limiter_thrift:'Clock'().

%%% API

-spec new() -> client().
new() ->
    woody_context:new().

-spec get(limit_id(), limit_version(), limit_context(), client()) -> woody:result() | no_return().
get(LimitID, Version, Context, Client) ->
    call('GetVersioned', {LimitID, Version, clock(), Context}, Client).

-spec hold(limit_change(), limit_context(), client()) -> woody:result() | no_return().
hold(LimitChange, Context, Client) ->
    call('Hold', {LimitChange, clock(), Context}, Client).

-spec commit(limit_change(), limit_context(), client()) -> woody:result() | no_return().
commit(LimitChange, Context, Client) ->
    call('Commit', {LimitChange, clock(), Context}, Client).

%%% Internal functions

-spec call(atom(), tuple(), client()) -> woody:result() | no_return().
call(Function, Args, Client) ->
    Call = {{limproto_limiter_thrift, 'Limiter'}, Function, Args},
    Opts = #{
        url => <<"http://limiter:8022/v1/limiter">>,
        event_handler => hg_woody_event_handler,
        transport_opts => #{
            max_connections => 10000
        }
    },
    woody_client:call(Call, Opts, Client).

-spec clock() -> clock().
clock() ->
    {vector, #limiter_VectorClock{state = <<>>}}.
