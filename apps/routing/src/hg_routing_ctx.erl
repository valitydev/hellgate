-module(hg_routing_ctx).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-compile({no_auto_import, [error/1]}).

-export_type([t/0]).

-export([
    new/1,
    from_result/1,
    append_rejected_routes/4,
    reject/3,
    rejected_routes/1,
    rejections/1,
    candidates/1,
    stash_current_candidates/1,
    considered_candidates/1,
    initial_candidates/1,
    accounted_candidates/1,
    latest_rejected_error/1,
    set_choosen/3,
    choosen_route/1,
    set_error/2,
    error/1,
    stash_route_limits/2,
    stash_route_scores/2,
    route_limits/1,
    route_scores/1,
    build_route_selection_context/3
]).

-type rejection_group() :: atom().
-type routes() :: [hg_route:t()].
-type limits() :: #{hg_route:payment_route() => [hg_limiter:turnover_limit_value()]}.
-type scores() :: #{hg_route:payment_route() => #domain_PaymentRouteScores{}}.
-type error() :: {atom(), _Description}.

-type t() :: #{
    initial_candidates := routes(),
    candidates := routes(),
    rejections := #{rejection_group() => routes()},
    latest_rejection => rejection_group(),
    stashed_candidates => routes(),
    error => error() | undefined,
    choosen_route => hg_route:t() | undefined,
    choice_meta => map() | undefined,
    route_limits => limits() | undefined,
    route_scores => scores() | undefined
}.

-spec new(routes()) -> t().
new(Candidates) ->
    #{
        initial_candidates => Candidates,
        candidates => Candidates,
        rejections => #{},
        error => undefined,
        choosen_route => undefined,
        choice_meta => undefined
    }.

