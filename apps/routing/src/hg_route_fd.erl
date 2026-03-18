-module(hg_route_fd).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-export([fill/1]).

-type route() :: hg_route:t().

-define(fd_overrides(Enabled), #domain_RouteFaultDetectorOverrides{enabled = Enabled}).

-spec fill([route()]) -> [route()].
fill([]) ->
    [];
fill(Routes) ->
    RouteMap = build_route_map(Routes),
    ServiceIDs = [Key || Key <- maps:keys(RouteMap), is_binary(Key)],
    FDStats = hg_fault_detector_client:get_statistics(ServiceIDs),
    UpdatedMap = lists:foldl(fun fill_fd_score/2, RouteMap, FDStats),
    [maps:get(Route, UpdatedMap) || Route <- Routes].

build_route_map(Routes) ->
    lists:foldl(
        fun(Route, Acc) ->
            #domain_ProviderRef{id = ID} = hg_route:provider_ref(Route),
            AvailabilityID = hg_fault_detector_client:build_service_id(adapter_availability, ID),
            ConversionID = hg_fault_detector_client:build_service_id(provider_conversion, ID),
            Acc#{
                AvailabilityID => {availability, Route},
                ConversionID => {conversion, Route},
                Route => Route
            }
        end,
        #{},
        Routes
    ).

fill_fd_score(#fault_detector_ServiceStatistics{service_id = ID, failure_rate = FailRate}, RouteMap) ->
    case maps:get(ID, RouteMap, undefined) of
        undefined ->
            RouteMap;
        {availability, RouteRef} ->
            Route = maps:get(RouteRef, RouteMap),
            AvailabilityConfig = maps:get(availability, genlib_app:env(hellgate, fault_detector, #{}), #{}),
            CriticalFailRate = maps:get(critical_fail_rate, AvailabilityConfig, 0.7),
            {Condition, Value} = calc_rate(FailRate >= CriticalFailRate, FailRate),
            UpdatedRoute = maybe_override(
                hg_route:fd_overrides(Route),
                hg_route:set_availability(Condition, Value, Route),
                Route
            ),
            RouteMap#{RouteRef => UpdatedRoute};
        {conversion, RouteRef} ->
            Route = maps:get(RouteRef, RouteMap),
            ConversionConfig = maps:get(conversion, genlib_app:env(hellgate, fault_detector, #{}), #{}),
            CriticalFailRate = maps:get(critical_fail_rate, ConversionConfig, 0.7),
            {Condition, Value} = calc_rate(FailRate >= CriticalFailRate, FailRate),
            UpdatedRoute = maybe_override(
                hg_route:fd_overrides(Route),
                hg_route:set_conversion(Condition, Value, Route),
                Route
            ),
            RouteMap#{RouteRef => UpdatedRoute}
    end.

maybe_override(?fd_overrides(true), _UpdatedRoute, Route) ->
    Route;
maybe_override(_, UpdatedRoute, _Route) ->
    UpdatedRoute.

calc_rate(true, FailRate) ->
    {0, 1.0 - FailRate};
calc_rate(false, FailRate) ->
    {1, 1.0 - FailRate}.
