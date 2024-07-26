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

-define(HANDLER, hg_machine).
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
            {error, exists}
    end;
call_automaton('Call', {MachineDesc, Args}) ->
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
    case progressor:call(Req) of
        {ok, _Response} = Ok ->
            Ok;
        {error, <<"process not found">>} ->
            {error, notfound};
        {error, <<"process is error">>} ->
            {error, failed}
    end;
call_automaton('GetMachine', {MachineDesc}) ->
    #mg_stateproc_MachineDescriptor{
        ns = NS,
        ref = {id, ID},
        range = Range
    } = MachineDesc,
    Req = #{
        ns => erlang:binary_to_atom(NS),
        id => ID,
        args => unmarshal(range, Range)
    },
    case progressor:get(Req) of
        {ok, Process} ->
            Machine = marshal(process, Process#{ns => NS}),
            {ok, Machine#mg_stateproc_Machine{history_range = Range}};
        {error, <<"process not found">>} ->
            {error, notfound}
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
            {error, failed}
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
    lists:foreach(fun(NsId) -> progressor:cleanup(#{ns => NsId}) end, Namespaces).

%-endif.

%% Processor

-spec process({task_t(), encoded_args(), process()}, map(), encoded_ctx()) -> process_result().
process({CallType, BinArgs, #{history := History} = Process}, #{ns := NS} = Options, Ctx) ->
    _ = set_context(Ctx),
    {_, LastEventId} = Range = get_range(History),
    Machine = marshal(process, Process#{ns => NS, history_range => Range}),
    Func = marshal(function, CallType),
    Args = marshal(args, {CallType, BinArgs, Machine}),
    handle_result(hg_machine:handle_function(Func, {Args}, Options), LastEventId).

%% Internal functions

handle_result(
    #mg_stateproc_SignalResult{
        change = #'mg_stateproc_MachineStateChange'{
            aux_state = AuxState,
            events = Events
        },
        action = Action
    },
    LastEventId
) ->
    {ok,
        genlib_map:compact(#{
            events => unmarshal(events, {Events, undef_to_zero(LastEventId)}),
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
    LastEventId
) ->
    {ok,
        genlib_map:compact(#{
            response => Response,
            events => unmarshal(events, {Events, undef_to_zero(LastEventId)}),
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
    LastEventId
) ->
    {ok,
        genlib_map:compact(#{
            response => Response,
            events => unmarshal(events, {Events, undef_to_zero(LastEventId)}),
            aux_state => maybe_unmarshal(term, AuxState),
            action => maybe_unmarshal(action, Action)
        })};
handle_result(_Unexpected, _LastEventId) ->
    {error, <<"unexpected result">>}.

get_context() ->
    try hg_context:load() of
        Ctx ->
            unmarshal(term, Ctx)
    catch
        _:_ ->
            unmarshal(term, <<>>)
    end.

set_context(<<>>) ->
    hg_context:save(hg_context:create(#{party_client => #{}}));
set_context(BinContext) ->
    hg_context:save(marshal(term, BinContext)).

get_range([]) ->
    {undefined, undefined};
get_range(History) ->
    lists:foldl(
        fun(#{event_id := Id}, {Min, Max}) ->
            {erlang:min(Id, Min), erlang:max(Id, Max)}
        end,
        {infinity, 0},
        History
    ).

zero_to_undef(0) ->
    undefined;
zero_to_undef(Value) ->
    Value.

undef_to_zero(undefined) ->
    0;
undef_to_zero(Value) ->
    Value.

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
    Range = maps:get(history_range, Process, undefined),
    AuxState = maps:get(aux_state, Process, term_to_binary(?EMPTY_CONTENT)),
    Detail = maps:get(detail, Process, undefined),
    MarshalledEvents = lists:map(fun(Ev) -> marshal(event, Ev) end, History),
    SortedEvents = lists:sort(
        fun(#mg_stateproc_Event{id = Id1}, #mg_stateproc_Event{id = Id2}) ->
            Id1 < Id2
        end,
        MarshalledEvents
    ),
    #mg_stateproc_Machine{
        ns = NS,
        id = ID,
        history = SortedEvents,
        history_range = marshal(history_range, Range),
        status = marshal(status, {Status, Detail}),
        aux_state = maybe_marshal(term, AuxState)
    };
marshal(
    event,
    #{
        event_id := EventId,
        timestamp := Timestamp,
        payload := Payload
    } = Event
) ->
    Meta = maps:get(metadata, Event, #{}),
    #mg_stateproc_Event{
        id = EventId,
        created_at = marshal(timestamp, Timestamp),
        format_version = format_version(Meta),
        data = marshal(term, Payload)
    };
marshal(history_range, {undefined, undefined}) ->
    #mg_stateproc_HistoryRange{direction = forward};
marshal(history_range, undefined) ->
    #mg_stateproc_HistoryRange{direction = forward};
marshal(history_range, {Min, Max}) ->
    Offset = Min - 1,
    Count = Max - Offset,
    #mg_stateproc_HistoryRange{
        'after' = zero_to_undef(Offset),
        limit = Count,
        direction = forward
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

unmarshal(events, {undefined, _Id}) ->
    [];
unmarshal(events, {[], _}) ->
    [];
unmarshal(events, {Events, LastEventId}) ->
    Ts = erlang:system_time(second),
    [#mg_stateproc_Content{format_version = Format, data = Data} | Rest] = Events,
    ConvertedFirst = genlib_map:compact(#{
        event_id => LastEventId + 1,
        timestamp => Ts,
        metadata => #{<<"format_version">> => Format},
        payload => unmarshal(term, Data)
    }),
    lists:foldl(
        fun(#mg_stateproc_Content{format_version = Ver, data = Payload}, [#{event_id := PrevId} | _] = Acc) ->
            [
                genlib_map:compact(#{
                    event_id => PrevId + 1,
                    timestamp => Ts,
                    metadata => #{<<"format_version">> => Ver},
                    payload => unmarshal(term, Payload)
                })
                | Acc
            ]
        end,
        [ConvertedFirst],
        Rest
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
unmarshal(range, undefined) ->
    #{};
%% TODO backward direction
unmarshal(range, #mg_stateproc_HistoryRange{'after' = Offset, limit = Limit}) ->
    genlib_map:compact(#{
        offset => Offset,
        limit => Limit
    }).

format_version(#{<<"format_version">> := Version}) ->
    Version;
format_version(_) ->
    undefined.
