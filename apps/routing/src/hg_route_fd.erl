-module(hg_route_fd).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

%%

-behaviour(hg_route_collector).
-export([fill/1]).

%%

-type route() :: hg_route:t().

-define(fd_overrides(Enabled), #domain_RouteFaultDetectorOverrides{enabled = Enabled}).

%%

-spec fill([route()]) -> [route()].
fill([]) ->
    [];
fill(Routes) ->
    ServiceIDs = collect_service_ids(Routes),
    FDStats = hg_fault_detector_client:get_statistics(ServiceIDs),
    StatsMap = build_stats_map(FDStats),
    [fill_route(Route, StatsMap) || Route <- Routes].

%%

collect_service_ids(Routes) ->
    sets:to_list(
        lists:foldl(
            fun(Route, Acc) ->
                {AvailabilityID, ConversionID} = service_ids(Route),
                sets:add_element(ConversionID, sets:add_element(AvailabilityID, Acc))
            end,
            sets:new(),
            Routes
        )
    ).

build_stats_map(FDStats) ->
    maps:from_list([
        {ID, FailRate}
     || #fault_detector_ServiceStatistics{service_id = ID, failure_rate = FailRate} <- FDStats
    ]).

fill_route(Route, StatsMap) ->
    {AvailabilityID, ConversionID} = service_ids(Route),
    Route1 = fill_availability(Route, maps:get(AvailabilityID, StatsMap, undefined)),
    fill_conversion(Route1, maps:get(ConversionID, StatsMap, undefined)).

service_ids(Route) ->
    #domain_ProviderRef{id = ProviderID} = hg_route:provider_ref(Route),
    {
        hg_fault_detector_client:build_service_id(adapter_availability, ProviderID),
        hg_fault_detector_client:build_service_id(provider_conversion, ProviderID)
    }.

fill_availability(Route, undefined) ->
    Route;
fill_availability(Route, FailRate) ->
    AvailabilityConfig = maps:get(availability, genlib_app:env(hellgate, fault_detector, #{}), #{}),
    CriticalFailRate = maps:get(critical_fail_rate, AvailabilityConfig, 0.7),
    {Condition, Value} = calc_rate(FailRate >= CriticalFailRate, FailRate),
    maybe_override(
        hg_route:fd_overrides(Route),
        hg_route:set_availability(Condition, Value, Route),
        Route
    ).

fill_conversion(Route, undefined) ->
    Route;
fill_conversion(Route, FailRate) ->
    ConversionConfig = maps:get(conversion, genlib_app:env(hellgate, fault_detector, #{}), #{}),
    CriticalFailRate = maps:get(critical_fail_rate, ConversionConfig, 0.7),
    {Condition, Value} = calc_rate(FailRate >= CriticalFailRate, FailRate),
    maybe_override(
        hg_route:fd_overrides(Route),
        hg_route:set_conversion(Condition, Value, Route),
        Route
    ).

maybe_override(?fd_overrides(true), _NewRoute, Route) ->
    Route;
maybe_override(_, NewRoute, _Route) ->
    NewRoute.

calc_rate(true, FailRate) ->
    {0, 1.0 - FailRate};
calc_rate(false, FailRate) ->
    {1, 1.0 - FailRate}.
