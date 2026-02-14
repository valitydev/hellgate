%% @doc
%% Мини-сьют для проверки доставки логов через OTel:
%% logger -> otel_log_handler -> OTLP -> otel-collector -> Loki.
-module(hg_log_delivery_tests_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([logger_otlp_delivery/1]).

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().

-define(LOG_MARKER_PREFIX, "HG_LOG_DELIVERY_").
-define(LOKI_HOST, "loki").
-define(LOKI_PORT, 3100).
-define(DELIVERY_WAIT_MS, 12000).
-define(DELIVERY_ASSERT_TIMEOUT_MS, 90000).
-define(DELIVERY_POLL_INTERVAL_MS, 2000).
-define(LOKI_LOOKBACK_NS, 10 * 60 * 1_000_000_000).

-spec all() -> [test_case_name()].
all() ->
    [logger_otlp_delivery].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    _ = application:ensure_all_started(inets, temporary),
    OldPrimaryLevel = get_primary_logger_level(),
    _ = logger:set_primary_config(level, info),
    {Apps, _Ret} = hg_ct_helper:start_apps([woody, scoper, dmt_client, hg_proto, hellgate]),
    case httpc:request(get, {"http://otel-collector:4318", []}, [{timeout, 3000}], []) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ct:log("WARNING: otel-collector unreachable (~p). OTel path will likely fail.", [Reason])
    end,
    [{loki_url, loki_base_url()}, {apps, Apps}, {old_logger_primary_level, OldPrimaryLevel} | C].

-spec end_per_suite(config()) -> ok.
end_per_suite(C) ->
    _ = [application:stop(App) || App <- hg_ct_helper:cfg(apps, C)],
    case proplists:get_value(old_logger_primary_level, C, undefined) of
        undefined ->
            ok;
        OldLevel ->
            _ = logger:set_primary_config(level, OldLevel),
            ok
    end,
    ok.

get_primary_logger_level() ->
    case logger:get_primary_config() of
        #{level := L} -> L;
        _ -> undefined
    end.

loki_base_url() ->
    Host =
        case os:getenv("LOKI_HOST") of
            false -> ?LOKI_HOST;
            H -> H
        end,
    Port =
        case os:getenv("LOKI_PORT") of
            false -> integer_to_list(?LOKI_PORT);
            P -> P
        end,
    "http://" ++ Host ++ ":" ++ Port.

make_marker() ->
    Rand = base64:encode(crypto:strong_rand_bytes(8)),
    ?LOG_MARKER_PREFIX ++ binary_to_list(Rand).

send_and_wait(MarkerPlain, MarkerLazy) ->
    logger:info("~s", [MarkerPlain]),
    logger:info(fun(Args) -> {"~s", Args} end, [MarkerLazy]),
    timer:sleep(?DELIVERY_WAIT_MS).

-spec query_loki(string(), config()) -> {ok, [binary()]} | {error, term()}.
query_loki(LogQL, C) ->
    BaseUrl = proplists:get_value(loki_url, C),
    EndNs = erlang:system_time(nanosecond),
    StartNs = EndNs - ?LOKI_LOOKBACK_NS,
    Query = [
        {"query", LogQL},
        {"start", integer_to_list(StartNs)},
        {"end", integer_to_list(EndNs)},
        {"limit", "2000"}
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
    Parts = [qs_key(K) ++ "=" ++ qs_value(V) || {K, V} <- KVs],
    string:join(Parts, "&").

qs_key(S) ->
    lists:flatten(percent_encode(ensure_binary(S))).

qs_value(S) ->
    lists:flatten(percent_encode(ensure_binary(S))).

logql_quote(S) ->
    Bin = ensure_binary(S),
    Escaped = binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
    <<"\"", (binary:replace(Escaped, <<"\"">>, <<"\\\"">>, [global]))/binary, "\"">>.

build_marker_query(Selector, Marker) ->
    Selector ++ " |= " ++ binary_to_list(logql_quote(Marker)).

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
        Decoded = jsx:decode(BodyBin, [return_maps]),
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

-spec logger_otlp_delivery(config()) -> ok.
logger_otlp_delivery(C) ->
    MarkerPlain = make_marker() ++ "_PLAIN",
    MarkerLazy = make_marker() ++ "_LAZY",
    send_and_wait(MarkerPlain, MarkerLazy),
    assert_delivery(MarkerPlain, C, "logger plain"),
    assert_delivery(MarkerLazy, C, "logger lazy format").

-spec assert_delivery(string(), config(), string()) -> ok.
assert_delivery(Marker, C, PathDesc) ->
    case query_loki("{exporter=\"OTLP\"}", C) of
        {error, {failed_connect, _}} ->
            ct:log(
                "Loki unreachable. Run with: "
                "docker compose -f compose.yaml -f compose.tracing.yaml run testrunner "
                "rebar3 ct --dir=apps/hellgate/test --suite=hg_log_delivery_tests_SUITE"
            ),
            throw({skip, "Loki not available"});
        _ ->
            ok
    end,
    DeadlineMs = erlang:monotonic_time(millisecond) + ?DELIVERY_ASSERT_TIMEOUT_MS,
    case wait_marker_delivery(Marker, C, DeadlineMs, undefined) of
        {ok, QueryUsed} ->
            ct:log("Path OTel: found marker ~s via query ~s", [Marker, QueryUsed]),
            ok;
        {error, LastErr} ->
            case LastErr of
                undefined ->
                    ct:fail("~s: marker ~s not found via any OTel query", [PathDesc, Marker]);
                _ ->
                    ct:fail("~s: marker ~s not found via any OTel query (last_error=~p)", [PathDesc, Marker, LastErr])
            end
    end.

wait_marker_delivery(Marker, C, DeadlineMs, LastErr) ->
    case try_otel_queries(Marker, C) of
        {ok, QueryUsed} ->
            {ok, QueryUsed};
        {error, Err} ->
            case erlang:monotonic_time(millisecond) >= DeadlineMs of
                true ->
                    {error, pick_last_error(Err, LastErr)};
                false ->
                    timer:sleep(?DELIVERY_POLL_INTERVAL_MS),
                    wait_marker_delivery(Marker, C, DeadlineMs, pick_last_error(Err, LastErr))
            end
    end.

pick_last_error(undefined, LastErr) ->
    LastErr;
pick_last_error(Err, _LastErr) ->
    Err.

try_otel_queries(Marker, C) ->
    Selectors = [
        "{exporter=\"OTLP\", service_name=\"hellgate\"}",
        "{exporter=~\"(?i)otlp\"}",
        "{service_name=\"hellgate\"}",
        "{job=~\".+\"}"
    ],
    try_selectors(Selectors, Marker, C, undefined).

try_selectors([], _Marker, _C, LastErr) ->
    {error, LastErr};
try_selectors([Selector | Rest], Marker, C, LastErr) ->
    case query_selector_for_marker(Selector, Marker, C) of
        {ok, QueryUsed} ->
            {ok, QueryUsed};
        {error, Err} ->
            try_selectors(Rest, Marker, C, pick_last_error(Err, LastErr))
    end.

query_selector_for_marker(Selector, Marker, C) ->
    MarkerQuery = build_marker_query(Selector, Marker),
    case query_loki(MarkerQuery, C) of
        {ok, Lines} ->
            case otel_lines_contain_marker(Lines, Marker) of
                true -> {ok, MarkerQuery};
                false -> query_selector_without_marker_filter(Selector, Marker, C)
            end;
        {error, {http_error, 400, _}} ->
            query_selector_without_marker_filter(Selector, Marker, C);
        {error, Err} ->
            case query_selector_without_marker_filter(Selector, Marker, C) of
                {error, undefined} -> {error, Err};
                Other -> Other
            end
    end.

query_selector_without_marker_filter(Selector, Marker, C) ->
    case query_loki(Selector, C) of
        {ok, Lines} ->
            case otel_lines_contain_marker(Lines, Marker) of
                true -> {ok, Selector};
                false -> {error, undefined}
            end;
        {error, {http_error, 400, _}} ->
            {error, undefined};
        {error, Err} ->
            {error, Err}
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
        Decoded = jsx:decode(BodyBin, [return_maps]),
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
    try iolist_to_binary(Body) of
        Bin ->
            Bin
    catch
        _:_ ->
            unicode:characters_to_binary(io_lib:format("~tp", [Body]))
    end;
body_to_binary(Body) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Body])).
