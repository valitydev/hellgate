-module(hg_service_wrapper).

%% Woody handler

-behaviour(woody_server_thrift_handler).

%% API
-export([handle_function/4]).
-export([raise/1]).

-export_type([handler_opts/0]).

-type handler_opts() :: #{
    handler := module(),
    party_client => party_client:client(),
    default_handling_timeout => timeout()
}.

% 30 seconds
-define(DEFAULT_HANDLING_TIMEOUT, 30000).

%% Callbacks

-callback handle_function(woody:func(), woody:args(), handler_opts()) -> term() | no_return().

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), handler_opts()) -> {ok, term()} | no_return().
handle_function(Func, Args, WoodyContext0, #{handler := Handler} = Opts) ->
    WoodyContext = ensure_woody_deadline_set(WoodyContext0, Opts),
    ok = hg_context:save(create_context(WoodyContext, Opts)),
    try
        Result = Handler:handle_function(
            Func,
            Args,
            Opts
        ),
        {ok, Result}
    catch
        throw:Reason ->
            raise(Reason)
    after
        hg_context:cleanup()
    end.

-spec raise(term()) -> no_return().
raise(Exception) ->
    woody_error:raise(business, Exception).

create_context(WoodyContext, Opts) ->
    ContextOptions = #{
        woody_context => WoodyContext
    },
    Context = hg_context:create(ContextOptions),
    configure_party_client(Context, Opts).

configure_party_client(Context0, #{party_client := PartyClient}) ->
    hg_context:set_party_client(PartyClient, Context0);
configure_party_client(Context, _Opts) ->
    Context.

-spec ensure_woody_deadline_set(woody_context:ctx(), handler_opts()) -> woody_context:ctx().
ensure_woody_deadline_set(WoodyContext, Opts) ->
    case woody_context:get_deadline(WoodyContext) of
        undefined ->
            DefaultTimeout = maps:get(default_handling_timeout, Opts, ?DEFAULT_HANDLING_TIMEOUT),
            Deadline = woody_deadline:from_timeout(DefaultTimeout),
            woody_context:set_deadline(Deadline, WoodyContext);
        _Other ->
            WoodyContext
    end.
