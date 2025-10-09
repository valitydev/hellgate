-module(hg_limiter_client).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([get/4]).
-export([hold/3]).
-export([commit/3]).
-export([rollback/3]).

-export([get_values/2]).
-export([get_batch/2]).
-export([hold_batch/2]).
-export([commit_batch/2]).
-export([rollback_batch/2]).

-type limit() :: limproto_limiter_thrift:'Limit'().
-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_version() :: limproto_limiter_thrift:'Version'().
-type limit_change() :: limproto_limiter_thrift:'LimitChange'().
-type context() :: limproto_limiter_thrift:'LimitContext'().
-type clock() :: limproto_limiter_thrift:'Clock'().
-type request() :: limproto_limiter_thrift:'LimitRequest'().

-export_type([limit/0]).
-export_type([limit_id/0]).
-export_type([limit_change/0]).
-export_type([context/0]).
-export_type([clock/0]).

-spec get(limit_id(), limit_version() | undefined, clock(), context()) -> limit() | no_return().
get(LimitID, Version, Clock, Context) ->
    Opts = hg_woody_wrapper:get_service_options(limiter),
    Args = {LimitID, Version, Clock, Context},
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

-spec get_values(request(), context()) -> [limit()] | no_return().
get_values(Request, Context) ->
    {ok, Limits} = call_w_request('GetValues', Request, Context),
    Limits.

-spec get_batch(request(), context()) -> [limit()] | no_return().
get_batch(Request, Context) ->
    {ok, Limits} = call_w_request('GetBatch', Request, Context),
    Limits.

-spec hold_batch(request(), context()) -> [limit()] | no_return().
hold_batch(Request, Context) ->
    {ok, Limits} = call_w_request('HoldBatch', Request, Context),
    Limits.

-spec commit_batch(request(), context()) -> ok | no_return().
commit_batch(Request, Context) ->
    {ok, ok} = call_w_request('CommitBatch', Request, Context),
    ok.

-spec rollback_batch(request(), context()) -> ok | no_return().
rollback_batch(Request, Context) ->
    {ok, ok} = call_w_request('RollbackBatch', Request, Context),
    ok.

%%

call_w_request(Function, Request, Context) ->
    Args = {Request, Context},
    Opts = hg_woody_wrapper:get_service_options(limiter),
    case hg_woody_wrapper:call(limiter, Function, Args, Opts) of
        {exception, #limiter_LimitNotFound{}} ->
            error(not_found);
        {exception, #base_InvalidRequest{errors = Errors}} ->
            error({invalid_request, Errors});
        {exception, Exception} ->
            %% NOTE Uniform handling of more specific exceptions:
            %% LimitChangeNotFound
            %% InvalidOperationCurrency
            %% OperationContextNotSupported
            %% PaymentToolNotSupported
            error(Exception);
        {ok, _} = Result ->
            Result
    end.
