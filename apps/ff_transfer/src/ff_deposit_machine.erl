%%%
%%% Deposit machine
%%%

-module(ff_deposit_machine).

-behaviour(machinery).

%% API

-type id() :: machinery:id().
-type change() :: ff_deposit:event().
-type event() :: {integer(), ff_machine:timestamped_event(change())}.
-type st() :: ff_machine:st(deposit()).
-type deposit() :: ff_deposit:deposit_state().
-type external_id() :: id().
-type event_range() :: {After :: non_neg_integer() | undefined, Limit :: non_neg_integer() | undefined}.

-type params() :: ff_deposit:params().
-type create_error() ::
    ff_deposit:create_error()
    | exists.

-type repair_error() :: ff_repair:repair_error().
-type repair_response() :: ff_repair:repair_response().

-type unknown_deposit_error() ::
    {unknown_deposit, id()}.

-export_type([id/0]).
-export_type([st/0]).
-export_type([change/0]).
-export_type([event/0]).
-export_type([params/0]).
-export_type([deposit/0]).
-export_type([event_range/0]).
-export_type([external_id/0]).
-export_type([create_error/0]).
-export_type([repair_error/0]).

%% API

-export([create/2]).
-export([get/1]).
-export([get/2]).
-export([events/2]).
-export([repair/2]).

%% Accessors

-export([deposit/1]).
-export([ctx/1]).

%% Machinery

-export([init/4]).
-export([process_timeout/3]).
-export([process_repair/4]).
-export([process_call/4]).
-export([process_notification/4]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%% Internal types

-type ctx() :: ff_entity_context:context().

-define(NS, 'ff/deposit_v1').

%% API

-spec create(params(), ctx()) ->
    ok
    | {error, ff_deposit:create_error() | exists}.
create(Params, Ctx) ->
    do(fun() ->
        #{id := ID} = Params,
        Events = unwrap(ff_deposit:create(Params)),
        unwrap(machinery:start(?NS, ID, {Events, Ctx}, backend()))
    end).

-spec get(id()) ->
    {ok, st()}
    | {error, unknown_deposit_error()}.
get(ID) ->
    get(ID, {undefined, undefined}).

-spec get(id(), event_range()) ->
    {ok, st()}
    | {error, unknown_deposit_error()}.
get(ID, {After, Limit}) ->
    case ff_machine:get(ff_deposit, ?NS, ID, {After, Limit, forward}) of
        {ok, _Machine} = Result ->
            Result;
        {error, notfound} ->
            {error, {unknown_deposit, ID}}
    end.

-spec events(id(), event_range()) ->
    {ok, [event()]}
    | {error, unknown_deposit_error()}.
events(ID, {After, Limit}) ->
    case ff_machine:history(ff_deposit, ?NS, ID, {After, Limit, forward}) of
        {ok, History} ->
            {ok, [{EventID, TsEv} || {EventID, _, TsEv} <- History]};
        {error, notfound} ->
            {error, {unknown_deposit, ID}}
    end.

-spec repair(id(), ff_repair:scenario()) ->
    {ok, repair_response()} | {error, notfound | working | {failed, repair_error()}}.
repair(ID, Scenario) ->
    machinery:repair(?NS, ID, Scenario, backend()).

%% Accessors

-spec deposit(st()) -> deposit().
deposit(St) ->
    ff_machine:model(St).

-spec ctx(st()) -> ctx().
ctx(St) ->
    ff_machine:ctx(St).

%% Machinery

-type machine() :: ff_machine:machine(event()).
-type result() :: ff_machine:result(event()).
-type handler_opts() :: machinery:handler_opts(_).
-type handler_args() :: machinery:handler_args(_).

-spec init({[event()], ctx()}, machine(), handler_args(), handler_opts()) -> result().
init({Events, Ctx}, #{}, _, _Opts) ->
    #{
        events => ff_machine:emit_events(Events),
        action => continue,
        aux_state => #{ctx => Ctx}
    }.

-spec process_timeout(machine(), handler_args(), handler_opts()) -> result().
process_timeout(Machine, _, _Opts) ->
    St = ff_machine:collapse(ff_deposit, Machine),
    Deposit = deposit(St),
    process_result(ff_deposit:process_transfer(Deposit)).

-spec process_call(_CallArgs, machine(), handler_args(), handler_opts()) -> no_return().
process_call(CallArgs, _Machine, _, _Opts) ->
    erlang:error({unexpected_call, CallArgs}).

-spec process_repair(ff_repair:scenario(), machine(), handler_args(), handler_opts()) ->
    {ok, {repair_response(), result()}} | {error, repair_error()}.
process_repair(Scenario, Machine, _Args, _Opts) ->
    ff_repair:apply_scenario(ff_deposit, Machine, Scenario).

-spec process_notification(_, machine(), handler_args(), handler_opts()) -> result() | no_return().
process_notification(_Args, _Machine, _HandlerArgs, _Opts) ->
    #{}.

%% Internals

backend() ->
    fistful:backend(?NS).

process_result({Action, Events}) ->
    genlib_map:compact(#{
        events => set_events(Events),
        action => Action
    }).

set_events([]) ->
    undefined;
set_events(Events) ->
    ff_machine:emit_events(Events).
