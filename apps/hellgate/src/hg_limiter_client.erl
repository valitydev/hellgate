-module(hg_limiter_client).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([get/4]).
-export([hold/3]).
-export([commit/3]).
-export([rollback/3]).

-type limit() :: limproto_limiter_thrift:'Limit'().
-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_version() :: dmsl_domain_thrift:'DataRevision'().
-type limit_change() :: limproto_limiter_thrift:'LimitChange'().
-type context() :: limproto_limiter_thrift:'LimitContext'().
-type clock() :: limproto_limiter_thrift:'Clock'().

-export_type([limit/0]).
-export_type([limit_id/0]).
-export_type([limit_change/0]).
-export_type([context/0]).
-export_type([clock/0]).

-spec get(limit_id(), limit_version(), clock(), context()) -> limit() | no_return().
get(LimitID, Version, Clock, Context) ->
    Args = {LimitID, Version, Clock, Context},
    Opts = hg_woody_wrapper:get_service_options(limiter),
    case hg_woody_wrapper:call(limiter, 'GetVersioned', Args, Opts) of
        {ok, Limit} ->
            Limit;
        {exception, #limiter_LimitNotFound{}} ->
            error({not_found, LimitID});
        {exception, #base_InvalidRequest{errors = Errors}} ->
            error({invalid_request, Errors})
    end.

-spec hold(limit_change(), clock(), context()) -> clock() | no_return().
hold(LimitChange, Clock, Context) ->
    Opts = hg_woody_wrapper:get_service_options(limiter),
    Args = {LimitChange, Clock, Context},
    case hg_woody_wrapper:call(limiter, 'Hold', Args, Opts) of
        {ok, ClockUpdated} ->
            ClockUpdated;
        {exception, Exception} ->
            error(Exception)
    end.

-spec commit(limit_change(), clock(), context()) -> clock() | no_return().
commit(LimitChange, Clock, Context) ->
    Opts = hg_woody_wrapper:get_service_options(limiter),
    Args = {LimitChange, Clock, Context},
    case hg_woody_wrapper:call(limiter, 'Commit', Args, Opts) of
        {ok, ClockUpdated} ->
            ClockUpdated;
        {exception, Exception} ->
            error(Exception)
    end.

-spec rollback(limit_change(), clock(), context()) -> clock() | no_return().
rollback(LimitChange, Clock, Context) ->
    Opts = hg_woody_wrapper:get_service_options(limiter),
    Args = {LimitChange, Clock, Context},
    case hg_woody_wrapper:call(limiter, 'Rollback', Args, Opts) of
        {ok, ClockUpdated} ->
            ClockUpdated;
        {exception, Exception} ->
            error(Exception)
    end.
