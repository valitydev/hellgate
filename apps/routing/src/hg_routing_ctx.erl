-module(hg_routing_ctx).

-export([new/1]).
-export([with_fail_rates/2]).
-export([fail_rates/1]).
-export([set_choosen/3]).
-export([set_error/2]).
-export([error/1]).
-export([reject/3]).
-export([rejected_routes/1]).
-export([rejections/1]).
-export([candidates/1]).
-export([initial_candidates/1]).
-export([stash_current_candidates/1]).
-export([considered_candidates/1]).
-export([accounted_candidates/1]).
-export([choosen_route/1]).
-export([process/2]).
-export([with_guard/1]).
-export([pipeline/2]).
-export([route_limits/1]).
-export([stash_route_limits/2]).
-export([route_scores/1]).
-export([stash_route_scores/2]).
-export([add_route_scores/2]).

-type rejection_group() :: atom().
-type error() :: {atom(), _Description}.
-type route_limits() :: hg_routing:limits().
-type route_scores() :: hg_routing:scores().
-type one_route_scores() :: {hg_route:payment_route(), hg_routing:route_scores()}.

-type t() :: #{
    initial_candidates := [hg_route:t()],
    candidates := [hg_route:t()],
    rejections := #{rejection_group() => [hg_route:rejected_route()]},
    latest_rejection := rejection_group() | undefined,
    error := error() | undefined,
    choosen_route := hg_route:t() | undefined,
    choice_meta := hg_routing:route_choice_context() | undefined,
    stashed_candidates => [hg_route:t()],
    fail_rates => [hg_routing:fail_rated_route()],
    route_limits => route_limits(),
    route_scores => route_scores()
}.

-export_type([t/0]).

%%

-spec new([hg_route:t()]) -> t().
new(Candidates) ->
    #{
        initial_candidates => Candidates,
        candidates => Candidates,
        rejections => #{},
        latest_rejection => undefined,
        error => undefined,
        choosen_route => undefined,
        choice_meta => undefined
    }.

-spec with_fail_rates([hg_routing:fail_rated_route()], t()) -> t().
with_fail_rates(FailRates, Ctx) ->
    maps:put(fail_rates, FailRates, Ctx).

-spec fail_rates(t()) -> [hg_routing:fail_rated_route()] | undefined.
fail_rates(Ctx) ->
    maps:get(fail_rates, Ctx, undefined).

-spec set_choosen(hg_route:t(), hg_routing:route_choice_context(), t()) -> t().
set_choosen(Route, ChoiceMeta, Ctx) ->
    Ctx#{choosen_route => Route, choice_meta => ChoiceMeta}.

-spec set_error(term(), t()) -> t().
set_error(ErrorReason, Ctx) ->
    Ctx#{error => ErrorReason}.