-spec from_result(#{routes := routes(), rejected_routes => routes()}) -> t().
from_result(#{routes := Routes} = RoutingResult) ->
    RejectedRoutes = maps:get(rejected_routes, RoutingResult, []),
    append_rejected_routes(forbidden, Routes, RejectedRoutes, new(Routes)).

-spec append_rejected_routes(
    rejection_group(),
    routes(),
    routes(),
    t()
) -> t().
append_rejected_routes(_Group, Candidates, [], Ctx) ->
    Ctx#{candidates => Candidates};
append_rejected_routes(Group, Candidates, RejectedRoutes, Ctx0) ->
    Rejections0 = maps:get(rejections, Ctx0, #{}),
    GroupRejected = maps:get(Group, Rejections0, []),
    Ctx0#{
        candidates => Candidates,
        rejections => Rejections0#{Group => GroupRejected ++ RejectedRoutes},
        latest_rejection => Group
    }.

-spec reject(rejection_group(), hg_route:rejected_route(), t()) -> t().
reject(GroupReason, RejectedRoute, Ctx0) ->
    Rejections0 = maps:get(rejections, Ctx0, #{}),
    RejectedList = maps:get(GroupReason, Rejections0, []) ++ [RejectedRoute],
    Ctx0#{
        candidates => exclude_route(RejectedRoute, candidates(Ctx0)),
        rejections => Rejections0#{GroupReason => RejectedList},
        latest_rejection => GroupReason
    }.

-spec rejected_routes(t()) -> [hg_route:rejected_route()].
rejected_routes(Ctx) ->
    lists:flatten([R || {_, R} <- maps:to_list(rejection_map(Ctx))]).

-spec rejections(t()) -> [{rejection_group(), routes()}].
rejections(#{rejections := Rejections}) ->
    maps:to_list(Rejections);
rejections(_) ->
    [].

-spec candidates(t()) -> routes().
candidates(#{candidates := Candidates}) ->
    Candidates.

-spec stash_current_candidates(t()) -> t().
stash_current_candidates(Ctx) ->
    case candidates(Ctx) of
        [] ->
            Ctx;
        CurrentCandidates ->
            Ctx#{stashed_candidates => CurrentCandidates}
    end.

-spec considered_candidates(t()) -> routes().
considered_candidates(Ctx) ->
    maps:get(stashed_candidates, Ctx, candidates(Ctx)).

-spec initial_candidates(t()) -> routes().
initial_candidates(#{initial_candidates := InitialCandidates}) ->
    InitialCandidates.

-spec accounted_candidates(t()) -> routes().
accounted_candidates(Ctx) ->
    maps:get(stashed_candidates, Ctx, initial_candidates(Ctx)).

-spec latest_rejected_error(t()) -> {rejected_routes, {atom(), routes()}}.
latest_rejected_error(Result) ->
    {Group, RejectedRoutes} = latest_rejected_routes(Result),
    {rejected_routes, {Group, RejectedRoutes}}.

-spec set_choosen(hg_route:t(), hg_routing:route_choice_context(), t()) -> t().
set_choosen(Route, ChoiceMeta, Ctx) ->
    Ctx#{
        choosen_route => Route,
        choice_meta => ChoiceMeta
    }.

-spec choosen_route(t()) -> hg_route:t() | undefined.
choosen_route(#{choosen_route := ChoosenRoute}) ->
    ChoosenRoute.

-spec set_error(error() | undefined, t()) -> t().
set_error(ErrorReason, Ctx) ->
    Ctx#{error => ErrorReason}.

-spec error(t()) -> error() | undefined.
error(#{error := Error}) ->
    Error;
error(_) ->
    undefined.

-spec route_limits(t()) -> limits() | undefined.
route_limits(Ctx) ->
    maps:get(route_limits, Ctx, undefined).

-spec stash_route_limits(limits(), t()) -> t().
stash_route_limits(Limits, Ctx) ->
    Ctx#{route_limits => Limits}.

-spec route_scores(t()) -> scores() | undefined.
route_scores(Ctx) ->
    maps:get(route_scores, Ctx, undefined).

-spec stash_route_scores(scores(), t()) -> t().
stash_route_scores(RouteScores, Ctx) ->
    Ctx#{route_scores => maps:merge(maps:get(route_scores, Ctx, #{}), RouteScores)}.

-spec build_route_selection_context(hg_route:t(), map(), t()) -> t().
build_route_selection_context(ChosenRoute, ChoiceMeta, Ctx) ->
    ExplainableRoutes = get_explainable_routes(Ctx),
    Ctx#{
        choosen_route => ChosenRoute,
        choice_meta => ChoiceMeta,
        route_scores => build_route_scores(ExplainableRoutes)
    }.

-spec latest_rejected_routes(t()) -> {rejection_group(), routes()}.
latest_rejected_routes(Result) ->
    RejectionMap = rejection_map(Result),
    Group = maps:get(latest_rejection, Result, forbidden),
    {Group, maps:get(Group, RejectionMap, [])}.

-spec rejection_map(t()) -> #{rejection_group() => routes()}.
rejection_map(Result) ->
    maps:get(rejections, Result, #{}).

get_explainable_routes(Result) ->
    merge_explainable_routes(
        rejected_routes(Result),
        candidates(Result)
    ).

merge_explainable_routes(Routes0, Routes1) ->
    lists:foldl(
        fun(Route, Acc) ->
            case lists:any(fun(AccRoute) -> hg_route:equal(Route, AccRoute) end, Acc) of
                true ->
                    Acc;
                false ->
                    Acc ++ [Route]
            end
        end,
        [],
        Routes0 ++ Routes1
    ).

build_route_scores(Routes) ->
    lists:foldl(
        fun(Route, Acc) ->
            Acc#{hg_route:to_payment_route(Route) => hg_route:score(Route)}
        end,
        #{},
        Routes
    ).

exclude_route(Route, Routes) ->
    lists:foldr(
        fun(R, RR) ->
            case hg_route:equal(Route, R) of
                true ->
                    RR;
                false ->
                    [R | RR]
            end
        end,
        [],
        Routes
    ).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec initial_candidates_test() -> _.
initial_candidates_test() ->
    R1 = new_test_route(1, 1),
    R2 = new_test_route(1, 2),
    R3 = new_test_route(1, 3),
    Result = from_result(#{routes => [R1, R2], rejected_routes => [R3]}),
    ?assertMatch(
        #{
            candidates := [R1, R2],
            initial_candidates := [R1, R2],
            rejections := #{forbidden := [R3]},
            latest_rejection := forbidden
        },
        Result
    ),
    ?assertEqual([R1, R2], initial_candidates(Result)).

-spec considered_and_accounted_candidates_test() -> _.
considered_and_accounted_candidates_test() ->
    R1 = new_test_route(2, 1),
    R2 = new_test_route(2, 2),
    Base = new([R1, R2]),
    ?assertEqual([R1, R2], accounted_candidates(Base)),
    ?assertEqual(
        [R1],
        considered_candidates(stash_current_candidates(append_rejected_routes(test, [R1], [R2], Base)))
    ).

-spec latest_rejected_error_test() -> _.
latest_rejected_error_test() ->
    R1 = new_test_route(3, 1),
    R2 = new_test_route(3, 2),
    R3 = new_test_route(3, 3),
    Result = append_rejected_routes(
        limit_overflow,
        [R1],
        [R2],
        from_result(#{routes => [R1], rejected_routes => [R3]})
    ),
    ?assertEqual(
        {rejected_routes, {limit_overflow, [R2]}},
        latest_rejected_error(Result)
    ).

-spec route_data_helpers_test() -> _.
route_data_helpers_test() ->
    R1 = new_test_route(4, 1),
    PaymentRoute = hg_route:to_payment_route(R1),
    Result0 = new([R1]),
    Result1 = stash_current_candidates(Result0),
    Result2 = stash_route_scores(
        #{PaymentRoute => hg_route:score(R1)},
        stash_route_limits(#{PaymentRoute => []}, Result1)
    ),
    ?assertEqual([R1], accounted_candidates(Result2)).

new_test_route(ProviderID, TerminalID) ->
    hg_route:new(
        1,
        #domain_ProviderRef{id = ProviderID},
        #domain_TerminalRef{id = TerminalID},
        0,
        0,
        #{}
    ).

-endif.
