-module(hg_routing_explanation).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("hellgate/include/hg_invoice_payment.hrl").

%% API
-export([get_explanation/2]).

-type st() :: #st{}.
-type explanation() :: dmsl_payproc_thrift:'InvoicePaymentExplanation'().

-type route() :: hg_route:payment_route().
-type scores() :: hg_routing:scores().
-type limits() :: hg_routing:limits().
-type route_with_context() :: #{
    route := route(),
    scores := hg_routing:route_scores() | undefined,
    limits := [hg_limiter:turnover_limit_value()] | undefined
}.

-spec get_explanation(st(), hg_invoice_payment:opts()) -> explanation().
get_explanation(
    #st{
        payment = Payment,
        routes = Routes,
        candidate_routes = CandidateRoutes,
        route_scores = RouteScores,
        route_limits = RouteLimits
    },
    Opts
) ->
    case Routes of
        [] ->
            %% If there's no routes even tried, then no explanation can be provided
            throw(#payproc_RouteNotChosen{});
        [Route | AttemptedRoutes] ->
            CandidateRoutesWithoutChosenRoute = exclude_chosen_route_from_candidates(CandidateRoutes, Route),
            ChosenRWC = make_route_with_context(Route, RouteScores, RouteLimits),
            AttemptedExplanation = maybe_explain_attempted_routes(
                AttemptedRoutes, RouteScores, RouteLimits
            ),
            CandidatesExplanation = maybe_explain_candidate_routes(
                CandidateRoutesWithoutChosenRoute, RouteScores, RouteLimits, ChosenRWC
            ),

            Varset = gather_varset(Payment, Opts),
            #payproc_InvoicePaymentExplanation{
                explained_routes = lists:flatten([
                    route_explanation(chosen, ChosenRWC, ChosenRWC),
                    AttemptedExplanation,
                    CandidatesExplanation
                ]),
                used_varset = Varset
            }
    end.

exclude_chosen_route_from_candidates(CandidateRoutes, Route) when is_list(CandidateRoutes) ->
    CandidateRoutes -- [Route];
exclude_chosen_route_from_candidates(_UndefinedCandidates, _Route) ->
    [].

-spec make_route_with_context(route(), scores(), limits()) -> route_with_context().
make_route_with_context(Route, RouteScores, RouteLimits) ->
    #{
        route => Route,
        scores => hg_maybe:apply(fun(A) -> maps:get(Route, A, undefined) end, RouteScores),
        limits => hg_maybe:apply(fun(A) -> maps:get(Route, A, undefined) end, RouteLimits)
    }.

maybe_explain_attempted_routes([], _RouteScores, _RouteLimits) ->
    [];
maybe_explain_attempted_routes([AttemptedRoute | AttemptedRoutes], RouteScores, RouteLimits) ->
    RouteWithContext = make_route_with_context(AttemptedRoute, RouteScores, RouteLimits),
    [
        route_explanation(attempted, RouteWithContext, RouteWithContext)
        | maybe_explain_attempted_routes(AttemptedRoutes, RouteScores, RouteLimits)
    ].

maybe_explain_candidate_routes([], _RouteScores, _RouteLimits, _ChosenRWC) ->
    [];
maybe_explain_candidate_routes([CandidateRoute | CandidateRoutes], RouteScores, RouteLimits, ChosenRWC) ->
    RouteWithContext = make_route_with_context(CandidateRoute, RouteScores, RouteLimits),
    [
        route_explanation(candidate, RouteWithContext, ChosenRWC)
        | maybe_explain_candidate_routes(CandidateRoutes, RouteScores, RouteLimits, ChosenRWC)
    ].

route_explanation(chosen, RouteWithContext, _ChosenRoute) ->
    #{
        route := Route,
        scores := Scores,
        limits := Limits
    } = RouteWithContext,
    #payproc_InvoicePaymentRouteExplanation{
        route = Route,
        is_chosen = true,
        scores = Scores,
        limits = Limits,
        rejection_description = <<"This route was chosen.">>
    };
route_explanation(attempted, RouteWithContext, _ChosenRoute) ->
    #{
        route := Route,
        scores := Scores,
        limits := Limits
    } = RouteWithContext,
    #payproc_InvoicePaymentRouteExplanation{
        route = Route,
        is_chosen = false,
        scores = Scores,
        limits = Limits,
        rejection_description = <<"This route was attempted, but wasn't succesfull.">>
    };
route_explanation(candidate, RouteWithContext, ChosenRoute) ->
    #{
        route := Route,
        scores := Scores,
        limits := Limits
    } = RouteWithContext,
    #payproc_InvoicePaymentRouteExplanation{
        route = Route,
        is_chosen = false,
        scores = Scores,
        limits = Limits,
        rejection_description = candidate_rejection_explanation(RouteWithContext, ChosenRoute)
    }.

candidate_rejection_explanation(
    #{scores := undefined, limits := undefined},
    _ChosenRoute
) ->
    <<"Not enough information to make judgement. Payment was done before relevant changes were done.">>;
candidate_rejection_explanation(
    #{scores := undefined, limits := RouteLimits},
    _ChosenRoute
) ->
    IfEmpty =
        <<"We only know about limits for this route, but no limit",
            " was reached, if you see this message contact developer.">>,
    check_route_limits(RouteLimits, IfEmpty);
candidate_rejection_explanation(
    R = #{scores := #domain_PaymentRouteScores{blacklist_condition = 1}},
    _
) ->
    check_route_blacklisted(R);
