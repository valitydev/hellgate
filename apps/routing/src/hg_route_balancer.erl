-module(hg_route_balancer).

-export([fill/1]).

-type route() :: hg_route:t().
-type terminal_priority_rating() :: integer().
-type availability_condition() :: integer().
-type route_groups_by_priority() :: #{{availability_condition(), terminal_priority_rating()} => [route()]}.

-spec fill([route()]) -> [route()].
fill(Routes) ->
    RouteGroups = lists:foldl(
        fun group_routes_by_priority/2,
        #{},
        Routes
    ),
    balance_route_groups(RouteGroups).

-spec group_routes_by_priority(route(), route_groups_by_priority()) -> route_groups_by_priority().
group_routes_by_priority(Route, RouteGroups) ->
    Priority = hg_route:priority(Route),
    #{availability_condition := AvailabilityCondition} = hg_route:fd_score(Route),
    GroupKey = {AvailabilityCondition, Priority},
    GroupRoutes = maps:get(GroupKey, RouteGroups, []),
    RouteGroups#{GroupKey => [Route | GroupRoutes]}.

-spec balance_route_groups(route_groups_by_priority()) -> [route()].
balance_route_groups(RouteGroups) ->
    maps:fold(
        fun(_GroupKey, Routes, Acc) ->
            balance_group_routes(Routes) ++ Acc
        end,
        [],
        RouteGroups
    ).

balance_group_routes(Routes) ->
    SummaryWeight = get_summary_weight(Routes),
    Random = rand:uniform() * SummaryWeight,
    lists:reverse(calc_random_condition(0.0, Random, Routes, [])).

get_summary_weight(Routes) ->
    lists:foldl(
        fun(Route, Acc) ->
            Acc + hg_route:weight(Route)
        end,
        0,
        Routes
    ).

calc_random_condition(_, _, [], Routes) ->
    Routes;
calc_random_condition(StartFrom, Random, [Route | Rest], Routes) ->
    Weight = hg_route:weight(Route),
    InRange = (Random >= StartFrom) and (Random < StartFrom + Weight),
    UpdatedRoute =
        case InRange of
            true -> hg_route:set_weight(1, Route);
            false -> hg_route:set_weight(0, Route)
        end,
    calc_random_condition(StartFrom + Weight, Random, Rest, [UpdatedRoute | Routes]).
