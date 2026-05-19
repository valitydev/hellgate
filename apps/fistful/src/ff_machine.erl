%%%
%%% Generic machine
%%%
%%% TODOs
%%%
%%%  - Split ctx and time tracking into different machine layers.
%%%

-module(ff_machine).

-type ctx() :: ff_entity_context:context().
-type range() :: machinery:range().
-type id() :: machinery:id().
-type namespace() :: machinery:namespace().
-type timestamp() :: machinery:timestamp().

-type st(Model) :: #{
    model := Model,
    ctx := ctx(),
    times => {timestamp(), timestamp()}
}.

-type timestamped_event(T) ::
    {ev, timestamp(), T}.

-type auxst() :: #{ctx := ctx()}.

-type machine(T) ::
    machinery:machine(timestamped_event(T), auxst()).

-type result(T) ::
    machinery:result(timestamped_event(T), auxst()).

-type migrate_params() :: #{
    ctx => ctx(),
    timestamp => timestamp(),
    id => id()
}.

-export_type([st/1]).
-export_type([machine/1]).
-export_type([result/1]).
-export_type([timestamped_event/1]).
-export_type([auxst/0]).
-export_type([migrate_params/0]).

%% Accessors

-export([model/1]).
-export([ctx/1]).
-export([created/1]).
-export([updated/1]).

%% API

-export([get/3]).
-export([get/4]).
-export([trace/2]).

-export([collapse/2]).
-export([history/4]).

-export([emit_event/1]).
-export([emit_events/1]).

%% Machinery helpers

-export([init/4]).
-export([process_timeout/3]).
-export([process_call/4]).
-export([process_repair/4]).
-export([process_notification/4]).

%% Model callbacks

-callback init(machinery:args(_)) -> [event()].

-callback apply_event(event(), model()) -> model().

-callback maybe_migrate(event(), migrate_params()) -> event().

-callback process_call(machinery:args(_), st()) -> {machinery:response(_), [event()]}.

-callback process_repair(machinery:args(_), st()) ->
    {ok, machinery:response(_), [event()]} | {error, machinery:error(_)}.

-callback process_timeout(st()) -> [event()].

-optional_callbacks([maybe_migrate/2]).

%% Pipeline helpers

-import(ff_pipeline, [do/1, unwrap/1]).

%% Internal types

-type model() :: any().
-type event() :: any().
-type st() :: st(model()).
-type machine() :: machine(model()).
-type history() :: [machinery:event(timestamped_event(event()))].

%%

-define(EPOCH_DIFF, 62167219200).

-spec model(st(Model)) -> Model.
-spec ctx(st(_)) -> ctx().
-spec created(st(_)) -> timestamp() | undefined.
-spec updated(st(_)) -> timestamp() | undefined.

