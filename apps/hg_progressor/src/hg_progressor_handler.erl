-module(hg_progressor_handler).

-export([handle_function/3]).

-spec handle_function(_, _, _) -> _.
handle_function('ProcessTrace', {NS, ProcessID}, Opts) ->
    case progressor:trace(#{ns => NS, id => ProcessID}) of
        {ok, RawTrace} ->
            Format = maps:get(format, Opts, internal),
            unmarshal_trace(NS, ProcessID, RawTrace, Format);
        {error, _} = Error ->
            Error
    end.

unmarshal_trace(NS, ProcessID, RawTrace, internal = Format) ->
    lists:map(fun(RawTraceUnit) -> unmarshal_trace_unit(NS, ProcessID, RawTraceUnit, Format) end, RawTrace);
unmarshal_trace(NS, ProcessID, RawTrace, jaeger = Format) ->
    Spans = lists:map(fun(RawTraceUnit) -> unmarshal_trace_unit(NS, ProcessID, RawTraceUnit, Format) end, RawTrace),
    #{
        data => [
            #{
                traceID => trace_id(NS, ProcessID),
                spans => Spans,
                processes => #{
                    ProcessID => #{
                        service_name => service_name(NS),
                        tags => []
                    }
                }
            }
        ]
    }.

unmarshal_trace_unit(NS, _ProcessID, #{task_type := TaskType} = TraceUnit, internal = Format) ->
    BinArgs = maps:get(args, TraceUnit, <<>>),
    BinEvents = maps:get(events, TraceUnit, []),
    OtelTraceID = extract_trace_id(TraceUnit),
    Error = extract_error(TraceUnit),
    (maps:without([response, context], TraceUnit))#{
        args => unmarshal_args(NS, TaskType, BinArgs),
        events => unmarshal_events(BinEvents, Format),
        otel_trace_id => OtelTraceID,
        error => Error
    };
unmarshal_trace_unit(NS, ProcessID, #{task_type := TaskType, task_id := TaskID} = TraceUnit, jaeger = Format) ->
    BinArgs = maps:get(args, TraceUnit, <<>>),
    BinEvents = maps:get(events, TraceUnit, []),
    #{
        processID => ProcessID,
        process => #{
            service_name => service_name(NS),
            tags => []
        },
        warnings => [],
        traceId => trace_id(NS, ProcessID),
        span_id => integer_to_binary(TaskID),
        operationName => TaskType,
        startTime => start_time(TraceUnit),
        duration => duration(TraceUnit),
        tags => [
            #{
                key => <<"task.status">>,
                type => <<"string">>,
                value => maps:get(task_status, TraceUnit)
            },
            #{
                key => <<"task.retries">>,
                type => <<"int64">>,
                value => maps:get(retry_attempts, TraceUnit)
            },
            #{
                key => <<"task.input">>,
                type => <<"string">>,
                value => unicode:characters_to_binary(json:encode(unmarshal_args(NS, TaskType, BinArgs)))
            }
        ] ++ error_tag(TraceUnit),
        logs => unmarshal_events(BinEvents, Format)
    }.

unmarshal_args(_, _, <<>>) ->
    <<>>;
unmarshal_args(invoice, <<"init">> = _TaskType, BinArgs) ->
    {bin, B} = binary_to_term(BinArgs),
    UnwrappedArgs = binary_to_term(B),
    Type = {struct, struct, {dmsl_domain_thrift, 'Invoice'}},
    Args = hg_invoice:unmarshal_invoice(UnwrappedArgs),
    #{
        content_type => <<"thrift_call">>,
        content => #{
            call => #{service => 'Invoicing', function => 'Create'},
            params => to_maps(term_to_object(Args, Type))
        }
    };
unmarshal_args(invoice_template, <<"init">> = _TaskType, BinArgs) ->
    {bin, B} = binary_to_term(BinArgs),
    UnwrappedArgs = binary_to_term(B),
    Type = {struct, struct, {dmsl_payproc_thrift, 'InvoiceTemplateCreateParams'}},
    Args = hg_invoice_template:unmarshal_invoice_template_params(UnwrappedArgs),
    #{
        content_type => <<"thrift_call">>,
        content => #{
            call => #{service => 'InvoiceTemplating', function => 'Create'},
            params => to_maps(term_to_object(Args, Type))
        }
    };
