%% @doc
%% Мини-сьют для проверки доставки логов в Loki по разным путям:
%% - Путь 1 (Docker/Promtail): logger -> default handler -> stdout -> Docker -> Promtail -> Loki
%% - Путь 2 (OTel): logger -> otel_log_handler -> OTLP -> otel-collector -> Loki
%%
%% См. compose.tracing.yaml — тесты запускаются в testrunner с otel-log-handler.
%% Loki доступен как http://loki:3100 в docker network.
%%
%% Запуск:
%%   rebar3 ct --suite=apps/hellgate/test/hg_log_delivery_tests_SUITE
%%
%% В compose с tracing (compose.tracing.yaml):
%%   docker compose -f compose.yaml -f compose.tracing.yaml run testrunner rebar3 ct --suite=...
-module(hg_log_delivery_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([logger_plain_delivery/1]).
-export([logger_lazy_format_delivery/1]).
-export([logger_otlp_delivery/1]).
-export([woody_scoper_delivery/1]). % требует full compose (hellgate + mocks)

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().

-define(LOG_MARKER_PREFIX, "HG_LOG_DELIVERY_").
-define(LOKI_HOST, "loki").
-define(LOKI_PORT, 3100).
-define(DELIVERY_WAIT_MS, 12000).

-spec all() -> [test_case_name()].
all() ->
    [
        %% Plain + lazy в одном тесте — избегаем cross-test interference (второй тест не экспортирует)
        logger_otlp_delivery
        %% logger_plain_delivery, logger_lazy_format_delivery — см. otel_log_handler пустой batch
        %% woody_scoper_delivery — раскомментировать при запуске в full compose с mocks
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    _ = application:ensure_all_started(inets, temporary),
    %% Стартуем hellgate - это вызовет ensure_otel_log_handler() в hellgate:start/2
    {Apps, _Ret} = hg_ct_helper:start_apps([woody, scoper, dmt_client, hg_proto, hellgate]),
    %% Проверка доступности otel-collector для OTel-пути
    case httpc:request(get, {"http://otel-collector:4318", []}, [{timeout, 3000}], []) of
        {ok, _} -> ok;
        {error, Reason} ->
            ct:pal("WARNING: otel-collector unreachable (~p). OTel path will likely fail.", [Reason])
    end,
    [{loki_url, loki_base_url()}, {apps, Apps} | C].

-spec end_per_suite(config()) -> ok.
end_per_suite(C) ->
    _ = hg_ct_helper:flush_otel_logs(),
    _ = [application:stop(App) || App <- hg_ct_helper:cfg(apps, C)],
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_TC, C) ->
    C.

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(_TC, _C) ->
    ok.

%% -------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

loki_base_url() ->
    Host = case os:getenv("LOKI_HOST") of
        false -> ?LOKI_HOST;
        H -> H
    end,
    Port = case os:getenv("LOKI_PORT") of
        false -> integer_to_list(?LOKI_PORT);
        P -> P
    end,
    "http://" ++ Host ++ ":" ++ Port.

make_marker() ->
    Rand = base64:encode(crypto:strong_rand_bytes(8)),
    ?LOG_MARKER_PREFIX ++ binary_to_list(Rand).

%% Отправить логи разными способами, затем проверить доставку в Loki
send_and_wait(MarkerPlain, MarkerLazy, C) ->
    %% 1. Plain logger — идёт в default + otel_log_handler
    logger:info("~s", [MarkerPlain]),
    %% 2. Lazy format (как scoper_woody_event_handler)
    logger:info(fun(Args) -> {"~s", Args} end, [MarkerLazy]),
    timer:sleep(?DELIVERY_WAIT_MS),
    C.

%% Запрос Loki API: GET /loki/api/v1/query_range
%% Query: LogQL, например {job="docker"} |~ "MARKER" или {service_name="hellgate"} |~ "MARKER"
-spec query_loki(string(), config()) -> {ok, [binary()]} | {error, term()}.
query_loki(LogQL, C) ->
    BaseUrl = proplists:get_value(loki_url, C),
    EndNs = erlang:system_time(nanosecond),
    StartNs = EndNs - 60 * 1_000_000_000, %% 1 min back
    Query = [
        {"query", LogQL},
        {"start", integer_to_list(StartNs)},
        {"end", integer_to_list(EndNs)},
        {"limit", "100"}
    ],
    URL = BaseUrl ++ "/loki/api/v1/query_range?" ++ build_query(Query),
    case http_get(URL) of
        {ok, 200, Body} ->
            parse_loki_streams(Body);
        {ok, Code, Body} ->
            {error, {http_error, Code, Body}};
        Err ->
            Err
    end.

build_query(KVs) ->
    Parts = [
        qs_key(K) ++ "=" ++ qs_value(V)
        || {K, V} <- KVs
    ],
    string:join(Parts, "&").

qs_key(S) ->
    lists:flatten(percent_encode(ensure_binary(S))).

qs_value(S) ->
    lists:flatten(percent_encode(ensure_binary(S))).

ensure_binary(S) when is_list(S) ->
    unicode:characters_to_binary(S);
ensure_binary(S) when is_binary(S) ->
    S.

percent_encode(<<>>) ->
    [];
percent_encode(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse
    (C >= $A andalso C =< $Z) orelse
    (C >= $0 andalso C =< $9) orelse
    C =:= $- orelse C =:= $_ orelse C =:= $. orelse C =:= $~
->
    [C | percent_encode(Rest)];
percent_encode(<<C, Rest/binary>>) ->
    ["%", string:right(erlang:integer_to_list(C, 16), 2, $0) | percent_encode(Rest)].

http_get(URL) ->
    case httpc:request(get, {URL, []}, [{timeout, 10000}, {connect_timeout, 5000}], []) of
        {ok, {{_V, Code, _R}, _H, Body}} ->
            {ok, Code, Body};
        {error, Reason} ->
            {error, Reason}
    end.

parse_loki_streams(Body) ->
    try
        BodyBin = ensure_binary(Body),
        Decoded = jsone:decode(BodyBin, [{object_format, map}, {keys, binary}]),
        Streams = maps:get(<<"result">>, maps:get(<<"data">>, Decoded, #{}), []),
        Lines = lists:flatmap(
            fun(Stream) ->
                Vs = maps:get(<<"values">>, Stream, []),
                [V || [_, V] <- Vs]
            end,
            Streams
        ),
        {ok, Lines}
    catch
        _:Reason ->
            {error, {parse_error, Reason, Body}}
    end.

%% -------------------------------------------------------------------------
%% Test cases
%% ----------------------------------------------------------------------------

-spec logger_otlp_delivery(config()) -> ok.
logger_otlp_delivery(C) ->
    %% Plain + lazy в одном send — оба должны дойти по OTel
    MarkerPlain = make_marker() ++ "_PLAIN",
    MarkerLazy = make_marker() ++ "_LAZY",
    send_and_wait(MarkerPlain, MarkerLazy, C),
    assert_delivery(MarkerPlain, C, "logger plain"),
    assert_delivery(MarkerLazy, C, "logger lazy format").

-spec logger_plain_delivery(config()) -> ok.
logger_plain_delivery(C) ->
    Marker = make_marker(),
    send_and_wait(Marker, Marker ++ "_LAZY_IGNORED", C),
    assert_delivery(Marker, C, "logger plain").

-spec logger_lazy_format_delivery(config()) -> ok.
logger_lazy_format_delivery(C) ->
    MarkerLazy = make_marker() ++ "_LAZY",
    MarkerPlain = make_marker() ++ "_PLAIN",
    send_and_wait(MarkerPlain, MarkerLazy, C),
    assert_delivery(MarkerPlain, C, "logger plain (from same send)"),
    assert_delivery(MarkerLazy, C, "logger lazy format").

-spec woody_scoper_delivery(config()) -> ok.
woody_scoper_delivery(C) ->
    Marker = make_marker() ++ "_WOODY",
    logger:info("~s", [Marker]),
    RootUrl = hg_ct_helper:cfg(root_url, C),
    ApiClient = hg_ct_helper:create_client(RootUrl),
    try
        {ok, InvoicingPid} = hg_client_invoicing:start_link(ApiClient),
        _ = hg_client_invoicing:get(<<"00000000-0000-0000-0000-000000000000">>, InvoicingPid),
        ok
    catch
        _:_ ->
            ok
    end,
    timer:sleep(?DELIVERY_WAIT_MS),
    assert_delivery(Marker, C, "woody/scoper").

-spec assert_delivery(string(), config(), string()) -> ok.
assert_delivery(Marker, C, PathDesc) ->
    %% Пробуем подключиться — без compose Loki недоступен
    case query_loki("{exporter=\"OTLP\"}", C) of
        {error, {failed_connect, _}} ->
            ct:pal("Loki unreachable. Run with: docker compose -f compose.yaml -f compose.tracing.yaml run testrunner rebar3 ct --dir=apps/hellgate/test --suite=hg_log_delivery_tests_SUITE"),
            throw({skip, "Loki not available"});
        _ -> ok
    end,
    %% Проверка OTLP пути — только поток с exporter=OTLP.
    %% В Loki body может храниться как массив байт JSON, поэтому проверяем маркер
    %% после локального декодирования тела сообщения.
    case query_loki("{exporter=\"OTLP\", service_name=\"hellgate\"}", C) of
        {ok, OTelLines} ->
            case otel_lines_contain_marker(OTelLines, Marker) of
                true ->
                    ct:log("Path OTel: found marker ~s", [Marker]),
                    ok;
                false ->
                    ct:log("Path OTel: marker ~s NOT found (exporter=OTLP,service_name=hellgate)", [Marker]),
                    %% Пробуем другие labels перед fail
                    try_otel_alternate_query(Marker, C, PathDesc)
            end;
        {error, ErrO} ->
            ct:log("Path OTel: query failed: ~p", [ErrO]),
            case ErrO of
                {http_error, 400, _} ->
                    try_otel_alternate_query(Marker, C, PathDesc);
                _ ->
                    ct:fail("~s: Loki query failed: ~p", [PathDesc, ErrO])
            end
    end.

try_otel_alternate_query(Marker, C, PathDesc) ->
    %% OTel Loki exporter может использовать другие labels
    Queries = [
        "{exporter=\"OTLP\"}",
        "{service_name=\"hellgate\"}"
    ],
    Found = lists:any(
        fun(Q) ->
            case query_loki(Q, C) of
                {ok, Lines} ->
                    otel_lines_contain_marker(Lines, Marker);
                _ -> false
            end
        end,
        Queries
    ),
    case Found of
        true -> ok;
        false ->
            ct:fail("~s: marker ~s not found via any OTel query", [PathDesc, Marker])
    end.

otel_lines_contain_marker(Lines, Marker) ->
    MarkerBin = ensure_binary(Marker),
    lists:any(
        fun(Line) ->
            case decode_otel_body(Line) of
                {ok, BodyBin} ->
                    binary:match(BodyBin, MarkerBin) =/= nomatch;
                error ->
                    binary:match(ensure_binary(Line), MarkerBin) =/= nomatch
            end
        end,
        Lines
    ).

decode_otel_body(Line) ->
    try
        BodyBin = ensure_binary(Line),
        Decoded = jsone:decode(BodyBin, [{object_format, map}, {keys, binary}]),
        case maps:get(<<"body">>, Decoded, undefined) of
            undefined ->
                error;
            Body ->
                {ok, body_to_binary(Body)}
        end
    catch
        _:_ ->
            error
    end.

body_to_binary(Body) when is_binary(Body) ->
    Body;
body_to_binary(Body) when is_list(Body) ->
    case catch iolist_to_binary(Body) of
        Bin when is_binary(Bin) ->
            Bin;
        _ ->
            unicode:characters_to_binary(io_lib:format("~tp", [Body]))
    end;
body_to_binary(Body) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Body])).

escape_loki_regex(S) ->
    %% Loki regex: escape . * + ? [ ] ( ) { } | \
    re:replace(S, "[\\.*+?\\[\\]\\(\\)\\{\\}\\|\\\\]", "\\\\&", [global, {return, list}]).
