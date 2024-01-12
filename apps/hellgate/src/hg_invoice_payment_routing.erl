-module(hg_invoice_payment_routing).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include("hg_invoice_payment.hrl").

%% API
-export([get_explanation/1]).

-type st() :: #st{}.
-type explanation() :: #payproc_InvoicePaymentExplanation{}.

-spec get_explanation(st()) -> explanation().
get_explanation(#st{
    routes = Routes,
    candidate_routes = CandidateRoutes,
    route_scores = RouteScores,
    route_limits = RouteLimits
}) ->
    case Routes of
        [] ->
            %% If there's no routes even tried, then no explanation can be provided
            undefined;
        [Route | _] ->
            CandidatesExplanation = maybe_explain_candidate_routes(CandidateRoutes, RouteScores, RouteLimits),
            ChosenRouteScore = hg_maybe:apply(fun(A) -> maps:get(Route, A, undefined) end, RouteScores),
            ChosenRouteLimits = hg_maybe:apply(fun(A) -> maps:get(Route, A, undefined) end, RouteLimits),
            #payproc_InvoicePaymentExplanation{
                explained_routes = [
                    route_explanation(chosen, Route, ChosenRouteScore, ChosenRouteLimits)
                    | CandidatesExplanation
                ]
            }
    end.

maybe_explain_candidate_routes([], _RouteScores, _RouteLimits) ->
    [];
maybe_explain_candidate_routes([CandidateRoute | CandidateRoutes], RouteScores, RouteLimits) ->
    RouteScore = hg_maybe:apply(fun(A) -> maps:get(CandidateRoute, A, undefined) end, RouteScores),
    RouteLimit = hg_maybe:apply(fun(A) -> maps:get(CandidateRoute, A, undefined) end, RouteLimits),
    [
        route_explanation(candidate, CandidateRoute, RouteScore, RouteLimit)
        | maybe_explain_candidate_routes(CandidateRoutes, RouteScores, RouteLimits)
    ].

route_explanation(Type, Route, Scores, Limits) ->
    IsChosen =
        case Type of
            chosen ->
                true;
            candidate ->
                false
        end,
    #payproc_InvoicePaymentRouteExplanation{
        route = Route,
        is_chosen = IsChosen,
        scores = Scores,
        limits = Limits
    }.
