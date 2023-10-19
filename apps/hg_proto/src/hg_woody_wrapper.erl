-module(hg_woody_wrapper).

-export_type([client_opts/0]).

-type client_opts() :: #{
    url := woody:url(),
    transport_opts => [{_, _}]
}.

%% API

-export([call/3]).
-export([call/4]).
-export([call/5]).
-export([raise/1]).

-export([get_service_options/1]).

-spec call(atom(), woody:func(), woody:args()) -> term().
call(ServiceName, Function, Args) ->
    Opts = get_service_options(ServiceName),
    Deadline = undefined,
    call(ServiceName, Function, Args, Opts, Deadline).

-spec call(atom(), woody:func(), woody:args(), client_opts()) -> term().
call(ServiceName, Function, Args, Opts) ->
    Deadline = undefined,
    call(ServiceName, Function, Args, Opts, Deadline).

-spec call(atom(), woody:func(), woody:args(), client_opts(), woody_deadline:deadline()) -> term().
call(ServiceName, Function, Args, Opts, Deadline) ->
    Service = get_service_modname(ServiceName),
    Context = hg_context:get_woody_context(hg_context:load()),
    Request = {Service, Function, Args},
    woody_client:call(
        Request,
        Opts#{
            event_handler => {
                scoper_woody_event_handler,
                genlib_app:env(hellgate, scoper_event_handler_options, #{})
            }
        },
        attach_deadline(Deadline, Context)
    ).

-spec get_service_options(atom()) -> client_opts().
get_service_options(ServiceName) ->
    construct_opts(maps:get(ServiceName, genlib_app:env(hg_proto, services))).

-spec attach_deadline(woody_deadline:deadline(), woody_context:ctx()) -> woody_context:ctx().
attach_deadline(undefined, Context) ->
    Context;
attach_deadline(Deadline, Context) ->
    woody_context:set_deadline(Deadline, Context).

-spec raise(term()) -> no_return().
raise(Exception) ->
    woody_error:raise(business, Exception).

%% Internal functions

construct_opts(Opts = #{url := Url}) ->
    Opts#{url := genlib:to_binary(Url)};
construct_opts(Url) ->
    #{url => genlib:to_binary(Url)}.

-spec get_service_modname(atom()) -> {module(), atom()}.
get_service_modname(ServiceName) ->
    hg_proto:get_service(ServiceName).