unmarshal_args(_, TaskType, BinArgs) when
    TaskType =:= <<"call">>;
    TaskType =:= <<"repair">>;
    TaskType =:= <<"timeout">>
->
    {bin, B} = binary_to_term(BinArgs),
    case binary_to_term(B) of
        {schemaless_call, Args} ->
            maybe_format(Args);
        {thrift_call, ServiceName, FunctionRef, EncodedArgs} ->
            {Service, Function} = FunctionRef,
            {Module, Service} = hg_proto:get_service(ServiceName),
            Type = Module:function_info(Service, Function, params_type),
            Args = hg_proto_utils:deserialize(Type, EncodedArgs),
            #{
                content_type => <<"thrift_call">>,
                content => #{
                    call => #{service => Service, function => Function},
                    params => to_maps(term_to_object(Args, Type))
                }
            };
        Args ->
            maybe_format(Args)
    end.

unmarshal_events(BinEvents, Format) ->
    lists:map(
        fun(#{event_payload := BinPayload} = Event) ->
            {bin, BinChanges} = binary_to_term(BinPayload),
            Type = {struct, union, {dmsl_payproc_thrift, 'EventPayload'}},
            Changes = hg_proto_utils:deserialize(Type, BinChanges),
            Payload = to_maps(term_to_object(Changes, Type)),
            unmarshal_event(Event, Payload, Format)
        end,
        BinEvents
    ).

unmarshal_event(Event, Payload, internal) ->
    Event#{event_payload => Payload};
unmarshal_event(#{event_id := EventID, event_timestamp := Ts}, Payload, jaeger) ->
    #{
        timestamp => Ts,
        fields => [
            #{
                key => <<"event.id">>,
                type => <<"int64">>,
                value => EventID
            },
            #{
                key => <<"event.payload">>,
                type => <<"string">>,
                value => unicode:characters_to_binary(json:encode(Payload))
            }
        ]
    }.

maybe_format(Data) when is_binary(Data) ->
    case is_printable_string(Data) of
        true ->
            #{
                content_type => <<"text">>,
                content => Data
            };
        false ->
            to_maps(term_to_object_content(Data))
    end;
maybe_format(Data) ->
    #{
        content_type => <<"unknown">>,
        content => format(Data)
    }.

format(Data) ->
    unicode:characters_to_binary(io_lib:format("~p", [Data])).

