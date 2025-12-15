-module(hg_progressor).

-include_lib("mg_proto/include/mg_proto_state_processing_thrift.hrl").
-include_lib("progressor/include/progressor.hrl").

%% automaton call wrapper
-export([call_automaton/2]).

%% processor call wrapper
-export([process/3]).

%-ifdef(TEST).
-export([cleanup/0]).
%-endif.

-type encoded_args() :: binary().
-type encoded_ctx() :: binary().

-define(EMPTY_CONTENT, #mg_stateproc_Content{data = {bin, <<>>}}).

-spec call_automaton(woody:func(), woody:args()) -> term().
call_automaton('Start', {NS, ID, Args}) ->
    Req = #{
        ns => erlang:binary_to_atom(NS),
        id => ID,
        args => maybe_unmarshal(term, Args),
        context => get_context()
    },
    case progressor:init(Req) of
        {ok, ok} = Result ->
            Result;
        {error, <<"process already exists">>} ->
            {error, exists};
        {error, {exception, _, _} = Exception} ->
            handle_exception(Exception)
    end;
call_automaton('Call', {MachineDesc, Args}) ->
    #mg_stateproc_MachineDescriptor{
        ns = NS,
        ref = {id, ID},
        range = HistoryRange
    } = MachineDesc,
    Req = #{
        ns => erlang:binary_to_atom(NS),
        id => ID,
        args => maybe_unmarshal(term, Args),
        context => get_context(),
        range => unmarshal(history_range, HistoryRange)
    },
    case progressor:call(Req) of
        {ok, _Response} = Ok ->
            Ok;
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, <<"process is error">>} ->
            {error, failed};
        {error, {exception, _, _} = Exception} ->
            handle_exception(Exception)
    end;
call_automaton('GetMachine', {MachineDesc}) ->
    #mg_stateproc_MachineDescriptor{
        ns = NS,
        ref = {id, ID},
        range = HistoryRange
    } = MachineDesc,
    Req = #{
        ns => erlang:binary_to_atom(NS),
        id => ID,
        range => unmarshal(history_range, HistoryRange)
    },
    case progressor:get(Req) of
        {ok, Process} ->
            Machine = marshal(process, Process#{ns => NS}),
            {ok, Machine};
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, {exception, _, _} = Exception} ->
            handle_exception(Exception)
    end;
call_automaton('Repair', {MachineDesc, Args}) ->
    #mg_stateproc_MachineDescriptor{
        ns = NS,
        ref = {id, ID}
    } = MachineDesc,
    Req = #{
        ns => erlang:binary_to_atom(NS),
        id => ID,
        args => maybe_unmarshal(term, Args),
        context => get_context()
    },
    case progressor:repair(Req) of
        {ok, _Response} = Ok ->
            Ok;
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, <<"process is running">>} ->
            {error, working};
        {error, <<"process is error">>} ->
            {error, failed};
        {error, {exception, _, _} = Exception} ->
            handle_exception(Exception)
    end.

%-ifdef(TEST).

