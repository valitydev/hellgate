-module(hg_mock_helper).

-include_lib("common_test/include/ct.hrl").

-export([start_mocked_service_sup/0]).
-export([stop_mocked_service_sup/1]).
-export([mock_services/2]).

-include("hg_ct_domain.hrl").
-include("hg_ct_json.hrl").

-include_lib("hellgate/include/domain.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_config_thrift.hrl").

-export_type([config/0]).

-type config() :: [{atom(), any()}].
-type sup_or_config() :: config() | pid().

%%

-define(HELLGATE_IP, "::").
-define(HELLGATE_HOST, "hellgate").
-define(HELLGATE_PORT, 8022).

-spec start_mocked_service_sup() -> {ok, pid()}.
start_mocked_service_sup() ->
    {ok, SupPid} = genlib_adhoc_supervisor:start_link(
        #{strategy => one_for_all, intensity => 1, period => 1}, []
    ),
    _ = unlink(SupPid),
    {ok, SupPid}.

-spec stop_mocked_service_sup(pid()) -> _.
stop_mocked_service_sup(SupPid) ->
    proc_lib:stop(SupPid, shutdown, 5000).

-spec mock_services(list(), sup_or_config()) -> _.
mock_services(Services, SupOrConfig) ->
    {DominantClientServices, WoodyServices0} = lists:partition(
        fun
            ({repository, _}) -> true;
            ({repository_client, _}) -> true;
            (_) -> false
        end,
        Services
    ),
    {PartyClientServices, WoodyServices1} = lists:partition(
        fun
            ({party_management, _}) -> true;
            (_) -> false
        end,
        WoodyServices0
    ),
    _ = start_party_client(mock_services_(PartyClientServices, SupOrConfig)),
    _ = start_dmt_client(mock_services_(DominantClientServices, SupOrConfig)),
    start_woody_client(mock_services_(WoodyServices1, SupOrConfig)).

start_party_client(Services) when map_size(Services) == 0 ->
    ok;
start_party_client(Services) ->
    hg_ct_helper:start_app(party_client, [{services, Services}]).

start_dmt_client(Services) when map_size(Services) == 0 ->
    ok;
start_dmt_client(Services) ->
    ReformattedServices = maps:fold(
        fun(Key, V, Acc) ->
            case (Key) of
                repository ->
                    Acc#{'Repository' => V};
                repository_client ->
                    Acc#{'RepositoryClient' => V};
                _ ->
                    Acc
            end
        end,
        #{},
        Services
    ),
    hg_ct_helper:start_app(dmt_client, [
        {service_urls, ReformattedServices}
    ]).

start_woody_client(Services0) ->
    ExistingServices = application:get_env(hg_proto, services, #{}),
    Services1 = maps:merge(ExistingServices, Services0),
    _ = hg_ct_helper:start_app(hg_proto, [{services, Services1}]).

-spec mock_services_(list(), sup_or_config()) -> map().
mock_services_([], _Config) ->
    #{};
mock_services_(Services, Config) when is_list(Config) ->
    mock_services_(Services, ?config(test_sup, Config));
mock_services_(Services, SupPid) when is_pid(SupPid) ->
    {ok, IP} = inet:parse_address(?HELLGATE_IP),
    lists:foldl(
        fun
            ({Name, URL}, Acc) when is_binary(URL) ->
                Acc#{Name => URL};
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

mock_service_handler({repository, Fun}) ->
    mock_service_handler(repository, {dmsl_domain_config_thrift, 'Repository'}, Fun);
mock_service_handler({repository_client, Fun}) ->
    mock_service_handler(repository_client, {dmsl_domain_config_thrift, 'RepositoryClient'}, Fun);
mock_service_handler({ServiceName, Fun}) ->
    mock_service_handler(ServiceName, hg_proto:get_service(ServiceName), Fun);
mock_service_handler({ServiceName, WoodyService, Fun}) ->
    mock_service_handler(ServiceName, WoodyService, Fun).

mock_service_handler(ServiceName, WoodyService, Fun) ->
    {make_path(ServiceName), {WoodyService, {hg_service_wrapper, #{function => Fun}}}}.

make_url(ServiceName, Port) ->
    iolist_to_binary(["http://", ?HELLGATE_HOST, ":", integer_to_list(Port), make_path(ServiceName)]).

make_path(ServiceName) ->
    "/" ++ atom_to_list(ServiceName).