extract_trace_id(#{context := <<>>}) ->
    null;
extract_trace_id(#{context := BinContext}) ->
    try binary_to_term(BinContext) of
        #{<<"otel">> := [TraceID | _]} ->
            TraceID;
        _ ->
            null
    catch
        _:_ ->
            null
    end.

extract_error(#{task_status := <<"error">>, response := {error, ReasonTerm}}) ->
    #{content := Content} = maybe_format(ReasonTerm),
    Content;
extract_error(_) ->
    null.

service_name(invoice) ->
    <<"hellgate_invoice">>;
service_name(invoice_template) ->
    <<"hellgate_invoice_template">>.

trace_id(NS, ProcessID) ->
    NsBin = erlang:atom_to_binary(NS),
    HexList = [io_lib:format("~2.16.0b", [B]) || <<B>> <= <<NsBin/binary, ProcessID/binary>>],
    Hex = lists:flatten(HexList),
    io:format(user, "HEX: ~p~n", [Hex]),
    case length(Hex) of
        Len when Len < 32 -> unicode:characters_to_binary(lists:duplicate(32 - Len, $0) ++ Hex);
        Len when Len > 32 -> unicode:characters_to_binary(string:slice(Hex, 0, 32));
        _ -> unicode:characters_to_binary(Hex)
    end.

start_time(#{running := Ts}) ->
    Ts;
start_time(_) ->
    null.

duration(#{running := Running, finished := Finished}) ->
    Finished - Running;
duration(_) ->
    null.

error_tag(#{task_status := <<"error">>, response := {error, ReasonTerm}}) ->
    #{content := Content} = maybe_format(ReasonTerm),
    [
        #{
            key => <<"task.error">>,
            type => <<"string">>,
            value => Content
        }
    ];
error_tag(_) ->
    [].

-define(is_integer(T), (T == byte orelse T == i8 orelse T == i16 orelse T == i32 orelse T == i64)).
-define(is_number(T), (?is_integer(T) orelse T == double)).
-define(is_scalar(T), (?is_number(T) orelse T == string orelse element(1, T) == enum)).

-spec term_to_object(term(), dmt_thrift:thrift_type()) -> jsone:json_value().
term_to_object(Term, Type) ->
    term_to_object(Term, Type, []).

term_to_object(Term, {list, Type}, Stack) when is_list(Term) ->
    [term_to_object(T, Type, [N | Stack]) || {N, T} <- enumerate(0, Term)];
term_to_object(Term, {set, Type}, Stack) ->
    term_to_object(ordsets:to_list(Term), {list, Type}, Stack);
term_to_object(Term, {map, KType, VType}, Stack) when is_map(Term), ?is_scalar(KType) ->
    maps:fold(
        fun(K, V, A) ->
            [{genlib:to_binary(K), term_to_object(V, VType, [value, V | Stack])} | A]
        end,
        [],
        Term
    );
term_to_object(Term, {map, KType, VType}, Stack) when is_map(Term) ->
    maps:fold(
        fun(K, V, A) ->
            [
                [
                    {<<"key">>, term_to_object(K, KType, [key, K | Stack])},
                    {<<"value">>, term_to_object(V, VType, [value, V | Stack])}
                ]
                | A
            ]
        end,
        [],
        Term
    );
term_to_object(Term, {struct, union, {Mod, Name}}, Stack) when is_atom(Mod), is_atom(Name) ->
    {struct, _, StructDef} = Mod:struct_info(Name),
    union_to_object(Term, StructDef, Stack);
term_to_object(Term, {struct, _, {Mod, Name}}, Stack) when is_atom(Mod), is_atom(Name), is_tuple(Term) ->
    {struct, _, StructDef} = Mod:struct_info(Name),
    struct_to_object(Term, StructDef, Stack);
term_to_object(Term, {struct, struct, List}, Stack) when is_tuple(Term), is_list(List) ->
    Data = lists:zip(List, tuple_to_list(Term)),
    [{atom_to_binary(Name), term_to_object(V, Type, Stack)} || {{_Pos, _, Type, Name, _}, V} <- Data];
term_to_object(Term, {enum, _}, _Stack) when is_atom(Term) ->
    Term;
term_to_object(Term, Type, _Stack) when is_integer(Term), ?is_integer(Type) ->
    Term;
term_to_object(Term, double, _Stack) when is_number(Term) ->
    float(Term);
term_to_object(Term, string, _Stack) when is_binary(Term) ->
    case is_printable_string(Term) of
        true ->
            Term;
        false ->
            term_to_object_content(Term)
    end;
term_to_object(Term, bool, _Stack) when is_boolean(Term) ->
    Term;
term_to_object(Term, Type, _Stack) ->
    erlang:error({badarg, Term, Type}).

union_to_object({Fn, Term}, StructDef, Stack) ->
    {_N, _Req, Type, Fn, _Def} = lists:keyfind(Fn, 4, StructDef),
    [{Fn, term_to_object(Term, Type, [Fn | Stack])}].

struct_to_object(Struct, StructDef, Stack) ->
    [_ | Fields] = tuple_to_list(Struct),
    lists:foldr(
        fun
            ({undefined, _}, A) ->
                A;
            ({Term, {_N, _Req, Type, Fn, _Def}}, A) ->
                [{Fn, term_to_object(Term, Type, [Fn | Stack])} | A]
        end,
        [],
        lists:zip(Fields, StructDef)
    ).

term_to_object_content(Term) ->
    term_to_object_content(<<"base64">>, base64:encode(Term)).

term_to_object_content(CType, Term) ->
    [
        {<<"content_type">>, CType},
        {<<"content">>, Term}
    ].

enumerate(_, []) ->
    [];
enumerate(N, [H | T]) ->
    [{N, H} | enumerate(N + 1, T)].

is_printable_string(V) ->
    try unicode:characters_to_binary(V) of
        B when is_binary(B) ->
            true;
        _ ->
            false
    catch
        _:_ ->
            false
    end.

to_maps(Data) ->
    to_maps(Data, #{}).

to_maps([], Acc) ->
    Acc;
to_maps([{K, [{_, _} | _] = V} | Rest], Acc) ->
    to_maps(Rest, Acc#{K => to_maps(V)});
to_maps([{K, V} | Rest], Acc) when is_list(V) ->
    to_maps(Rest, Acc#{K => lists:map(fun(E) -> to_maps(E) end, V)});
to_maps([{K, V} | Rest], Acc) ->
    to_maps(Rest, Acc#{K => V}).
