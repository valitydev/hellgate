-module(hg_submachine).

%% Types
-type id() :: binary().
-type name() :: atom().
-type handler() :: module().
-type func() :: atom().

-type submachine_action_desc() :: #{
    handler := handler(),
    func := func()
}.

-type submachine_event_action_desc() :: #{
    event_name := name(),
    action_or_submachine := submachine_action_desc() | submachine_desc()
}.

-type submachine_step_desc() :: #{
    name := name(),
    action_or_submachine := submachine_action_desc() | submachine_desc(),
    on_event => list(submachine_event_action_desc())
}.

-type submachine_desc() :: #{
    handler := handler(),
    steps := list(submachine_step_desc())
}.

-type submachine_step() :: #{
    name := name(),
    action := submachine_action_desc(),
    wrap := [name()]
}.

%% Some generic type that would be in proto
-type submachine() :: dmsl_domain_thrift:'Submachine'().
-type activity() :: atom().

-type process_change() :: any().
-type process_result() :: #{
    changes => [process_change()],
    action => hg_machine_action:t(),
    response => ok | term()
}.

-export_type([submachine_action_desc/0]).
-export_type([submachine_event_action_desc/0]).
-export_type([submachine_step_desc/0]).
-export_type([submachine_desc/0]).
-export_type([submachine_step/0]).
-export_type([submachine/0]).
-export_type([activity/0]).
-export_type([process_result/0]).

%% API
-export([create/2]).
-export([get_handler_for/2]).

%% Machine callbacks

-behaviour(hg_machine).

-export([namespace/0]). %% get it from machine modules

-export([init/3]).
-export([process_signal/3]).
-export([process_call/3]).
-export([process_repair/3]).

%% Submachine behaviour callbacks
-callback make_submachine_desc() ->
    submachine_desc().

-callback create(_) ->
    {ok, submachine()}
    | {error, create_error()}.

-callback deduce_activity(submachine()) ->
    submachine_step().

-callback apply_event(_, submachine()) ->
    submachine().

%% API
-spec create(handler(), params()) -> ok | {error, Reason}.
create(Handler, Params) ->
    case Handler:create(Params) of,
        {ok, Submachine} ->
            case hg_machine:start(Handler:namespace(), ID, marshal_submachine(Submachine)) of
                {ok, _} -> ok;
                {error, exists} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec get_handler_for(activity(), submachine_desc()) -> {ok, handler()} | {error, not_found}.
get_handler_for(Activity, Desc) ->
    ok.

%% Machine callback
-spec init(binary(), handler(), hg_machine:machine()) -> hg_machine:result().
init(_Data, _Handler, _Machine) ->
    handle_result(#{action => hg_machine_action:instant()}).

-spec process_signal(hg_machine:signal(), handler(), hg_machine:machine()) -> hg_machine:result().
process_signal(Signal, Handler, #{history := History}) ->
    SubmachineDesc = Handler:make_submachine_desc(),
    State = collapse_history(History, SubmachineDesc),
    Activity = get_next_step(State, SubmachineDesc),
    handle_result(Handler:process_signal(Activity, Signal, State)).

-spec process_call(call(), handler(), hg_machine:machine()) -> {hg_machine:response(), hg_machine:result()}.
process_call(Call, Handler, #{history := History}) ->
    SubmachineDesc = Handler:make_submachine_desc(),
    State = collapse_history(History, SubmachineDesc),
    Activity = get_next_step(State, SubmachineDesc),
    handle_result(Handler:process_call(Activity, Call, State)).

-spec process_repair(hg_machine:args(), handler(), hg_machine:machine()) -> hg_machine:result() | no_return().
process_repair(Args, Handler, #{history := History}) ->
    SubmachineDesc = Handler:make_submachine_desc(),
    State = collapse_history(History, SubmachineDesc),
    Activity = get_next_step(State, SubmachineDesc),
    handle_result(Handler:process_repair(Activity, Args, State)).

handle_result(#{} = Result) ->
    MachineResult = genlib_map:compact(#{
        events => maps:get(changes, Result, undefined),
        action => maps:get(action, Result, undefined),
    }),
    case maps:get(response, Result, undefined) of
        undefined ->
            MachineResult;
        ok ->
            {ok, MachineResult};
        Response ->
            {{ok, Response}, MachineResult}
    end.

-spec marshal_submachine(submachine()) -> binary().
marshal_submachine(Submachine) ->
    Type = {struct, struct, {dmsl_domain_thrift, 'Submachine'}},
    hg_proto_utils:serialize(Type, Submachine).

-spec unmarshal_submachine(binary()) -> submachine().
unmarshal_submachine(Bin) ->
    Type = {struct, struct, {dmsl_domain_thrift, 'Submachine'}},
    hg_proto_utils:deserialize(Type, Bin).

%% Events utils

-spec collapse_history([event()], submachine_desc()) -> state().
collapse_history(History, SubmachineDesc) ->
    lists:foldl(
        fun(Ev, {St, SubmachineDesc}) -> apply_event(Ev, St, SubmachineDesc) end,
        {undefined, SubmachineDesc},
        History
    ).

-spec apply_event(event(), state() | undefined, submachine_desc()) -> state().
apply_event(Ev, St, Desc = #{handler := Handler}) ->
    apply_event_(Ev, St).

%% Internals

-spec get_next_step(state(), submachine_desc()) -> submachine_step().
get_next_step(State, Desc = #{handler := Handler}) ->
    NextStep = Handler:get_next_step(State),
    case get_step_handler(NextStep, Desc) of
        {action, Step} ->
            #{name => NextStep, step => Step, wrap => []};
        {submachine, Handler} ->
            SubState = get_substate(NextStep, State),
            Step = #{wrap := Wrap} = get_next_step(SubState, Handler:make_submachine_desc()),
            Step#{wrap => [NextStep | Wrap]};
    end.

%% Helpers
get_step_handler(Step, Desc) ->
    %% traverse Desc and found out that it is sub machine
    {submachine, Handler};
get_step_handler(Step, Desc) ->
    {action, #{}}.

get_substate(Activity, #{Activity := #{active := Active}}) ->
    Active;
get_substate(Activity, _State) ->
    new_index().

new_index() ->
    #{
        submachines => #{},
        inversed_order => []
    }.