candidate_rejection_explanation(
    #{scores := RouteScores, limits := RouteLimits},
    #{scores := ChosenScores}
) when RouteScores =:= ChosenScores ->
    IfEmpty = <<"This route has the same score as the chosen route, but wasn't chosen due to order in ruleset.">>,
    check_route_limits(RouteLimits, IfEmpty);
candidate_rejection_explanation(
    #{scores := RouteScores, limits := RouteLimits},
    #{scores := ChosenScores}
) when RouteScores > ChosenScores ->
    IfEmpty = <<"No explanation for rejection can be found. Check in with developer.">>,
    check_route_limits(RouteLimits, IfEmpty);
candidate_rejection_explanation(
    R = #{scores := RouteScores, limits := RouteLimits},
    #{scores := ChosenScores}
) when RouteScores < ChosenScores ->
    Explanation0 = check_route_blacklisted(R),
    Explanation1 = check_route_scores(RouteScores, ChosenScores),
    Explanation2 = check_route_limits(RouteLimits, <<"">>),
    genlib_string:join(<<" ">>, [Explanation0, Explanation1, Explanation2]).

check_route_limits(RouteLimits, IfEmpty) ->
    case check_route_limits(RouteLimits) of
        [] ->
            IfEmpty;
        Result ->
            genlib_string:join(<<" ">>, Result)
    end.

check_route_limits([]) ->
    [];
check_route_limits([TurnoverLimitValue | Rest]) ->
    case TurnoverLimitValue of
        #payproc_TurnoverLimitValue{
            limit = #domain_TurnoverLimit{
                id = LimitID,
                upper_boundary = UpperBoundary
            },
            value = Value
        } when Value > UpperBoundary ->
            [
                format(
                    "Limit with id ~p was exceeded with upper_boundary being ~p and limit value being ~p.",
                    [LimitID, UpperBoundary, Value]
                )
                | check_route_limits(Rest)
            ];
        _ ->
            check_route_limits(Rest)
    end.

check_route_scores(
    #domain_PaymentRouteScores{
        availability_condition = 0,
        availability = Av
    },
    _ChoseScores
) ->
    AvailabilityConfig = maps:get(availability, genlib_app:env(hellgate, fault_detector, #{}), #{}),
    CriticalFailRate = maps:get(critical_fail_rate, AvailabilityConfig, 0.7),
    format(
        "Availability reached critical level with availability of ~p, while threshold is ~p.",
        [1.0 - Av, CriticalFailRate]
    );
check_route_scores(
    #domain_PaymentRouteScores{
        conversion_condition = 0,
        conversion = Cv
    },
    _ChoseScores
) ->
    ConversionConfig = maps:get(conversion, genlib_app:env(hellgate, fault_detector, #{}), #{}),
    CriticalFailRate = maps:get(critical_fail_rate, ConversionConfig, 0.7),
    format(
        "Conversion reached critical level with conversion of ~p, while threshold is ~p.",
        [1.0 - Cv, CriticalFailRate]
    );
check_route_scores(
    #domain_PaymentRouteScores{
        terminal_priority_rating = Rating0
    },
    #domain_PaymentRouteScores{
        terminal_priority_rating = Rating1
    }
) when Rating0 < Rating1 ->
    format("Priority of this route was less than in chosen route, where ~p < ~p.", [Rating0, Rating1]);
check_route_scores(
    #domain_PaymentRouteScores{
        route_pin = Pin0
    },
    #domain_PaymentRouteScores{
        route_pin = Pin1
    }
) when Pin0 < Pin1 ->
    format("Pin wasn't the same as in chosen route ~p < ~p.", [Pin0, Pin1]);
check_route_scores(
    #domain_PaymentRouteScores{
        random_condition = Random0
    },
    #domain_PaymentRouteScores{
        random_condition = Random1
    }
) when Random0 < Random1 ->
    format("Random condition wasn't the same as in chosen route ~p < ~p.", [Random0, Random1]);
check_route_scores(
    #domain_PaymentRouteScores{
        availability = Av0
    },
    #domain_PaymentRouteScores{
        availability = Av1
    }
) when Av0 < Av1 ->
    format("Avaliability is less than in chosen route ~p < ~p.", [Av0, Av1]);
check_route_scores(
    #domain_PaymentRouteScores{
        conversion = Cv0
    },
    #domain_PaymentRouteScores{
        conversion = Cv1
    }
) when Cv0 < Cv1 ->
    format("Conversion is less than in chosen route ~p < ~p.", [Cv0, Cv1]).

check_route_blacklisted(#{route := R, scores := #domain_PaymentRouteScores{blacklist_condition = 1}}) ->
    format("Route was blacklisted ~w.", [R]);
check_route_blacklisted(_) ->
    <<"">>.

gather_varset(Payment, Opts) ->
    #domain_InvoicePayment{
        cost = Cost,
        payer = Payer
    } = Payment,
    #domain_Party{
        id = PartyID
    } = get_party(Opts),
    #domain_Shop{
        id = ShopID,
        category = Category
    } = get_shop(Opts),
    #payproc_Varset{
        category = Category,
        currency = Cost#domain_Cash.currency,
        amount = Cost,
        shop_id = ShopID,
        payment_tool = hg_invoice_payment:get_payer_payment_tool(Payer),
        party_id = PartyID
    }.

get_party(#{party := Party}) ->
    Party.

get_shop(#{party := Party, invoice := Invoice}) ->
    #domain_Invoice{shop_id = ShopID} = Invoice,
    hg_party:get_shop(ShopID, Party).

format(Format, Data) ->
    erlang:iolist_to_binary(io_lib:format(Format, Data)).
