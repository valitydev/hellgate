-module(hg_profiler).

-behaviour(gen_server).

-export([start_link/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([get_child_spec/0]).
-export([report/0]).

-spec get_child_spec() -> _.
get_child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []}
    }.

-spec report() -> _.
report() ->
    TargetItem = memory,
    MFAs = [
        {prg_worker, init, 1},
        {prg_worker_sidecar, init, 1},
        {epg_pool_wrk, init, 1},
        {epgsql_sock, init, 1}
    ],
    lists:foreach(fun(MFA) -> do_report(MFA, TargetItem) end, MFAs).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================
-spec start_link() -> _.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(_) -> _.
init(_) ->
    erlang:start_timer(60000, self(), report),
    {ok, #{}}.

-spec handle_call(_, _, _) -> _.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(_, _) -> _.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(_, _) -> _.
handle_info({timeout, _TRef, report}, State) ->
    TargetItem = memory,
    MFAs = [
        {prg_worker, init, 1},
        {prg_worker_sidecar, init, 1},
        {epg_pool_wrk, init, 1},
        {epgsql_sock, init, 1}
    ],
    lists:foreach(fun(MFA) -> do_report(MFA, TargetItem) end, MFAs),
    erlang:start_timer(60000, self(), report),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(_, _) -> _.
terminate(_Reason, _State) ->
    ok.

-spec code_change(_, _, _) -> _.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%

do_report(InitialMFA, Item) ->
    {ProcCount, Summary} = lists:foldl(
        fun(P, {Cnt, Sm} = Acc) ->
            try maps:from_list(process_info(P, [dictionary, Item])) of
                #{dictionary := Dict} = Info ->
                    case maps:from_list(Dict) of
                        #{'$initial_call' := InitialMFA} ->
                            Value = maps:get(Item, Info),
                            {Cnt + 1, Sm + Value};
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            catch
                _:_ ->
                    Acc
            end
        end,
        {0, 0},
        processes()
    ),
    %% io:format(user, "MFA: ~p Item: ~p Count: ~p Summary: ~p~n", [InitialMFA, Item, ProcCount, Summary]),
    logger:info("MFA: ~p Item: ~p Count: ~p Summary: ~p", [InitialMFA, Item, ProcCount, Summary]),
    ok.
