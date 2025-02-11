-module(hg_hybrid).

-include_lib("mg_proto/include/mg_proto_state_processing_thrift.hrl").

-export([call_automaton/2]).

-spec call_automaton(woody:func(), woody:args()) -> term().
call_automaton('Start' = Func, {NS, ID, _} = Args) ->
    MachineDesc = prepare_descriptor(NS, ID),
    case hg_machine:call_automaton('GetMachine', {MachineDesc}, machinegun) of
        {ok, Machine} ->
            ok = migrate(unmarshal(machine, Machine), unmarshal(descriptor, MachineDesc)),
            {error, exists};
        {error, notfound} ->
            hg_progressor:call_automaton(Func, Args)
    end;
call_automaton(Func, Args) ->
    MachineDesc = extract_descriptor(Args),
    case hg_progressor:call_automaton(Func, Args) of
        {error, notfound} ->
            maybe_retry_call_backend(maybe_migrate_machine(MachineDesc), Func, Args);
        Result ->
            Result
    end.

%% Internal functions

maybe_migrate_machine(MachineDesc) ->
    case hg_machine:call_automaton('GetMachine', {MachineDesc}, machinegun) of
        {error, notfound} = Error ->
            Error;
        {ok, Machine} ->
            migrate(unmarshal(machine, Machine), unmarshal(descriptor, MachineDesc))
    end.

maybe_retry_call_backend(ok, Func, Args) ->
    hg_progressor:call_automaton(Func, Args);
maybe_retry_call_backend({error, _Reason} = Error, _Func, _Args) ->
    erlang:error(Error).

migrate(MigrateArgs, Req0) ->
    Req = Req0#{args => MigrateArgs},
    case progressor:put(Req) of
        {ok, _} ->
            ok;
        {error, <<"process already exists">>} ->
            ok;
        {error, Reason} ->
            {error, {migration_failed, Reason}}
    end.

unmarshal(machine, #mg_stateproc_Machine{
    ns = NS,
    id = ID,
    history = Events,
    status = Status,
    aux_state = AuxState,
    timer = Timestamp
}) ->
    Process = genlib_map:compact(#{
        namespace => unmarshal(atom, NS),
        process_id => unmarshal(string, ID),
        history => maybe_unmarshal({list, {event, ID}}, Events),
        status => unmarshal(status, Status),
        aux_state => maybe_unmarshal(term, AuxState)
    }),
    Action = maybe_unmarshal(action, Timestamp),
    #{
        process => Process,
        action => Action
    };
unmarshal({event, ProcessID}, #mg_stateproc_Event{
    id = EventID,
    created_at = CreatedAt,
    format_version = Ver,
    data = Payload
}) ->
    genlib_map:compact(#{
        process_id => ProcessID,
        event_id => EventID,
        timestamp => unmarshal(timestamp_sec, CreatedAt),
        metadata => unmarshal(metadata, [{<<"format_version">>, Ver}]),
        payload => maybe_unmarshal(term, Payload)
    });
unmarshal(action, Timestamp) ->
    #{set_timer => unmarshal(timestamp_sec, Timestamp)};
unmarshal(metadata, List) ->
    lists:foldl(
        fun
            ({_K, undefined}, Acc) -> Acc;
            ({K, V}, Acc) -> Acc#{K => V}
        end,
        #{},
        List
    );
unmarshal(status, {failed, _}) ->
    <<"error">>;
unmarshal(status, _) ->
    <<"running">>;
unmarshal(timestamp_sec, TimestampBin) when is_binary(TimestampBin) ->
    genlib_rfc3339:parse(TimestampBin, second);
unmarshal({list, T}, List) ->
    lists:map(fun(V) -> unmarshal(T, V) end, List);
unmarshal(string, V) when is_binary(V) ->
    V;
unmarshal(atom, V) when is_binary(V) ->
    erlang:binary_to_atom(V, utf8);
unmarshal(descriptor, #mg_stateproc_MachineDescriptor{ns = NS, ref = {id, ID}}) ->
    #{
        ns => unmarshal(atom, NS),
        id => unmarshal(string, ID)
    };
unmarshal(term, V) ->
    term_to_binary(V).

maybe_unmarshal(_, undefined) ->
    undefined;
maybe_unmarshal(T, V) ->
    unmarshal(T, V).

prepare_descriptor(NS, ID) ->
    prepare_descriptor(NS, ID, #mg_stateproc_HistoryRange{
        direction = forward
    }).

prepare_descriptor(NS, ID, Range) ->
    #mg_stateproc_MachineDescriptor{
        ns = NS,
        ref = {id, ID},
        range = Range
    }.

extract_descriptor({MachineDescriptor}) ->
    MachineDescriptor;
extract_descriptor({MachineDescriptor, _}) ->
    MachineDescriptor.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_MACHINE, #mg_stateproc_Machine{
    ns = <<"invoice">>,
    id = <<"24Dbt7gfCnw">>,
    status = {working, {mg_stateproc_MachineStatusWorking}},
    aux_state = #mg_stateproc_Content{
        format_version = undefined,
        data = {bin, <<>>}
    },
    timer = <<"2025-02-10T16:07:21Z">>,
    history_range = #mg_stateproc_HistoryRange{},
    history = [
        #mg_stateproc_Event{
            id = 1,
            created_at = <<"2025-02-10T16:07:21Z">>,
            format_version = 1,
            data = {bin, <<>>}
        },
        #mg_stateproc_Event{
            id = 2,
            created_at = <<"2025-02-10T16:07:21Z">>,
            format_version = 1,
            data = {bin, <<>>}
        },
        #mg_stateproc_Event{
            id = 3,
            created_at = <<"2025-02-10T16:07:21Z">>,
            format_version = 1,
            data = {bin, <<>>}
        }
    ]
}).

-spec test() -> _.

-spec unmarshal_test() -> _.
unmarshal_test() ->
    Unmarshalled = unmarshal(machine, ?TEST_MACHINE),
    Expected = #{
        process => #{
            process_id => <<"24Dbt7gfCnw">>,
            status => <<"running">>,
            history => [
                #{
                    timestamp => 1739203641,
                    metadata => #{<<"format_version">> => 1},
                    process_id => <<"24Dbt7gfCnw">>,
                    event_id => 1,
                    payload => <<131, 104, 2, 119, 3, 98, 105, 110, 109, 0, 0, 0, 0>>
                },
                #{
                    timestamp => 1739203641,
                    metadata => #{<<"format_version">> => 1},
                    process_id => <<"24Dbt7gfCnw">>,
                    event_id => 2,
                    payload => <<131, 104, 2, 119, 3, 98, 105, 110, 109, 0, 0, 0, 0>>
                },
                #{
                    timestamp => 1739203641,
                    metadata => #{<<"format_version">> => 1},
                    process_id => <<"24Dbt7gfCnw">>,
                    event_id => 3,
                    payload => <<131, 104, 2, 119, 3, 98, 105, 110, 109, 0, 0, 0, 0>>
                }
            ],
            namespace => invoice,
            aux_state =>
                <<131, 104, 3, 119, 20, 109, 103, 95, 115, 116, 97, 116, 101, 112, 114, 111, 99, 95, 67, 111, 110, 116,
                    101, 110, 116, 119, 9, 117, 110, 100, 101, 102, 105, 110, 101, 100, 104, 2, 119, 3, 98, 105, 110,
                    109, 0, 0, 0, 0>>
        },
        action => #{set_timer => 1739203641}
    },
    ?assertEqual(Expected, Unmarshalled).

-endif.
