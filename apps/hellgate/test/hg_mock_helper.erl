-module(hg_mock_helper).

-behaviour(woody_server_thrift_handler).

-include_lib("common_test/include/ct.hrl").

-export([handle_function/4]).

-export([start_sup/0]).
-export([stop_sup/1]).
-export([mock_services/2]).
-export([mock_dominant/2]).
-export([mock_party_management/2]).

%%

-type service_name() :: atom().
-type service_fun() :: fun((woody:func(), woody:args()) -> term()).
-type service() :: {service_name(), service_fun()}.
-type service_to_mock() :: {service_name(), woody:service(), service_fun()}.
-type services() :: [service()].
-type services_to_mock() :: [service_to_mock()].

-define(HELLGATE_IP, "::").
-define(HELLGATE_HOST, "hellgate").

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

-spec start_sup() -> {ok, pid()}.
start_sup() ->
    {ok, SupPid} = genlib_adhoc_supervisor:start_link(
        #{strategy => one_for_all, intensity => 1, period => 1}, []
    ),
    _ = unlink(SupPid),
    {ok, SupPid}.

-spec stop_sup(pid()) -> _.
stop_sup(SupPid) ->
    proc_lib:stop(SupPid, shutdown, 5000).

-spec mock_services(services(), pid()) -> _.
mock_services(Services, SupPid) ->
    ServicesToMock = [get_service_to_mock(Service) || Service <- Services],
    start_woody_client(mock_services_(ServicesToMock, SupPid)).

-spec mock_dominant(services(), pid()) -> _.
mock_dominant(Services0, SupPid) ->
    Services1 = lists:map(
        fun
            ({'AuthorManagement', Fun}) ->
                {'AuthorManagement', {dmsl_domain_conf_v2_thrift, 'AuthorManagement'}, Fun};
            ({'Repository', Fun}) ->
                {'Repository', {dmsl_domain_conf_v2_thrift, 'Repository'}, Fun};
            ({'RepositoryClient', Fun}) ->
                {'RepositoryClient', {dmsl_domain_conf_v2_thrift, 'RepositoryClient'}, Fun}
        end,
        Services0
    ),
    _ = start_dmt_client(mock_services_(Services1, SupPid)),
    ok.

-spec mock_party_management(services(), pid()) -> _.
mock_party_management(Services, SupPid) ->
    ServicesToMock = [get_service_to_mock(Service) || Service <- Services],
    _ = start_party_client(mock_services_(ServicesToMock, SupPid)),
    ok.

start_party_client(Services) when map_size(Services) == 0 ->
    ok;
start_party_client(Services) ->
    hg_ct_helper:start_app(party_client, [{services, Services}]).

start_dmt_client(Services) when map_size(Services) == 0 ->
    ok;
start_dmt_client(Services) ->
    hg_ct_helper:start_app(dmt_client, [
        {service_urls, Services}
    ]).

start_woody_client(Services0) ->
    ExistingServices = application:get_env(hg_proto, services, #{}),
    Services1 = maps:merge(ExistingServices, Services0),
    _ = hg_ct_helper:start_app(hg_proto, [{services, Services1}]).

-spec mock_services_(services_to_mock(), pid()) -> map().
mock_services_([], _SupPid) ->
    #{};
mock_services_(Services, SupPid) when is_pid(SupPid) ->
    {ok, IP} = inet:parse_address(?HELLGATE_IP),
    lists:foldl(
        fun(Service, Acc) ->
            Name = get_service_name(Service),
            ServerID = {dummy, Name},
            WoodyOpts = #{
                ip => IP,
                port => 0,
                event_handler => scoper_woody_event_handler,
                handlers => [mock_service_handler(Service)]
            },
            ChildSpec = woody_server:child_spec(ServerID, WoodyOpts),
            {ok, _} = supervisor:start_child(SupPid, ChildSpec),
            {_IP, Port} = woody_server:get_addr(ServerID, WoodyOpts),
            Acc#{Name => make_url(Name, Port)}
        end,
        #{},
        Services
    ).

get_service_name({ServiceName, _WoodyService, _Fun}) ->
    ServiceName.

get_service_to_mock({ServiceName, Fun}) ->
    {ServiceName, hg_proto:get_service(ServiceName), Fun}.

mock_service_handler({ServiceName, WoodyService, Fun}) ->
    {make_path(ServiceName), {WoodyService, {?MODULE, #{function => Fun}}}}.

make_url(ServiceName, Port) ->
    iolist_to_binary(["http://", ?HELLGATE_HOST, ":", integer_to_list(Port), make_path(ServiceName)]).

make_path(ServiceName) ->
    "/" ++ atom_to_list(ServiceName).
