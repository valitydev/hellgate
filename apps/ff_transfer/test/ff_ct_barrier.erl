-module(ff_ct_barrier).

-export([start_link/0]).
-export([stop/1]).
-export([enter/2]).
-export([release/1]).

%% Gen Server

-behaviour(gen_server).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).

-type caller() :: {pid(), reference()}.

-type st() :: #{
    blocked := [caller()]
}.

%%

-spec enter(pid(), timeout()) -> ok.
enter(ServerRef, Timeout) ->
    gen_server:call(ServerRef, enter, Timeout).

-spec release(pid()) -> ok.
release(ServerRef) ->
    gen_server:call(ServerRef, release).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec stop(pid()) -> ok.
stop(ServerRef) ->
    proc_lib:stop(ServerRef, normal, 5000).

-spec init(_) -> {ok, st()}.
init(_Args) ->
    {ok, #{blocked => []}}.

-spec handle_call(enter | release, caller(), st()) ->
    {noreply, st()}
    | {reply, ok, st()}.
handle_call(enter, {ClientPid, _} = From, #{blocked := Blocked} = St) ->
    false = lists:any(fun({Pid, _}) -> Pid == ClientPid end, Blocked),
    {noreply, St#{blocked => [From | Blocked]}};
handle_call(release, _From, #{blocked := Blocked} = St) ->
    ok = lists:foreach(fun(Caller) -> gen_server:reply(Caller, ok) end, Blocked),
    {reply, ok, St#{blocked => []}};
handle_call(Call, _From, _St) ->
    error({badcall, Call}).

-spec handle_cast(_Cast, st()) -> no_return().
handle_cast(Cast, _St) ->
    error({badcast, Cast}).
