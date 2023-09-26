-module(hg_woody_event_handler).

-include_lib("opentelemetry_api/include/otel_tracer.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("woody/src/woody_defs.hrl").

-behaviour(woody_event_handler).

-export([handle_event/4]).

-spec handle_event(Event, RpcId, Meta, Opts) -> ok when
    Event :: woody_event_handler:event(),
    RpcId :: woody:rpc_id() | undefined,
    Meta :: woody_event_handler:event_meta(),
    Opts :: woody:options().

handle_event(
    Event = ?EV_CALL_SERVICE,
    RpcID = #{span_id := WoodySpanId},
    Meta = #{service := Service, function := Function},
    Opts
) ->
    SpanName = <<"client ", (atom_to_binary(Service))/binary, ":", (atom_to_binary(Function))/binary>>,
    ok = proc_span_start(WoodySpanId, SpanName, #{kind => ?SPAN_KIND_CLIENT}),
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts);
handle_event(Event = ?EV_SERVICE_RESULT, RpcID = #{span_id := WoodySpanId}, Meta, Opts) ->
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts),
    proc_span_end(WoodySpanId);
handle_event(
    Event = ?EV_INVOKE_SERVICE_HANDLER,
    RpcID = #{span_id := WoodySpanId},
    Meta = #{service := Service, function := Function},
    Opts
) ->
    SpanName = <<"server ", (atom_to_binary(Service))/binary, ":", (atom_to_binary(Function))/binary>>,
    ok = proc_span_start(WoodySpanId, SpanName, #{kind => ?SPAN_KIND_SERVER}),
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts);
handle_event(Event = ?EV_SERVICE_HANDLER_RESULT, RpcID = #{span_id := WoodySpanId}, Meta, Opts) ->
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts),
    proc_span_end(WoodySpanId);
handle_event(Event, RpcID, Meta, Opts) ->
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts).

%%

-define(SPANS_STACK, 'spans_ctx_stack').

proc_span_start(SpanKey, SpanName, Opts) ->
    Tracer = opentelemetry:get_application_tracer(?MODULE),
    Ctx = otel_ctx:get_current(),
    SpanCtx = otel_tracer:start_span(Ctx, Tracer, SpanName, Opts),
    Ctx1 = record_current_span_ctx(SpanKey, SpanCtx, Ctx),
    Ctx2 = otel_tracer:set_current_span(Ctx1, SpanCtx),
    _ = otel_ctx:attach(Ctx2),
    ok.

record_current_span_ctx(Key, SpanCtx, Ctx) ->
    Stack = otel_ctx:get_value(Ctx, ?SPANS_STACK, []),
    otel_ctx:set_value(Ctx, ?SPANS_STACK, [{Key, SpanCtx, otel_tracer:current_span_ctx(Ctx)} | Stack]).

proc_span_end(SpanKey) ->
    Ctx = otel_ctx:get_current(),
    Stack = otel_ctx:get_value(Ctx, ?SPANS_STACK, []),
    case lists:keytake(SpanKey, 1, Stack) of
        false ->
            ok;
        {value, {_Key, SpanCtx, ParentSpanCtx}, Stack1} ->
            _ = otel_span:end_span(SpanCtx, undefined),
            Ctx1 = otel_ctx:set_value(Ctx, ?SPANS_STACK, Stack1),
            Ctx2 = otel_tracer:set_current_span(Ctx1, ParentSpanCtx),
            _ = otel_ctx:attach(Ctx2),
            ok
    end.
