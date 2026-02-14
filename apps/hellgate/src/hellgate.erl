%%% @doc Public API, supervisor and application startup.
%%% @end

-module(hellgate).

-behaviour(supervisor).
-behaviour(application).

%% API
-export([start/0]).
-export([stop/0]).

%% Supervisor callbacks
-export([init/1]).

%% Application callbacks
-export([start/2]).
-export([stop/1]).

% 30 seconds
-define(DEFAULT_HANDLING_TIMEOUT, 30000).

%%
%% API
%%
-spec start() -> {ok, _}.
start() ->
    application:ensure_all_started(?MODULE).

-spec stop() -> ok.
stop() ->
    application:stop(?MODULE).

%% Supervisor callbacks

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    MachineHandlers = [
        hg_invoice,
        hg_invoice_template
    ],
    PartyClient = party_client:create_client(),
    DefaultTimeout = genlib_app:env(hellgate, default_woody_handling_timeout, ?DEFAULT_HANDLING_TIMEOUT),
    Opts = #{
        party_client => PartyClient,
        default_handling_timeout => DefaultTimeout
    },
    {ok,
        {
            #{strategy => one_for_all, intensity => 6, period => 30},
            [
                %% for debugging only
                %% hg_profiler:get_child_spec(),
                party_client:child_spec(party_client, PartyClient),
                hg_machine:get_child_spec(MachineHandlers),
                get_api_child_spec(MachineHandlers, Opts)
            ]
        }}.

get_api_child_spec(MachineHandlers, Opts) ->
    {ok, Ip} = inet:parse_address(genlib_app:env(?MODULE, ip, "::")),
    HealthRoutes =
        construct_health_routes(liveness, genlib_app:env(?MODULE, health_check_liveness, #{})) ++
            construct_health_routes(readiness, genlib_app:env(?MODULE, health_check_readiness, #{})),
    EventHandlerOpts = genlib_app:env(?MODULE, scoper_event_handler_options, #{}),
    PrometeusRoute = get_prometheus_route(),
    woody_server:child_spec(
        ?MODULE,
        #{
            ip => Ip,
            port => genlib_app:env(?MODULE, port, 8022),
            transport_opts => genlib_app:env(?MODULE, transport_opts, #{}),
            protocol_opts => genlib_app:env(?MODULE, protocol_opts, #{}),
            event_handler => {scoper_woody_event_handler, EventHandlerOpts},
            handlers => hg_machine:get_service_handlers(MachineHandlers, Opts) ++
                [
                    construct_service_handler(invoicing, hg_invoice_handler, Opts),
                    construct_service_handler(invoice_templating, hg_invoice_template, Opts),
                    construct_service_handler(proxy_host_provider, hg_proxy_host_provider, Opts)
                ],
            additional_routes => [PrometeusRoute | HealthRoutes],
            shutdown_timeout => genlib_app:env(?MODULE, shutdown_timeout, 0)
        }
    ).

construct_health_routes(liveness, Check) ->
    [erl_health_handle:get_liveness_route(enable_health_logging(Check))];
construct_health_routes(readiness, Check) ->
    [erl_health_handle:get_readiness_route(enable_health_logging(Check))].

enable_health_logging(Check) ->
    EvHandler = {erl_health_event_handler, []},
    maps:map(fun(_, {_, _, _} = V) -> #{runner => V, event_handler => EvHandler} end, Check).

construct_service_handler(Name, Module, Opts) ->
    FullOpts = maps:merge(#{handler => Module}, Opts),
    {Path, Service} = hg_proto:get_service_spec(Name),
    {Path, {Service, {hg_woody_service_wrapper, FullOpts}}}.

-spec get_prometheus_route() -> {iodata(), module(), _Opts :: any()}.
get_prometheus_route() ->
    {"/metrics/[:registry]", prometheus_cowboy2_handler, []}.

%% Application callbacks

-spec start(normal, any()) -> {ok, pid()} | {error, any()}.
start(_StartType, _StartArgs) ->
    case ensure_otel_log_handler() of
        ok ->
            ok = setup_metrics(),
            supervisor:start_link(?MODULE, []);
        {error, Reason} ->
            logger:error("Failed to add otel_logs handler: ~p", [Reason]),
            {error, Reason}
    end.

-spec stop(any()) -> ok.
stop(_State) ->
    ok = flush_otel_logs(),
    ok.

%%

setup_metrics() ->
    ok = woody_ranch_prometheus_collector:setup(),
    ok = woody_hackney_prometheus_collector:setup().

ensure_otel_log_handler() ->
    case logger:get_handler_config(otel_logs) of
        {ok, _} ->
            ok;
        _ ->
            MaxQueue = application:get_env(hellgate, otel_log_max_queue_size, 2048),
            DelayMs = application:get_env(hellgate, otel_log_scheduled_delay_ms, 1000),
            TimeoutMs = application:get_env(hellgate, otel_log_exporting_timeout_ms, 300000),
            LogLevel = application:get_env(hellgate, otel_log_level, info),
            HandlerConfig = #{
                report_cb => fun hg_otel_log_filter:format_otp_report_utf8/1,
                exporter =>
                    {otel_exporter_logs_otlp, #{
                        protocol => http_protobuf,
                        ssl_options => []
                    }},
                max_queue_size => MaxQueue,
                scheduled_delay_ms => DelayMs,
                exporting_timeout_ms => TimeoutMs
            },
            LoggerHandlerConfig = #{
                level => LogLevel,
                filter_default => log,
                filters => [{hg_otel_trace_id_bytes, {fun hg_otel_log_filter:filter/2, undefined}}],
                config => HandlerConfig
            },
            case logger:add_handler(otel_logs, hg_otel_log_handler, LoggerHandlerConfig) of
                ok ->
                    ok;
                {error, {already_exist, _}} ->
                    ok;
                {error, Reason} ->
                    {error, {otel_log_handler_failed, Reason}}
            end
    end.

%% @doc Ждём отправки буферизованных логов перед остановкой.
%% otel_log_handler батчит логи и отправляет по таймеру (scheduled_delay_ms).
%% Явного API для flush у otel_log_handler нет, поэтому ждём один полный цикл
%% батчинга + запас на сетевую отправку (export overhead).
-define(FLUSH_EXPORT_OVERHEAD_MS, 700).
-define(FLUSH_MAX_WAIT_MS, 5000).

flush_otel_logs() ->
    case logger:get_handler_config(otel_logs) of
        {ok, HandlerCfg} ->
            Config = maps:get(config, HandlerCfg, #{}),
            DelayMs = maps:get(
                scheduled_delay_ms,
                Config,
                maps:get(scheduled_delay_ms, HandlerCfg, 1000)
            ),
            _ = logger:info("otel_log_handler_flush"),
            timer:sleep(erlang:min(?FLUSH_MAX_WAIT_MS, DelayMs + ?FLUSH_EXPORT_OVERHEAD_MS)),
            ok;
        _ ->
            ok
    end.
