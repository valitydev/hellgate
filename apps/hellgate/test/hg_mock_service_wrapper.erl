-module(hg_mock_service_wrapper).

%% Woody handler

-behaviour(woody_server_thrift_handler).

%% API
-export([handle_function/4]).

% 30 seconds
-define(DEFAULT_HANDLING_TIMEOUT, 30000).

%% Callbacks

-callback handle_function(woody:func(), woody:args(), woody:options()) -> term() | no_return().

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, term()} | no_return().
handle_function(FunName, Args, _, #{function := Fun}) ->
    case Fun(FunName, Args) of
        {throwing, Exception} ->
            erlang:throw(Exception);
        Result ->
            Result
    end.
