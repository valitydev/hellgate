-module(hg_mock_helper).

-include_lib("common_test/include/ct.hrl").

-export([start_sup/0]).
-export([stop_sup/1]).
-export([mock_services/2]).
-export([mock_dominant/2]).
-export([mock_party_management/2]).

%%

-define(HELLGATE_IP, "::").
-define(HELLGATE_HOST, "hellgate").

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

-spec mock_services(list(), pid()) -> _.
mock_services(Services, SupPid) ->
    start_woody_client(mock_services_(Services, SupPid)).

-spec mock_dominant(list(), pid()) -> _.
mock_dominant(Services0, SupPid) ->
    Services1 = lists:map(
        fun
            ({'Repository', Fun}) ->
                {'Repository', {dmsl_domain_config_thrift, 'Repository'}, Fun};
            ({'RepositoryClient', Fun}) ->
                {'RepositoryClient', {dmsl_domain_config_thrift, 'RepositoryClient'}, Fun};
            ({_, _, _} = Service) ->
                Service
        end,
        Services0
    ),
    _ = start_dmt_client(mock_services_(Services1, SupPid)),
    ok.

-spec mock_party_management(list(), pid()) -> _.
mock_party_management(Services, SupPid) ->
    _ = start_party_client(mock_services_(Services, SupPid)),
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

-spec mock_services_(list(), pid()) -> map().
mock_services_([], _Config) ->
    #{};
mock_services_(Services, SupPid) when is_pid(SupPid) ->
    {ok, IP} = inet:parse_address(?HELLGATE_IP),
    lists:foldl(
        fun
            (Service, Acc) ->
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

get_service_name({ServiceName, _Fun}) ->
    ServiceName;
get_service_name({ServiceName, _WoodyService, _Fun}) ->
    ServiceName.

mock_service_handler({ServiceName, Fun}) ->
    mock_service_handler(ServiceName, hg_proto:get_service(ServiceName), Fun);
mock_service_handler({ServiceName, WoodyService, Fun}) ->
    mock_service_handler(ServiceName, WoodyService, Fun).

mock_service_handler(ServiceName, WoodyService, Fun) ->
    {make_path(ServiceName), {WoodyService, {hg_mock_service_wrapper, #{function => Fun}}}}.

make_url(ServiceName, Port) ->
    iolist_to_binary(["http://", ?HELLGATE_HOST, ":", integer_to_list(Port), make_path(ServiceName)]).

make_path(ServiceName) ->
    "/" ++ atom_to_list(ServiceName).