-spec cleanup() -> _.
cleanup() ->
    Namespaces = [
        invoice,
        invoice_template,
        customer,
        recurrent_paytools
    ],
    lists:foreach(fun(NsID) -> progressor:cleanup(#{ns => NsID}) end, Namespaces).

%-endif.

%% Processor

-spec process({task_t(), encoded_args(), process()}, hg_woody_service_wrapper:handler_opts(), encoded_ctx()) ->
    process_result().
process({CallType, BinArgs, Process}, #{ns := NS} = Options, BinCtx) ->
    {WoodyContext0, OtelCtx} = decode_rpc_context(BinCtx),
    ok = woody_rpc_helper:attach_otel_context(OtelCtx),
    #{last_event_id := LastEventID} = Process,
    Machine = marshal(process, Process#{ns => NS}),
    Func = marshal(function, CallType),
    Args = marshal(args, {CallType, BinArgs, Machine}),
    WoodyContext = hg_woody_service_wrapper:ensure_woody_deadline_set(WoodyContext0, Options),
    ok = hg_context:save(hg_woody_service_wrapper:create_context(WoodyContext, Options)),
    try
        handle_result(hg_machine:handle_function(Func, {Args}, Options), LastEventID)
    after
        hg_context:cleanup()
    end.

%% Internal functions

decode_rpc_context(<<>>) ->
    woody_rpc_helper:decode_rpc_context(#{});
decode_rpc_context(BinCtx) ->
    woody_rpc_helper:decode_rpc_context(marshal(term, BinCtx)).

handle_result(
    #mg_stateproc_SignalResult{
        change = #'mg_stateproc_MachineStateChange'{
            aux_state = AuxState,
            events = Events
        },
        action = Action
    },
    LastEventID
) ->
    {ok,
        genlib_map:compact(#{
            events => unmarshal(events, {Events, LastEventID}),
            aux_state => maybe_unmarshal(term, AuxState),
            action => maybe_unmarshal(action, Action)
        })};
handle_result(
    #mg_stateproc_CallResult{
        response = Response,
        change = #'mg_stateproc_MachineStateChange'{
            aux_state = AuxState,
            events = Events
        },
        action = Action
    },
    LastEventID
) ->
    {ok,
        genlib_map:compact(#{
            response => Response,
            events => unmarshal(events, {Events, LastEventID}),
            aux_state => maybe_unmarshal(term, AuxState),
            action => maybe_unmarshal(action, Action)
        })};
handle_result(
    #mg_stateproc_RepairResult{
        response = Response,
        change = #'mg_stateproc_MachineStateChange'{
            aux_state = AuxState,
            events = Events
        },
        action = Action
    },
    LastEventID
) ->
    {ok,
        genlib_map:compact(#{
            response => Response,
            events => unmarshal(events, {Events, LastEventID}),
            aux_state => maybe_unmarshal(term, AuxState),
            action => maybe_unmarshal(action, Action)
        })};
handle_result(_Unexpected, _LastEventID) ->
    {error, <<"unexpected result">>}.

-spec handle_exception(_) -> no_return().
handle_exception({exception, Class, Reason}) ->
    erlang:raise(Class, Reason, []).

get_context() ->
    WoodyContext =
        try hg_context:load() of
            Ctx ->
                hg_context:get_woody_context(Ctx)
        catch
            Class:Reason ->
                _ = logger:warning("Failed to load context with error class '~s' and reason: ~p", [Class, Reason]),
                _ = logger:info("Creating empty fallback context"),
                woody_context:new()
        end,
    unmarshal(term, woody_rpc_helper:encode_rpc_context(WoodyContext, otel_ctx:get_current())).

%% Marshalling

maybe_marshal(_, undefined) ->
    undefined;
maybe_marshal(Type, Value) ->
    marshal(Type, Value).

marshal(
    process,
    #{
        ns := NS,
        process_id := ID,
        status := Status,
        history := History
    } = Process
) ->
    Range = maps:get(range, Process, #{}),
    AuxState = maps:get(aux_state, Process, term_to_binary(?EMPTY_CONTENT)),
    Detail = maps:get(detail, Process, undefined),
    MarshalledEvents = lists:map(fun(Ev) -> marshal(event, Ev) end, History),
    #mg_stateproc_Machine{
        ns = NS,
        id = ID,
        history = MarshalledEvents,
        history_range = marshal(history_range, Range),
        status = marshal(status, {Status, Detail}),
        aux_state = maybe_marshal(term, AuxState)
    };
marshal(
    event,
    #{
        event_id := EventID,
        timestamp := Timestamp,
        payload := Payload
    } = Event
) ->
    Meta = maps:get(metadata, Event, #{}),
    #mg_stateproc_Event{
        id = EventID,
        created_at = marshal(timestamp, Timestamp),
        format_version = format_version(Meta),
        data = marshal(term, Payload)
    };
marshal(history_range, Range) ->
    #mg_stateproc_HistoryRange{
        'after' = maps:get(offset, Range, undefined),
        limit = maps:get(limit, Range, undefined),
        direction = maps:get(direction, Range, forward)
    };
