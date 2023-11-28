-module(hg_fkn_routing).

-type ctx() :: #{
    initial_candidates := [hg_routing:route()],
    candidates := [hg_routing:route()],
    rejections := #{atom() => [hg_routing:rejected_route()]},
    error := Reason :: term() | undefined,
    choosen_route := hg_routing:route() | undefined,
    choice_meta := hg_routing:route_choice_context() | undefined
}.

-export([new/0]).
-export([new/1]).
-export([set_choosen/3]).
-export([set_error/2]).
-export([reject/3]).
-export([reject_route/4]).
-export([all_rejected_routes/1]).
-export([process_guarded/2]).
-export([pipeline_guarded/2]).

%%

-spec new() -> ctx().
new() ->
    new([]).

-spec new([hg_routing:route()]) -> ctx().
new(Candidates) ->
    #{
        initial_candidates => Candidates,
        candidates => Candidates,
        rejections => #{},
        error => undefined,
        choosen_route => undefined,
        choice_meta => undefined
    }.

-spec set_choosen(hg_routing:route(), hg_routing:route_choice_context(), ctx()) -> ctx().
set_choosen(Route, ChoiceMeta, Ctx) ->
    Ctx#{choosen_route => Route, choice_meta => ChoiceMeta}.

-spec set_error(term(), ctx()) -> ctx().
set_error(ErrorReason, Ctx) ->
    Ctx#{error => ErrorReason}.

-spec reject(atom(), hg_routing:rejected_route(), ctx()) -> ctx().
reject(GroupReason, RejectedRoute, Ctx = #{rejections := Rejections, candidates := Candidates}) ->
    RejectedList = maps:get(GroupReason, Rejections, []) ++ [RejectedRoute],
    Ctx#{
        rejections => Rejections#{GroupReason => RejectedList},
        candidates => exclude_rejected(RejectedRoute, Candidates)
    }.

-spec reject_route(atom(), term(), hg_routing:route(), ctx()) -> ctx().
reject_route(GroupReason, Reason, Route, Ctx) ->
    reject(GroupReason, hg_routing:to_rejected_route(Route, Reason), Ctx).

-spec process_guarded(T, fun((T) -> T)) -> T when T :: ctx().
process_guarded(Ctx0, Fun) ->
    case Ctx0 of
        #{error := undefined} ->
            case Fun(Ctx0) of
                NoRouteCtx = #{candidates := []} ->
                    NoRouteCtx#{error := {rejected_routes, all_rejected_routes(NoRouteCtx)}};
                Ctx1 ->
                    Ctx1
            end;
        ErroneousCtx ->
            ErroneousCtx
    end.

-spec pipeline_guarded(T, [fun((T) -> T)]) -> T when T :: ctx().
pipeline_guarded(Ctx, Funs) ->
    lists:foldl(fun(F, C) -> process_guarded(C, F) end, Ctx, Funs).

-spec all_rejected_routes(ctx()) -> [hg_routing:rejected_route()].
all_rejected_routes(#{rejections := Rejections}) ->
    {_, RejectedRoutes} = lists:unzip(maps:to_list(Rejections)),
    lists:flatten(RejectedRoutes).

%%

exclude_rejected({PRef, TRef, _}, Routes) ->
    do_exclude(PRef, TRef, Routes).

do_exclude(PRef, TRef, Routes) ->
    lists:foldr(
        fun
            ({route, Prv, Trm, _, _, _, _}, RR) when Prv =:= PRef andalso Trm =:= TRef -> RR;
            (R, RR) -> [R | RR]
        end,
        [],
        Routes
    ).