-spec error(t()) -> term() | undefined.
error(#{error := Error}) ->
    Error.

-spec reject(atom(), hg_route:rejected_route(), t()) -> t().
reject(GroupReason, RejectedRoute, Ctx = #{rejections := Rejections, candidates := Candidates}) ->
    RejectedList = maps:get(GroupReason, Rejections, []) ++ [RejectedRoute],
    Ctx#{
        rejections := Rejections#{GroupReason => RejectedList},
        candidates := exclude_route(RejectedRoute, Candidates),
        latest_rejection := GroupReason
    }.

-spec process(T, fun((T) -> T)) -> T when T :: t().
process(Ctx0, Fun) ->
    case Ctx0 of
        #{error := undefined} ->
            with_guard(Fun(Ctx0));
        ErroneousCtx ->
            ErroneousCtx
    end.

-spec with_guard(t()) -> t().
with_guard(Ctx0) ->
    case Ctx0 of
        NoRouteCtx = #{candidates := [], error := undefined} ->
            NoRouteCtx#{error := {rejected_routes, latest_rejected_routes(NoRouteCtx)}};
        Ctx1 ->
            Ctx1
    end.

-spec pipeline(T, [fun((T) -> T)]) -> T when T :: t().
pipeline(Ctx, Funs) ->
    lists:foldl(fun(F, C) -> process(C, F) end, Ctx, Funs).

-spec rejected_routes(t()) -> [hg_route:rejected_route()].
rejected_routes(#{rejections := Rejections}) ->
    {_, RejectedRoutes} = lists:unzip(maps:to_list(Rejections)),
    lists:flatten(RejectedRoutes).

%% @doc List of currently considering candidates.
%%      Route will be choosen among these.
-spec candidates(t()) -> [hg_route:t()].
candidates(#{candidates := Candidates}) ->
    Candidates.

%% @doc Lists candidates provided at very start of routing context formation.
-spec initial_candidates(t()) -> [hg_route:t()].
initial_candidates(#{initial_candidates := InitialCandidates}) ->
    InitialCandidates.

%% @doc Lists candidates (same as 'candidates/1') with only difference that list
%%      includes previously considered candidates that were stashed to be
%%      accounted for later.
%%
%%      For __example__, it may consist of routes that were successfully staged
%%      by limits accountant and thus stashed to be optionally rolled back
%%      later.
-spec considered_candidates(t()) -> [hg_route:t()].
considered_candidates(Ctx) ->
    maps:get(stashed_candidates, Ctx, candidates(Ctx)).

%% @doc Same as 'considered_candidates/1' except for it fallbacks to initial
%%      candidates if no were stashed.
%%
%%      Its use-case is simillar to 'considered_candidates/1' as well.
-spec accounted_candidates(t()) -> [hg_route:t()].
accounted_candidates(Ctx) ->
    maps:get(stashed_candidates, Ctx, initial_candidates(Ctx)).

-spec stash_current_candidates(t()) -> t().
stash_current_candidates(Ctx = #{candidates := []}) ->
    Ctx;
stash_current_candidates(Ctx) ->
    Ctx#{stashed_candidates => candidates(Ctx)}.

-spec choosen_route(t()) -> hg_route:t() | undefined.
choosen_route(#{choosen_route := ChoosenRoute}) ->
    ChoosenRoute.

-spec rejections(t()) -> [{atom(), [hg_route:rejected_route()]}].
rejections(#{rejections := Rejections}) ->
    maps:to_list(Rejections).

%%

-spec route_limits(t()) -> route_limits() | undefined.
route_limits(Ctx) ->
    maps:get(route_limits, Ctx, undefined).

-spec stash_route_limits(route_limits(), t()) -> t().
stash_route_limits(RouteLimits, Ctx) ->
    Ctx#{route_limits => RouteLimits}.

-spec route_scores(t()) -> route_scores() | undefined.
route_scores(Ctx) ->
    maps:get(route_scores, Ctx, undefined).

-spec stash_route_scores(route_scores(), t()) -> t().
stash_route_scores(RouteScores, Ctx) ->
    Ctx#{route_scores => RouteScores}.

-spec add_route_scores(one_route_scores(), t()) -> t().
add_route_scores({PR, Scores}, Ctx) ->
    Ctx#{route_scores => #{PR => Scores}}.

%%

latest_rejected_routes(#{latest_rejection := ReasonGroup, rejections := Rejections}) ->
    {ReasonGroup, maps:get(ReasonGroup, Rejections, [])}.

exclude_route(Route, Routes) ->
    lists:foldr(
        fun(R, RR) ->
            case hg_route:equal(Route, R) of
                true -> RR;
                _Else -> [R | RR]
            end
        end,
        [],
        Routes
    ).

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).

-spec test() -> _.

-spec route_exclusion_test_() -> [_].
route_exclusion_test_() ->
    RouteA = hg_route:new(?prv(1), ?trm(1)),
    RouteB = hg_route:new(?prv(1), ?trm(2)),
    RouteC = hg_route:new(?prv(2), ?trm(1)),
    [
        ?_assertEqual([], exclude_route(RouteA, [])),
        ?_assertEqual([RouteA, RouteB], exclude_route(RouteC, [RouteA, RouteB])),
        ?_assertEqual([RouteA, RouteB], exclude_route(RouteC, [RouteA, RouteB, RouteC])),
        ?_assertEqual([RouteA, RouteC], exclude_route(RouteB, [RouteA, RouteB, RouteC]))
    ].

-spec pipeline_test_() -> [_].
pipeline_test_() ->
    RouteA = hg_route:new(?prv(1), ?trm(1)),
    RouteB = hg_route:new(?prv(1), ?trm(2)),
    RouteC = hg_route:new(?prv(2), ?trm(1)),
    RejectedRouteA = hg_route:to_rejected_route(RouteA, {?MODULE, <<"whatever">>}),
    [
        ?_assertMatch(
            #{
                initial_candidates := [RouteA],
                candidates := [],
                error := {rejected_routes, {test, [RejectedRouteA]}},
                choosen_route := undefined
            },
            pipeline(new([RouteA]), [fun do_reject_route_a/1])
        ),
        ?_assertMatch(
            #{
                initial_candidates := [RouteA, RouteB, RouteC],
                candidates := [RouteA, RouteB, RouteC],
                error := undefined,
                choosen_route := undefined
            },
            pipeline(new([RouteA, RouteB, RouteC]), [])
        ),
        ?_assertMatch(
            #{
                initial_candidates := [RouteA, RouteB, RouteC],
                candidates := [RouteB, RouteC],
                error := undefined,
                choosen_route := undefined
            },
            pipeline(new([RouteA, RouteB, RouteC]), [fun do_reject_route_a/1])
        ),
        ?_assertMatch(
            #{
                initial_candidates := [RouteA, RouteB, RouteC],
                candidates := [RouteB, RouteC],
                error := undefined,
                choosen_route := RouteB
            },
            pipeline(new([RouteA, RouteB, RouteC]), [fun do_reject_route_a/1, fun do_choose_route_b/1])
        )
    ].

do_reject_route_a(Ctx) ->
    RouteA = hg_route:new(?prv(1), ?trm(1)),
    reject(test, hg_route:to_rejected_route(RouteA, {?MODULE, <<"whatever">>}), Ctx).

do_choose_route_b(Ctx) ->
    RouteB = hg_route:new(?prv(1), ?trm(2)),
    set_choosen(RouteB, #{}, Ctx).

-endif.
