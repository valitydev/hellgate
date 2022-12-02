%%%
%%% Test machine
%%%

-module(ff_ct_machine).

-dialyzer({nowarn_function, dispatch_signal/4}).

-export([load_per_suite/0]).
-export([unload_per_suite/0]).

-export([set_hook/2]).
-export([clear_hook/1]).

-spec load_per_suite() -> ok.
load_per_suite() ->
    meck:new(machinery, [no_link, passthrough]),
    meck:expect(machinery, dispatch_signal, fun dispatch_signal/4),
    meck:expect(machinery, dispatch_call, fun dispatch_call/4).

-spec unload_per_suite() -> ok.
unload_per_suite() ->
    meck:unload(machinery).

-type hook() :: fun((machinery:machine(_, _), module(), _Args) -> _).

-spec set_hook(timeout, hook()) -> ok.
set_hook(On = timeout, Fun) when is_function(Fun, 3) ->
    persistent_term:put({?MODULE, hook, On}, Fun).

-spec clear_hook(timeout) -> ok.
clear_hook(On = timeout) ->
    _ = persistent_term:erase({?MODULE, hook, On}),
    ok.

dispatch_signal({init, Args}, Machine, {Handler, HandlerArgs}, Opts) ->
    Handler:init(Args, Machine, HandlerArgs, Opts);
dispatch_signal(timeout, Machine, {Handler, HandlerArgs}, Opts) when Handler =/= fistful ->
    _ =
        case persistent_term:get({?MODULE, hook, timeout}, undefined) of
            Fun when is_function(Fun) ->
                Fun(Machine, Handler, HandlerArgs);
            undefined ->
                ok
        end,
    Handler:process_timeout(Machine, HandlerArgs, Opts);
dispatch_signal(timeout, Machine, {Handler, HandlerArgs}, Opts) ->
    Handler:process_timeout(Machine, HandlerArgs, Opts);
dispatch_signal({notification, Args}, Machine, {Handler, HandlerArgs}, Opts) ->
    Handler:process_notification(Args, Machine, HandlerArgs, Opts).

dispatch_call(Args, Machine, {Handler, HandlerArgs}, Opts) ->
    Handler:process_call(Args, Machine, HandlerArgs, Opts).
