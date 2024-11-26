-module(ff_ct_limiter_client).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([get/4]).

%% TODO Remove obsolete functions
-export([create_config/2]).
-export([get_config/2]).

-type client() :: woody_context:ctx().

-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_version() :: limproto_limiter_thrift:'Version'().
-type limit_context() :: limproto_limiter_thrift:'LimitContext'().
-type clock() :: limproto_limiter_thrift:'Clock'().
-type limit_config_params() :: limproto_config_thrift:'LimitConfigParams'().

%%% API

-define(PLACEHOLDER_OPERATION_GET_LIMIT_VALUES, <<"get values">>).

-spec get(limit_id(), limit_version() | undefined, limit_context(), client()) -> woody:result() | no_return().
get(LimitID, undefined, Context, Client) ->
    call('GetVersioned', {LimitID, undefined, clock(), Context}, Client);
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

-spec create_config(limit_config_params(), client()) -> woody:result() | no_return().
create_config(LimitCreateParams, Client) ->
    call_configurator('Create', {LimitCreateParams}, Client).

-spec get_config(limit_id(), client()) -> woody:result() | no_return().
get_config(LimitConfigID, Client) ->
    call_configurator('Get', {LimitConfigID}, Client).

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

-spec call_configurator(atom(), tuple(), client()) -> woody:result() | no_return().
call_configurator(Function, Args, Client) ->
    Call = {{limproto_configurator_thrift, 'Configurator'}, Function, Args},
    Opts = #{
        url => <<"http://limiter:8022/v1/configurator">>,
        event_handler => ff_woody_event_handler,
        transport_opts => #{
            max_connections => 10000
        }
    },
    woody_client:call(Call, Opts, Client).

-spec clock() -> clock().
clock() ->
    {vector, #limiter_VectorClock{state = <<>>}}.
