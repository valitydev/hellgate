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
    _ = proc_span_start(
        WoodySpanId, <<"client ", (atom_to_binary(Service))/binary, ":", (atom_to_binary(Function))/binary>>, #{
            kind => ?SPAN_KIND_CLIENT
        }
    ),
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts);
handle_event(Event = ?EV_SERVICE_RESULT, RpcID = #{span_id := WoodySpanId}, Meta, Opts) ->
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts),
    _ = proc_span_end(WoodySpanId),
    ok;
handle_event(
    Event = ?EV_INVOKE_SERVICE_HANDLER,
    RpcID = #{span_id := WoodySpanId},
    Meta = #{service := Service, function := Function},
    Opts
) ->
    _ = proc_span_start(
        WoodySpanId, <<"server ", (atom_to_binary(Service))/binary, ":", (atom_to_binary(Function))/binary>>, #{
            kind => ?SPAN_KIND_SERVER
        }
    ),
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts);
handle_event(Event = ?EV_SERVICE_HANDLER_RESULT, RpcID = #{span_id := WoodySpanId}, Meta, Opts) ->
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts),
    _ = proc_span_end(WoodySpanId),
    ok;
handle_event(Event, RpcID, Meta, Opts) ->
    scoper_woody_event_handler:handle_event(Event, RpcID, Meta, Opts).

%%

proc_span_start(SpanKey, SpanName, Opts) ->
    Tracer = opentelemetry:get_application_tracer(?MODULE),
    SpanCtx = otel_tracer:set_current_span(otel_tracer:start_span(Tracer, SpanName, Opts)),
    _ = erlang:put({proc_span_ctx, SpanKey}, SpanCtx),
    ok.

proc_span_end(SpanKey) ->
    case erlang:erase({proc_span_ctx, SpanKey}) of
        undefined ->
            ok;
        #span_ctx{} = SpanCtx ->
            _ = otel_tracer:set_current_span(otel_span:end_span(SpanCtx, undefined)),
            ok
    end.
