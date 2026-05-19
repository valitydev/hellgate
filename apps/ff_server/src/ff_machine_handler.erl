-module(ff_machine_handler).

-export([init/2, terminate/3]).
-export([get_routes/0]).

-spec get_routes() -> _.
get_routes() ->
    [
        {"/traces/internal/source_v1/[:process_id]", ?MODULE, #{namespace => 'ff/source_v1'}},
        {"/traces/internal/destination_v2/[:process_id]", ?MODULE, #{namespace => 'ff/destination_v2'}},
        {"/traces/internal/deposit_v1/[:process_id]", ?MODULE, #{namespace => 'ff/deposit_v1'}},
        {"/traces/internal/withdrawal_v2/[:process_id]", ?MODULE, #{namespace => 'ff/withdrawal_v2'}},
        {"/traces/internal/withdrawal_session_v2/[:process_id]", ?MODULE, #{namespace => 'ff/withdrawal/session_v2'}}
    ].

-spec init(cowboy_req:req(), cowboy_http:opts()) ->
    {ok, cowboy_req:req(), undefined}.
init(Request, Opts) ->
    Method = cowboy_req:method(Request),
    NS = maps:get(namespace, Opts),
    ProcessID = cowboy_req:binding(process_id, Request),
    maybe
        {method_is_valid, true} ?= {method_is_valid, Method =:= <<"GET">>},
        {process_id_is_valid, true} ?= {process_id_is_valid, is_binary(ProcessID)},
        {ok, Trace} ?= ff_machine:trace(NS, ProcessID),
        Body = unicode:characters_to_binary(json:encode(Trace)),
        Req = cowboy_req:reply(200, #{}, Body, Request),
        {ok, Req, undefined}
    else
        {method_is_valid, false} ->
            Req1 = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Request),
            {ok, Req1, undefined};
        {process_id_is_valid, false} ->
            Req2 = cowboy_req:reply(400, #{}, <<"Invalid ProcessID">>, Request),
            {ok, Req2, undefined};
        {error, <<"process not found">>} ->
            Req3 = cowboy_req:reply(404, #{}, <<"Unknown process">>, Request),
            {ok, Req3, undefined}
    end.

-spec terminate(term(), cowboy_req:req(), undefined) ->
    ok.
terminate(_Reason, _Req, _State) ->
    ok.