model(#{model := V}) ->
    V.

ctx(#{ctx := V}) ->
    V.

created(St) ->
    erlang:element(1, times(St)).

updated(St) ->
    erlang:element(2, times(St)).

times(St) ->
    genlib_map:get(times, St, {undefined, undefined}).

%%

-spec get(module(), namespace(), id()) ->
    {ok, st()}
    | {error, notfound}.
get(Mod, NS, Ref) ->
    get(Mod, NS, Ref, {undefined, undefined, forward}).

-spec get(module(), namespace(), id(), range()) ->
    {ok, st()}
    | {error, notfound}.
get(Mod, NS, ID, Range) ->
    do(fun() ->
        Machine = unwrap(machinery:get(NS, ID, Range, fistful:backend(NS))),
        collapse(Mod, Machine)
    end).

-spec trace(namespace(), id()) -> _.
trace(NS, ID) ->
    maybe
        {ok, MachineTrace} ?= machinery:trace(NS, ID, fistful:backend(NS)),
        Trace = unmarshal_trace(MachineTrace),
        {ok, Trace}
    else
        {error, _} = Error ->
            Error
    end.

unmarshal_trace(MachineTrace) ->
    lists:map(fun(TraceUnit) -> unmarshal_trace_unit(TraceUnit) end, MachineTrace).

unmarshal_trace_unit(TraceUnit) ->
    MachineArgs = maps:get(args, TraceUnit, undefined),
    MachineEvents = maps:get(events, TraceUnit, []),
    OtelTraceID = extract_trace_id(TraceUnit),
    Error = extract_error(TraceUnit),
    maps:merge(
        maps:without([response, context], TraceUnit),
        #{
            args => json_compatible_value(MachineArgs),
            events => unmarshal_machine_events(MachineEvents),
            otel_trace_id => OtelTraceID,
            error => Error
        }
    ).

extract_trace_id(#{context := #{<<"otel">> := [OtelTraceID | _]}}) ->
    OtelTraceID;
extract_trace_id(_) ->
    null.

extract_error(#{response := {error, Reason}}) ->
    %% unification with hellgate
    unicode:characters_to_binary(io_lib:format("~p", [Reason]));
extract_error(_) ->
    null.

json_compatible_value([]) ->
    [];
json_compatible_value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true ->
            unicode:characters_to_binary(V);
        false ->
            [json_compatible_value(E) || E <- V]
    end;
json_compatible_value(V) when is_map(V) ->
    maps:fold(
        fun(K, Val, Acc) ->
            Acc#{json_compatible_key(K) => json_compatible_value(Val)}
        end,
        #{},
        V
    );
%% tagged tuple - special case or not???
json_compatible_value({K, V}) when is_atom(K) ->
    #{K => json_compatible_value(V)};
json_compatible_value(V) when is_tuple(V) ->
    %% MAYBE ???
    %% Elements = [json_compatible_value(E) || E <- tuple_to_list(V)],
    %% #{<<"__tuple__">> => Elements};
    [json_compatible_value(E) || E <- tuple_to_list(V)];
json_compatible_value(true) ->
    true;
json_compatible_value(false) ->
    false;
json_compatible_value(null) ->
    null;
json_compatible_value(undefined) ->
    null;
json_compatible_value(V) when is_atom(V) ->
    erlang:atom_to_binary(V);
json_compatible_value(V) when is_integer(V) ->
    V;
json_compatible_value(V) when is_float(V) ->
    V;
json_compatible_value(V) when is_binary(V) ->
    try unicode:characters_to_binary(V) of
        Binary when is_binary(Binary) ->
            Binary;
        _ ->
            content(<<"base64">>, base64:encode(V))
    catch
        _:_ ->
            content(<<"base64">>, base64:encode(V))
    end;
%% default for other types (pid() | ref() | function() etc)
json_compatible_value(V) ->
    CompatVal = unicode:characters_to_binary(io_lib:format("~p", [V])),
    content(<<"unknown">>, CompatVal).

json_compatible_key(K) when
    is_atom(K);
    is_integer(K);
    is_float(K)
->
    K;
json_compatible_key(K) when is_list(K) ->
    case io_lib:printable_unicode_list(K) of
        true ->
            unicode:characters_to_binary(K);
        false ->
            unicode:characters_to_binary(io_lib:format("~p", [K]))
    end;
json_compatible_key(K) when is_binary(K) ->
    try unicode:characters_to_binary(K) of
        Binary when is_binary(Binary) ->
            Binary;
        _ ->
            base64:encode(K)
        %% MAYBE ???
        %% unicode:characters_to_binary(io_lib:format("~p", [K]))
    catch
        _:_ ->
            base64:encode(K)
        %% MAYBE ???
        %% unicode:characters_to_binary(io_lib:format("~p", [K]))
    end;
json_compatible_key(K) ->
    unicode:characters_to_binary(io_lib:format("~p", [K])).

content(Type, Payload) ->
    #{
        <<"content_type">> => Type,
        <<"content">> => Payload
    }.

unmarshal_machine_events(MachineEvents) ->
    lists:map(
        fun({EventID, _TsExt, {ev, Ts, Body}}) ->
            #{
                event_id => EventID,
                event_payload => json_compatible_value(Body),
                event_timestamp => to_unix_microseconds(Ts)
            }
        end,
        MachineEvents
    ).

to_unix_microseconds({{{_Y, _M, _D}, {_H, _Min, _S}} = DateTime, Microsec}) ->
    GregorianSeconds = calendar:datetime_to_gregorian_seconds(DateTime),
    (GregorianSeconds - ?EPOCH_DIFF) * 1000000 + Microsec.

-spec history(module(), namespace(), id(), range()) ->
    {ok, history()}
    | {error, notfound}.
history(Mod, NS, ID, Range) ->
    do(fun() ->
        Machine = unwrap(machinery:get(NS, ID, Range, fistful:backend(NS))),
        #{history := History} = migrate_machine(Mod, Machine),
        History
    end).

-spec collapse(module(), machine()) -> st().
collapse(Mod, Machine) ->
    collapse_(Mod, migrate_machine(Mod, Machine)).

-spec collapse_(module(), machine()) -> st().
collapse_(Mod, #{history := History, aux_state := #{ctx := Ctx}}) ->
    collapse_history(Mod, History, #{ctx => Ctx}).

collapse_history(Mod, History, St0) ->
    lists:foldl(fun(Ev, St) -> merge_event(Mod, Ev, St) end, St0, History).

-spec migrate_history(module(), history(), migrate_params()) -> history().
migrate_history(Mod, History, MigrateParams) ->
    [migrate_event(Mod, Ev, MigrateParams) || Ev <- History].

-spec emit_event(E) -> [timestamped_event(E)].
emit_event(Event) ->
    emit_events([Event]).

-spec emit_events([E]) -> [timestamped_event(E)].
emit_events(Events) ->
    emit_timestamped_events(Events, machinery_time:now()).

emit_timestamped_events(Events, Ts) ->
    [{ev, Ts, Body} || Body <- Events].

merge_event(Mod, {_ID, _Ts, TsEvent}, St0) ->
    {Ev, St1} = merge_timestamped_event(TsEvent, St0),
    Model1 = Mod:apply_event(Ev, maps:get(model, St1, undefined)),
    St1#{model => Model1}.

merge_timestamped_event({ev, Ts, Body}, #{times := {Created, _Updated}} = St) ->
    {Body, St#{times => {Created, Ts}}};
merge_timestamped_event({ev, Ts, Body}, #{} = St) ->
    {Body, St#{times => {Ts, Ts}}}.

-spec migrate_machine(module(), machine()) -> machine().
migrate_machine(Mod, #{history := History} = Machine) ->
    MigrateParams = #{
        ctx => maps:get(ctx, maps:get(aux_state, Machine, #{}), undefined),
        id => maps:get(id, Machine, undefined)
    },
    Machine#{history => migrate_history(Mod, History, MigrateParams)}.

migrate_event(Mod, {ID, Ts, {ev, EventTs, EventBody}} = Event, MigrateParams) ->
    case erlang:function_exported(Mod, maybe_migrate, 2) of
        true ->
            {ID, Ts, {ev, EventTs, Mod:maybe_migrate(EventBody, MigrateParams#{timestamp => EventTs})}};
        false ->
            Event
    end.

%%

-spec init({machinery:args(_), ctx()}, machinery:machine(E, A), module(), _) -> machinery:result(E, A).
init({Args, Ctx}, _Machine, Mod, _) ->
    Events = Mod:init(Args),
    #{
        events => emit_events(Events),
        aux_state => #{ctx => Ctx}
    }.

-spec process_timeout(machinery:machine(E, A), module(), _) -> machinery:result(E, A).
process_timeout(Machine, Mod, _) ->
    Events = Mod:process_timeout(collapse(Mod, Machine)),
    #{
        events => emit_events(Events)
    }.

-spec process_call(machinery:args(_), machinery:machine(E, A), module(), _) ->
    {machinery:response(_), machinery:result(E, A)}.
process_call(Args, Machine, Mod, _) ->
    {Response, Events} = Mod:process_call(Args, collapse(Mod, Machine)),
    {Response, #{
        events => emit_events(Events)
    }}.

-spec process_repair(machinery:args(_), machinery:machine(E, A), module(), _) ->
    {ok, machinery:response(_), machinery:result(E, A)} | {error, machinery:error(_)}.
process_repair(Args, Machine, Mod, _) ->
    case Mod:process_repair(Args, collapse(Mod, Machine)) of
        {ok, Response, Events} ->
            {ok, Response, #{
                events => emit_events(Events)
            }};
        {error, _Reason} = Error ->
            Error
    end.

-spec process_notification(_, machine(_), _, _) -> result(_) | no_return().
process_notification(_Args, _Machine, _HandlerArgs, _Opts) ->
    #{}.
