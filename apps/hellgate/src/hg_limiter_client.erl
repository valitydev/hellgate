-module(hg_limiter_client).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-export([get_values/2]).
-export([get_batch/2]).
-export([hold_batch/2]).
-export([commit_batch/2]).
-export([rollback_batch/2]).

-type limit() :: limproto_limiter_thrift:'Limit'().
-type limit_id() :: limproto_limiter_thrift:'LimitID'().
-type limit_change() :: limproto_limiter_thrift:'LimitChange'().
-type context() :: limproto_limiter_thrift:'LimitContext'().
-type request() :: limproto_limiter_thrift:'LimitRequest'().

-export_type([limit/0]).
-export_type([limit_id/0]).
-export_type([limit_change/0]).
-export_type([context/0]).

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
