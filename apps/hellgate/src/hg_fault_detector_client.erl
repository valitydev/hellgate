%%% Fault detector interaction

-module(hg_fault_detector_client).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-define(service_config(SW, OTL, PAS), #fault_detector_ServiceConfig{
    sliding_window = SW,
    operation_time_limit = OTL,
    pre_aggregation_size = PAS
}).

-define(operation(OpId, State), #fault_detector_Operation{
    operation_id = OpId,
    state = State
}).

-define(state_start(TimeStamp), #fault_detector_Start{time_start = TimeStamp}).
-define(state_error(TimeStamp), #fault_detector_Error{time_end = TimeStamp}).
-define(state_finish(TimeStamp), #fault_detector_Finish{time_end = TimeStamp}).

-export([register_transaction/4]).

-export([build_config/1]).
-export([build_config/3]).

-export([build_service_id/2]).
-export([build_operation_id/2]).

-export([init_service/2]).

-export([get_statistics/1]).

-export([register_operation/4]).

-type operation_status() :: start | finish | error.
-type service_stats() :: fd_proto_fault_detector_thrift:'ServiceStatistics'().
-type service_id() :: fd_proto_fault_detector_thrift:'ServiceId'().
-type operation_id() :: fd_proto_fault_detector_thrift:'OperationId'().
-type service_config() :: fd_proto_fault_detector_thrift:'ServiceConfig'().
-type sliding_window() :: fd_proto_fault_detector_thrift:'Milliseconds'().
-type operation_time_limit() :: fd_proto_fault_detector_thrift:'Milliseconds'().
-type pre_aggregation_size() :: fd_proto_fault_detector_thrift:'Seconds'() | undefined.

-type id() :: binary() | atom() | number().
-type fd_service_type() ::
    adapter_availability
    | provider_conversion.

map_service_type_to_cfg_key(provider_conversion) -> conversion;
map_service_type_to_cfg_key(adapter_availability) -> availability.

%% API

-spec register_transaction(fd_service_type(), operation_status(), id(), id()) ->
    {ok, registered} | {error, not_found} | {error, any()} | disabled.
register_transaction(ServiceType, Status, ServiceID, OperationID) ->
    ServiceConfig = build_config(ServiceType),
    _ =
        case register_operation(start, ServiceID, OperationID, ServiceConfig) of
            {error, not_found} ->
                _ = init_service(ServiceID, ServiceConfig),
                _ = register_operation(start, ServiceID, OperationID, ServiceConfig);
            Result ->
                Result
        end,
    register_operation(Status, ServiceID, OperationID, ServiceConfig).

-spec build_config(fd_service_type()) -> service_config().
build_config(ServiceType) ->
    FDConfig = genlib_app:env(hellgate, fault_detector, #{}),
    Config = genlib_map:get(map_service_type_to_cfg_key(ServiceType), FDConfig, #{}),
    SlidingWindow = genlib_map:get(sliding_window, Config, 60000),
    OpTimeLimit = genlib_map:get(operation_time_limit, Config, 1200000),
    PreAggrSize = genlib_map:get(pre_aggregation_size, Config, 2),
    build_config(SlidingWindow, OpTimeLimit, PreAggrSize).

-spec build_config(sliding_window(), operation_time_limit(), pre_aggregation_size()) -> service_config().
build_config(SlidingWindow, OpTimeLimit, PreAggrSize) ->
    ?service_config(SlidingWindow, OpTimeLimit, PreAggrSize).

-spec build_service_id(fd_service_type(), id()) -> binary().
build_service_id(ServiceType, ID) ->
    hg_utils:construct_complex_id([<<"hellgate_service">>, genlib:to_binary(ServiceType), genlib:to_binary(ID)]).

-spec build_operation_id(fd_service_type(), [id()]) -> binary().
build_operation_id(ServiceType, IDs) ->
    MappedIDs = [genlib:to_binary(ID) || ID <- IDs],
    hg_utils:construct_complex_id(lists:flatten([<<"hellgate_operation">>, genlib:to_binary(ServiceType), MappedIDs])).

-spec init_service(service_id(), service_config()) -> {ok, initialised} | {error, any()} | disabled.
init_service(ServiceID, ServiceConfig) ->
    call('InitService', {ServiceID, ServiceConfig}).

-spec get_statistics([service_id()]) -> [service_stats()].
get_statistics(ServiceIDs) when is_list(ServiceIDs) ->
    call('GetStatistics', {ServiceIDs}).

-spec register_operation(operation_status(), service_id(), operation_id(), service_config()) ->
    {ok, registered} | {error, not_found} | {error, any()} | disabled.
register_operation(Status, ServiceID, OperationID, ServiceConfig) ->
    OperationState =
        case Status of
            start -> {Status, ?state_start(hg_datetime:format_now())};
            error -> {Status, ?state_error(hg_datetime:format_now())};
            finish -> {Status, ?state_finish(hg_datetime:format_now())}
        end,
    Operation = ?operation(OperationID, OperationState),
    call('RegisterOperation', {ServiceID, Operation, ServiceConfig}).

%% PRIVATE

call(Service, Args) ->
    EnvFDConfig = genlib_app:env(hellgate, fault_detector, #{}),
    Timeout = genlib_map:get(timeout, EnvFDConfig, 4000),
    FDEnabled = genlib_map:get(enabled, EnvFDConfig, true),
    Deadline = woody_deadline:from_timeout(Timeout),
    Opts = hg_woody_wrapper:get_service_options(fault_detector),
    maybe_call(FDEnabled, Service, Args, Opts, Deadline).

maybe_call(true = _FDEnabled, Service, Args, Opts, Deadline) ->
    do_call(Service, Args, Opts, Deadline);
maybe_call(false = _FDEnabled, 'GetStatistics', _Args, _Opts, _Deadline) ->
    [];
maybe_call(false = _FDEnabled, _Service, _Args, _Opts, _Deadline) ->
    disabled.

do_call('InitService', {ServiceID, _ServiceConfig} = Args, Opts, Deadline) ->
    try hg_woody_wrapper:call(fault_detector, 'InitService', Args, Opts, Deadline) of
        {ok, _Result} -> {ok, initialised}
    catch
        error:{woody_error, {_Source, Class, _Details}} = Reason when
            Class =:= resource_unavailable orelse
                Class =:= result_unknown
        ->
            ErrorText = "Unable to init service ~p in fault detector, ~p:~p",
            _ = logger:warning(ErrorText, [ServiceID, error, Reason]),
            {error, Reason};
        error:{woody_error, {_Source, result_unexpected, _Details}} = Reason ->
            ErrorText = "Unable to init service ~p in fault detector, ~p:~p",
            _ = logger:error(ErrorText, [ServiceID, error, Reason]),
            {error, Reason}
    end;
do_call('GetStatistics', {ServiceIDs} = Args, Opts, Deadline) ->
    try hg_woody_wrapper:call(fault_detector, 'GetStatistics', Args, Opts, Deadline) of
        {ok, Stats} -> Stats
    catch
        error:{woody_error, {_Source, Class, _Details}} = Reason when
            Class =:= resource_unavailable orelse
                Class =:= result_unknown
        ->
            String = "Unable to get statistics for services ~p from fault detector, ~p:~p",
            _ = logger:warning(String, [ServiceIDs, error, Reason]),
            [];
        error:{woody_error, {_Source, result_unexpected, _Details}} = Reason ->
            String = "Unable to get statistics for services ~p from fault detector, ~p:~p",
            _ = logger:error(String, [ServiceIDs, error, Reason]),
            []
    end;
do_call('RegisterOperation', {ServiceID, OperationID, _ServiceConfig} = Args, Opts, Deadline) ->
    try hg_woody_wrapper:call(fault_detector, 'RegisterOperation', Args, Opts, Deadline) of
        {ok, _Result} ->
            {ok, registered};
        {exception, #fault_detector_ServiceNotFoundException{}} ->
            {error, not_found}
    catch
        error:{woody_error, {_Source, Class, _Details}} = Reason when
            Class =:= resource_unavailable orelse
                Class =:= result_unknown
        ->
            ErrorText = "Unable to register operation ~p for service ~p in fault detector, ~p:~p",
            _ = logger:warning(ErrorText, [OperationID, ServiceID, error, Reason]),
            {error, Reason};
        error:{woody_error, {_Source, result_unexpected, _Details}} = Reason ->
            ErrorText = "Unable to register operation ~p for service ~p in fault detector, ~p:~p",
            _ = logger:error(ErrorText, [OperationID, ServiceID, error, Reason]),
            {error, Reason}
    end.
