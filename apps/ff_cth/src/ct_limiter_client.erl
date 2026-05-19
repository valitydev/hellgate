-module(ct_limiter_client).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([get/4]).

-type client() :: woody_context:ctx().

-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_version() :: limproto_limiter_thrift:'Version'().
-type limit_context() :: limproto_limiter_thrift:'LimitContext'().

%%% API

-define(PLACEHOLDER_OPERATION_GET_LIMIT_VALUES, <<"get values">>).

-spec get(limit_id(), limit_version(), limit_context(), client()) -> woody:result() | no_return().
get(LimitID, Version, Context, Client) ->
    LimitRequest = #limiter_LimitRequest{
        operation_id = ?PLACEHOLDER_OPERATION_GET_LIMIT_VALUES,
        limit_changes = [#limiter_LimitChange{id = LimitID, version = Version}]
    },
    case call('GetValues', {LimitRequest, Context}, Client) of
        {ok, [L]} ->
            {ok, L};
        {ok, []} ->
            {exception, #limiter_LimitNotFound{}};
        {exception, _} = Exception ->
            Exception
    end.

%%% Internal functions

-spec call(atom(), tuple(), client()) -> woody:result() | no_return().
call(Function, Args, Client) ->
    Call = {{limproto_limiter_thrift, 'Limiter'}, Function, Args},
    Opts = #{
        url => <<"http://limiter:8022/v1/limiter">>,
        event_handler => ff_woody_event_handler,
        transport_opts => #{
            max_connections => 10000
        }
    },
    woody_client:call(Call, Opts, Client).
