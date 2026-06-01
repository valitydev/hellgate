-module(hg_route_balancer).

-behaviour(hg_route_collector).
-export([fill/1]).

%%

-type route() :: hg_route:t().
-type terminal_priority_rating() :: integer().
-type availability_condition() :: integer().
-type route_groups_by_priority() :: #{{availability_condition(), terminal_priority_rating()} => [route()]}.

%%

-spec fill([route()]) -> [route()].
fill(Routes) ->
    FilteredRouteGroups = lists:foldr(
        fun group_routes_by_priority/2,
        #{},
        Routes
    ),
    balance_route_groups(FilteredRouteGroups).

-spec group_routes_by_priority(route(), Acc :: route_groups_by_priority()) -> route_groups_by_priority().
group_routes_by_priority(Route, SortedRoutes) ->
    Priority = hg_route:priority(Route),
    #{availability_condition := ACond} = hg_route:fd_score(Route),
    Key = {ACond, Priority},
    Routes = maps:get(Key, SortedRoutes, []),
    SortedRoutes#{Key => [Route | Routes]}.

-spec balance_route_groups(route_groups_by_priority()) -> [route()].
balance_route_groups(RouteGroups) ->
    maps:fold(
        fun(_Priority, Routes, Acc) ->
            NewRoutes = set_routes_random_condition(Routes),
            NewRoutes ++ Acc
        end,
        [],
        RouteGroups
    ).

set_routes_random_condition(Routes) ->
    Summary = get_summary_weight(Routes),
    Random = rand:uniform() * Summary,
    lists:reverse(calc_random_condition(0.0, Random, Routes, [])).

get_summary_weight(Routes) ->
    lists:foldl(
        fun(Route, Acc) ->
            Weight = hg_route:weight(Route),
            Acc + Weight
        end,
        0,
        Routes
    ).

calc_random_condition(_, _, [], Routes) ->
    Routes;
calc_random_condition(StartFrom, Random, [Route | Rest], Routes) ->
    Weight = hg_route:weight(Route),
    InRange = (Random >= StartFrom) and (Random < StartFrom + Weight),
    case InRange of
        true ->
            NewRoute = hg_route:set_weight(1, Route),
            calc_random_condition(StartFrom + Weight, Random, Rest, [NewRoute | Routes]);
        false ->
            NewRoute = hg_route:set_weight(0, Route),
            calc_random_condition(StartFrom + Weight, Random, Rest, [NewRoute | Routes])
    end.

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-spec test() -> _.
-type testcase() :: {_, fun(() -> _)}.

-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).

balanced_test_route(ProviderId, Weight) ->
    hg_route:new(1, ?prv(ProviderId), ?trm(1), Weight, ?DOMAIN_CANDIDATE_PRIORITY, #{}).

-spec balance_routes_test_() -> [testcase()].
balance_routes_test_() ->
    WithWeight = [
        balanced_test_route(1, 1),
        balanced_test_route(2, 2),
        balanced_test_route(3, 0),
        balanced_test_route(4, 1),
        balanced_test_route(5, 0)
    ],

    Result1 = [
        balanced_test_route(1, 1),
        balanced_test_route(2, 0),
        balanced_test_route(3, 0),
        balanced_test_route(4, 0),
        balanced_test_route(5, 0)
    ],
    Result2 = [
        balanced_test_route(1, 0),
        balanced_test_route(2, 1),
        balanced_test_route(3, 0),
        balanced_test_route(4, 0),
        balanced_test_route(5, 0)
    ],
    Result3 = [balanced_test_route(Prv, 0) || Prv <- lists:seq(1, 5)],
    [
        ?_assertEqual(Result1, lists:reverse(calc_random_condition(0.0, 0.2, WithWeight, []))),
        ?_assertEqual(Result2, lists:reverse(calc_random_condition(0.0, 1.5, WithWeight, []))),
        ?_assertEqual(Result3, lists:reverse(calc_random_condition(0.0, 4.0, WithWeight, [])))
    ].

-spec balance_routes_with_default_weight_test_() -> testcase().
balance_routes_with_default_weight_test_() ->
    Routes = [
        hg_route:new(1, ?prv(1), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY, #{}),
        hg_route:new(1, ?prv(2), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY, #{})
    ],
    Result = [
        hg_route:new(1, ?prv(1), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY, #{}),
        hg_route:new(1, ?prv(2), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY, #{})
    ],
    ?_assertEqual(Result, set_routes_random_condition(Routes)).

-spec fill_preserves_candidate_order_test_() -> testcase().
fill_preserves_candidate_order_test_() ->
    Routes = [
        balanced_test_route(1, 0),
        balanced_test_route(2, 0),
        balanced_test_route(3, 0)
    ],
    ?_assertEqual(Routes, fill(Routes)).

-endif.
