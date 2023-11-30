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
-export([process/2]).
-export([with_guard/1]).
-export([pipeline/2]).

-type t() :: #{
    initial_candidates := [hg_route:t()],
    candidates := [hg_route:t()],
    rejections := #{atom() => [hg_route:rejected_route()]},
    error := Reason :: term() | undefined,
    choosen_route := hg_route:t() | undefined,
    choice_meta := hg_routing:route_choice_context() | undefined,
    fail_rates => [hg_routing:fail_rated_route()]
}.

-export_type([t/0]).

%%

-spec new([hg_route:t()]) -> t().
new(Candidates) ->
    #{
        initial_candidates => Candidates,
        candidates => Candidates,
        rejections => #{},
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
        rejections => Rejections#{GroupReason => RejectedList},
        candidates => exclude_route(RejectedRoute, Candidates)
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
            NoRouteCtx#{error := {rejected_routes, rejected_routes(NoRouteCtx)}};
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

-spec candidates(t()) -> [hg_route:t()].
candidates(#{candidates := Candidates}) ->
    Candidates.

-spec initial_candidates(t()) -> [hg_route:t()].
initial_candidates(#{initial_candidates := InitialCandidates}) ->
    InitialCandidates.

-spec rejections(t()) -> [{atom(), [hg_route:rejected_route()]}].
rejections(#{rejections := Rejections}) ->
    maps:to_list(Rejections).

%%

exclude_route(Route, Routes) ->
    lists:foldr(
        fun(R, RR) ->
            case hg_route:equal(Route, R) of
                true -> RR;
                _else -> [R | RR]
            end
        end,
        [],
        Routes
    ).
