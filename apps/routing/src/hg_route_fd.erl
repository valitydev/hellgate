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
    #{
        service_ids := ServiceIDs,
        service_map := ServiceMap,
        routes := RouteMap
    } = lists:foldl(fun build_route_map/2, #{service_ids => [], service_map => #{}, routes => #{}}, Routes),
    FDStats = hg_fault_detector_client:get_statistics(ServiceIDs),
    maps:values(lists:foldl(fun(Stats, Map) -> fill_fd_score(Stats, ServiceMap, Map) end, RouteMap, FDStats)).

%%

build_route_map(Route, #{service_ids := ServiceIDs, service_map := ServiceMap, routes := RouteMap}) ->
    #domain_ProviderRef{id = ProviderID} = hg_route:provider_ref(Route),
    PaymentRoute = hg_route:to_payment_route(Route),
    AvailabilityID = hg_fault_detector_client:build_service_id(adapter_availability, ProviderID),
    ConversionID = hg_fault_detector_client:build_service_id(provider_conversion, ProviderID),
    #{
        service_ids => [AvailabilityID, ConversionID | ServiceIDs],
        service_map => ServiceMap#{
            AvailabilityID => {availability, PaymentRoute},
            ConversionID => {conversion, PaymentRoute}
        },
        routes => RouteMap#{PaymentRoute => Route}
    }.

fill_fd_score(#fault_detector_ServiceStatistics{service_id = ID, failure_rate = FailRate}, ServiceMap, RouteMap) ->
    case maps:get(ID, ServiceMap, undefined) of
        undefined ->
            RouteMap;
        {availability, PaymentRoute} ->
            Route = maps:get(PaymentRoute, RouteMap),
            AvailabilityConfig = maps:get(availability, genlib_app:env(hellgate, fault_detector, #{}), #{}),
            CriticalFailRate = maps:get(critical_fail_rate, AvailabilityConfig, 0.7),
            {Condition, Value} = calc_rate(FailRate >= CriticalFailRate, FailRate),
            NewRoute = maybe_override(
                hg_route:fd_overrides(Route),
                hg_route:set_availability(Condition, Value, Route),
                Route
            ),
            RouteMap#{PaymentRoute => NewRoute};
        {conversion, PaymentRoute} ->
            Route = maps:get(PaymentRoute, RouteMap),
            ConversionConfig = maps:get(conversion, genlib_app:env(hellgate, fault_detector, #{}), #{}),
            CriticalFailRate = maps:get(critical_fail_rate, ConversionConfig, 0.7),
            {Condition, Value} = calc_rate(FailRate >= CriticalFailRate, FailRate),
            NewRoute = maybe_override(
                hg_route:fd_overrides(Route),
                hg_route:set_conversion(Condition, Value, Route),
                Route
            ),
            RouteMap#{PaymentRoute => NewRoute}
    end.

maybe_override(?fd_overrides(true), _NewRoute, Route) ->
    Route;
maybe_override(_, NewRoute, _Route) ->
    NewRoute.

calc_rate(true, FailRate) ->
    {0, 1.0 - FailRate};
calc_rate(false, FailRate) ->
    {1, 1.0 - FailRate}.