marshal(status, {<<"running">>, _Detail}) ->
    {'working', #mg_stateproc_MachineStatusWorking{}};
marshal(status, {<<"error">>, Detail}) ->
    {'failed', #mg_stateproc_MachineStatusFailed{reason = Detail}};
marshal(timestamp, Timestamp) ->
    unicode:characters_to_binary(calendar:system_time_to_rfc3339(Timestamp, [{offset, "Z"}]));
marshal(term, Term) ->
    binary_to_term(Term);
marshal(function, init) ->
    'ProcessSignal';
marshal(function, call) ->
    'ProcessCall';
marshal(function, repair) ->
    'ProcessRepair';
marshal(function, timeout) ->
    'ProcessSignal';
marshal(args, {init, BinArgs, Machine}) ->
    #mg_stateproc_SignalArgs{
        signal = {init, #mg_stateproc_InitSignal{arg = maybe_marshal(term, BinArgs)}},
        machine = Machine
    };
marshal(args, {call, BinArgs, Machine}) ->
    #mg_stateproc_CallArgs{
        arg = maybe_marshal(term, BinArgs),
        machine = Machine
    };
marshal(args, {repair, BinArgs, Machine}) ->
    #mg_stateproc_RepairArgs{
        arg = maybe_marshal(term, BinArgs),
        machine = Machine
    };
marshal(args, {timeout, _BinArgs, Machine}) ->
    #mg_stateproc_SignalArgs{
        signal = {timeout, #mg_stateproc_TimeoutSignal{}},
        machine = Machine
    }.

maybe_unmarshal(_, undefined) ->
    undefined;
maybe_unmarshal(Type, Value) ->
    unmarshal(Type, Value).

unmarshal(events, {undefined, _ID}) ->
    [];
unmarshal(events, {[], _}) ->
    [];
unmarshal(events, {Events, LastEventID}) ->
    Ts = erlang:system_time(second),
    lists:foldl(
        fun(#mg_stateproc_Content{format_version = Ver, data = Payload}, Acc) ->
            PrevID =
                case Acc of
                    [] -> LastEventID;
                    [#{event_id := ID} | _] -> ID
                end,
            [
                genlib_map:compact(#{
                    event_id => PrevID + 1,
                    timestamp => Ts,
                    metadata => #{<<"format_version">> => Ver},
                    payload => unmarshal(term, Payload)
                })
                | Acc
            ]
        end,
        [],
        Events
    );
unmarshal(action, #mg_stateproc_ComplexAction{
    timer = {set_timer, #mg_stateproc_SetTimerAction{timer = Timer}},
    remove = RemoveAction
}) when Timer =/= undefined ->
    genlib_map:compact(#{
        set_timer => unmarshal(timer, Timer),
        remove => maybe_unmarshal(remove_action, RemoveAction)
    });
unmarshal(action, #mg_stateproc_ComplexAction{
    timer = {set_timer, #mg_stateproc_SetTimerAction{timeout = Timeout}},
    remove = RemoveAction
}) when Timeout =/= undefined ->
    genlib_map:compact(#{
        set_timer => erlang:system_time(second) + Timeout,
        remove => maybe_unmarshal(remove_action, RemoveAction)
    });
unmarshal(action, #mg_stateproc_ComplexAction{timer = {unset_timer, #'mg_stateproc_UnsetTimerAction'{}}}) ->
    unset_timer;
unmarshal(action, #mg_stateproc_ComplexAction{remove = #mg_stateproc_RemoveAction{}}) ->
    #{remove => true};
unmarshal(action, #mg_stateproc_ComplexAction{remove = undefined}) ->
    undefined;
unmarshal(timer, {deadline, DateTimeRFC3339}) ->
    calendar:rfc3339_to_system_time(unicode:characters_to_list(DateTimeRFC3339), [{unit, second}]);
unmarshal(timer, {timeout, Timeout}) ->
    erlang:system_time(second) + Timeout;
unmarshal(term, Term) ->
    erlang:term_to_binary(Term);
unmarshal(remove_action, #mg_stateproc_RemoveAction{}) ->
    true;
unmarshal(history_range, undefined) ->
    #{};
unmarshal(history_range, #mg_stateproc_HistoryRange{'after' = Offset, limit = Limit, direction = Direction}) ->
    genlib_map:compact(#{
        offset => Offset,
        limit => Limit,
        direction => Direction
    }).

format_version(#{<<"format_version">> := Version}) ->
    Version;
format_version(_) ->
    undefined.
