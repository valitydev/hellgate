-module(hg_routing).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%%
-export([prepare_log_message/1]).
-export([get_logger_metadata/2]).
-export([get_routes/1]).
-export([filter_routes/2]).
-export([choose_route/1]).

%%

-type get_route_params() :: #{
    predestination := hg_route_collector:route_predestination(),
    revision := hg_route_collector:revision(),
    varset := hg_route_collector:varset(),
    payment_institution := hg_route_collector:payment_institution(),
    pin_context := hg_route_collector:gather_route_context(),
    blacklist_context => hg_route_collector:blacklist_context()
}.

-type route_choice_context() :: #{
    chosen_route => hg_route:t(),
    preferable_route => hg_route:t(),
    % Contains one of the field names defined in #domain_PaymentRouteScores{}
    reject_reason => atom()
}.

-type rejection_group() :: atom().
-type filter_routes_fun() :: fun((filter_routes_result()) -> filter_routes_result()).

-type get_routes_result() :: #{
    routes := [hg_route:t()],
    rejected_routes => [hg_route:t()],
    error => hg_route_collector:get_routes_error()
}.

-type filter_routes_result() :: #{
    routes := [hg_route:t()],
    rejected_routes => [hg_route:t()],
    latest_rejected_group => rejection_group() | undefined,
    rejection_groups => #{rejection_group() => [hg_route:t()]},
    considered_routes => [hg_route:t()],
    route_limits => limits(),
    route_scores => scores()
}.

-type route_scores() :: #domain_PaymentRouteScores{}.
-type limits() :: #{hg_route:payment_route() => [hg_limiter:turnover_limit_value()]}.
-type scores() :: #{hg_route:payment_route() => hg_routing:route_scores()}.
-type route_predestination() :: payment | recurrent_payment.

-type misconfiguration_error() :: {misconfiguration, {routing_decisions, _} | {routing_candidate, _}}.

-export_type([get_route_params/0]).
-export_type([get_routes_result/0]).
-export_type([filter_routes_result/0]).
-export_type([route_scores/0]).
-export_type([limits/0]).
-export_type([scores/0]).
-export_type([route_predestination/0]).

-define(ZERO, 0).

-spec prepare_log_message(misconfiguration_error()) -> {io:format(), [term()]}.
prepare_log_message({misconfiguration, {routing_decisions, Details}}) ->
    {"PaymentRoutingDecisions couldn't be reduced to candidates, ~p", [Details]};
prepare_log_message({misconfiguration, {routing_candidate, Candidate}}) ->
    {"PaymentRoutingCandidate couldn't be reduced, ~p", [Candidate]};
prepare_log_message({misconfiguration, {payment_routing_rules, empty}}) ->
    {"PaymentRoutingRules are empty", []}.

-spec get_logger_metadata(route_choice_context(), hg_route_collector:revision()) -> LoggerFormattedMetadata :: map().
get_logger_metadata(RouteChoiceContext, Revision) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{K => format_logger_metadata(K, V, Revision)}
        end,
        #{},
        RouteChoiceContext
    ).

format_logger_metadata(reject_reason, Reason, _) ->
    Reason;
format_logger_metadata(Meta, Route, Revision) when
    Meta =:= chosen_route;
    Meta =:= preferable_route
->
    ProviderRef = #domain_ProviderRef{id = ProviderID} = hg_route:provider_ref(Route),
    TerminalRef = #domain_TerminalRef{id = TerminalID} = hg_route:terminal_ref(Route),
    #domain_Provider{name = ProviderName} = hg_domain:get(Revision, {provider, ProviderRef}),
    #domain_Terminal{name = TerminalName} = hg_domain:get(Revision, {terminal, TerminalRef}),
    genlib_map:compact(#{
        provider => #{id => ProviderID, name => ProviderName},
        terminal => #{id => TerminalID, name => TerminalName},
        priority => hg_route:priority(Route),
        weight => hg_route:weight(Route)
    }).

-spec get_routes(get_route_params()) -> get_routes_result().
get_routes(
    #{
        predestination := Predestination,
        revision := Revision,
        varset := VS,
        payment_institution := PI,
        pin_context := PinCtx
    } = Params
) ->
    Result = #{routes := Routes0} = hg_route_collector:get_routes(Revision, VS, PI, PinCtx),
    Routes1 = hg_route_collector:fill_accepted(Predestination, Revision, VS, Routes0),
    Routes2 = hg_route_collector:fill_prohibition(Revision, VS, PI, Routes1),
    Routes3 = hg_route_collector:fill_fd_overrides(Revision, Routes2),
    Routes4 =
        case maps:get(blacklist_context, Params, undefined) of
            undefined ->
                Routes3;
            BlCtx ->
                hg_route_collector:fill_blacklist(BlCtx, Routes3)
        end,
    Routes5 = hg_route_fd:fill(Routes4),
    genlib_map:compact(
        maps:merge(
            #{error => maps:get(error, Result, undefined)},
            filter(hg_route_balancer:fill(Routes5), [{accepted, false}, {prohibit, true}, {blacklisted, 1}])
        )
    ).

-spec filter_routes(filter_routes_result(), [filter_routes_fun()]) -> filter_routes_result().
filter_routes(Result0, WithFilterFuns) ->
    lists:foldl(fun(Fun, Result) -> Fun(Result) end, Result0, WithFilterFuns).

filter(Routes, Keys) ->
    lists:foldr(
        fun(Route, #{routes := Accepted, rejected_routes := Rejected} = Acc) ->
            case route_rejection_reason(Route, Keys) of
                undefined ->
                    Acc#{routes => [Route | Accepted]};
                Reason ->
                    Acc#{rejected_routes => [hg_route:set_rejection_reason(Reason, Route) | Rejected]}
            end
        end,
        #{routes => [], rejected_routes => []},
        Routes
    ).

route_rejection_reason(Route, Keys) ->
    Data = hg_route:route_data(Route),
    get_rejection_reason(Keys, Data).

get_rejection_reason([{Key, Value} | Rest], Data) ->
    case maps:get(Key, Data, undefined) of
        {Value, Reason} ->
            {Key, {Value, Reason}};
        Value ->
            {Key, Value};
        _ ->
            get_rejection_reason(Rest, Data)
    end;
get_rejection_reason([], _) ->
    undefined.

-spec choose_route([hg_route:t()]) -> {hg_route:t(), route_choice_context()}.
choose_route(Routes) ->
    {ChosenScoredRoute, IdealRoute} = find_best_routes(Routes),
    RouteChoiceContext = get_route_choice_context(ChosenScoredRoute, IdealRoute),
    {ChosenScoredRoute, RouteChoiceContext}.
%%

-spec find_best_routes([hg_route:t()]) -> {Chosen :: hg_route:t(), Ideal :: hg_route:t()}.
find_best_routes([Route]) ->
    {Route, Route};
find_best_routes([First | Rest]) ->
    lists:foldl(
        fun(RouteIn, {CurrentRouteChosen, CurrentRouteIdeal}) ->
            NewRouteIdeal = select_better_route_ideal(RouteIn, CurrentRouteIdeal),
            NewRouteChosen = select_better_route(RouteIn, CurrentRouteChosen),
            {NewRouteChosen, NewRouteIdeal}
        end,
        {First, First},
        Rest
    ).

select_better_route_ideal(Left, Right) ->
    IdealLeft = set_ideal_score(Left),
    IdealRight = set_ideal_score(Right),
    case select_better_route(IdealLeft, IdealRight) of
        IdealLeft -> Left;
        IdealRight -> Right
    end.

set_ideal_score(Route0) ->
    Route1 = hg_route:set_availability(1, 1.0, Route0),
    hg_route:set_conversion(1, 1.0, Route1).

select_better_route(Left, Right) ->
    LeftPin = hg_route:pin_hash(Left),
    RightPin = hg_route:pin_hash(Right),
    Res =
        case {LeftPin, RightPin} of
            _ when LeftPin /= ?ZERO, RightPin /= ?ZERO, RightPin == LeftPin ->
                select_better_pinned_route(Left, Right);
            _ ->
                select_better_regular_route(Left, Right)
        end,
    Res.

select_better_pinned_route(Left, Right) ->
    LeftScore = (hg_route:score(Left))#domain_PaymentRouteScores{
        random_condition = 0,
        route_pin = erlang:phash2({
            hg_route:pin_hash(Left),
            hg_route:provider_ref(Left),
            hg_route:terminal_ref(Left)
        })
    },
    RightScore = (hg_route:score(Right))#domain_PaymentRouteScores{
        random_condition = 0,
        route_pin = erlang:phash2({
            hg_route:pin_hash(Right),
            hg_route:provider_ref(Right),
            hg_route:terminal_ref(Right)
        })
    },

    case max(LeftScore, RightScore) of
        LeftScore ->
            Left;
        RightScore ->
            Right
    end.

select_better_regular_route(Left, Right) ->
    LeftScore = (hg_route:score(Left))#domain_PaymentRouteScores{
        route_pin = 0
    },
    RightScore = (hg_route:score(Right))#domain_PaymentRouteScores{
        route_pin = 0
    },
    case max(LeftScore, RightScore) of
        LeftScore ->
            Left;
        RightScore ->
            Right
    end.

get_route_choice_context(SameRoute, SameRoute) ->
    #{
        chosen_route => SameRoute
    };
get_route_choice_context(ChosenRoute, IdealRoute) ->
    #{
        chosen_route => ChosenRoute,
        preferable_route => IdealRoute,
        reject_reason => map_route_switch_reason(hg_route:score(ChosenRoute), hg_route:score(IdealRoute))
    }.

map_route_switch_reason(SameScores, SameScores) ->
    unknown;
map_route_switch_reason(RealScores, IdealScores) when
    is_record(RealScores, 'domain_PaymentRouteScores'); is_record(IdealScores, 'domain_PaymentRouteScores')
->
    Zipped = lists:zip(tuple_to_list(RealScores), tuple_to_list(IdealScores)),
    DifferenceIdx = find_idx_of_difference(Zipped),
    lists:nth(DifferenceIdx, record_info(fields, 'domain_PaymentRouteScores')).

find_idx_of_difference(ZippedList) ->
    find_idx_of_difference(ZippedList, 0).

find_idx_of_difference([{Same, Same} | Rest], I) ->
    find_idx_of_difference(Rest, I + 1);
find_idx_of_difference(_, I) ->
    I.

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-spec test() -> _.
-type testcase() :: {_, fun(() -> _)}.

-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).

-spec record_comparsion_test() -> _.
record_comparsion_test() ->
    Bigger = new_route(42, 42, 0, {1, 0.5}, {1, 0.5}),
    Middle = new_route(50, 50, 0, {1, 0.1}, {1, 0.5}),
    Smaller = new_route(99, 99, 0, {0, 0.1}, {1, 0.5}),
    ?assertEqual(Bigger, select_better_route(Bigger, Smaller)),
    ?assertEqual(Middle, select_better_route(Middle, Smaller)),
    ?assertEqual(Bigger, select_better_route(Bigger, Middle)),
    ?assertMatch(
        {?trm(42), _},
        balance_and_choose_route([
            Bigger,
            Smaller
        ])
    ),
    ?assertMatch(
        {?trm(50), _},
        balance_and_choose_route([
            Middle,
            Smaller
        ])
    ),
    ?assertMatch(
        {?trm(42), _},
        balance_and_choose_route([
            Middle,
            Bigger
        ])
    ).

-spec pin_random_test() -> _.
pin_random_test() ->
    Pin = #{email => <<"example@mail.com">>},
    Route1 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin),
    Route2 = new_route(2, 2, 50, {1, 0.0}, {1, 0.0}, Pin),
    lists:foldl(
        fun(_I, Acc) ->
            {ST, _} = Route = balance_and_choose_route([Route1, Route2]),
            case Acc of
                undefined ->
                    Route;
                {ST, _} ->
                    Route;
                _ ->
                    error({Route, Acc})
            end
        end,
        undefined,
        lists:seq(0, 1000)
    ).

-spec diff_pin_test() -> _.
diff_pin_test() ->
    Pin = #{email => <<"example@mail.com">>},
    Route1 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin),
    Route2 = new_route(1, 2, 50, {1, 0.0}, {1, 0.0}, Pin),
    Route3 = new_route(1, 3, 50, {1, 0.0}, {1, 0.0}, Pin#{client_ip => <<"IP">>}),
    {I1, I2, I3} = lists:foldl(
        fun(_I, {Iter1, Iter2, Iter3}) ->
            {ST, _} = balance_and_choose_route([Route1, Route2, Route3]),
            case ST of
                ?trm(1) ->
                    {Iter1 + 1, Iter2, Iter3};
                ?trm(2) ->
                    {Iter1, Iter2 + 1, Iter3};
                ?trm(3) ->
                    {Iter1, Iter2, Iter3 + 1}
            end
        end,
        {0, 0, 0},
        lists:seq(0, 1000)
    ),
    case {I1, I2} of
        {0, S} when S > 400 ->
            true;
        {S, 0} when S > 400 ->
            true;
        SomethingElse ->
            error({{i1, i2}, SomethingElse})
    end,
    case I3 of
        _ when I3 > 300 ->
            true;
        _ ->
            error({i3, I3})
    end.

-spec pin_weight_test() -> _.
pin_weight_test() ->
    Pin0 = #{email => <<"example@mail.com">>},
    Pin1 = #{email => <<"example1@mail.com">>},
    Route1 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin0),
    Route2 = new_route(1, 2, 50, {1, 0.0}, {1, 0.0}, Pin0),
    Route3 = new_route(1, 1, 50, {1, 0.0}, {1, 0.0}, Pin1),
    Route4 = new_route(1, 2, 50, {1, 0.0}, {1, 0.0}, Pin1),
    true = lists:foldl(
        fun(_I, _A) ->
            {BalancedRoute1, _} = balance_and_choose_route([Route1, Route2]),
            {BalancedRoute2, _} = balance_and_choose_route([Route3, Route4]),
            case true of
                _ when BalancedRoute1 == ?trm(1), BalancedRoute2 == ?trm(2) ->
                    true;
                _ ->
                    error({BalancedRoute1, BalancedRoute2})
            end
        end,
        true,
        lists:seq(0, 1000)
    ).

new_route(PNum, TNum, Weight, {ACond, AValue}, {CCond, CValue}) ->
    new_route(PNum, TNum, Weight, {ACond, AValue}, {CCond, CValue}, #{}).

new_route(PNum, TNum, Weight, {ACond, AValue}, {CCond, CValue}, Pin) ->
    Route0 = hg_route:new(1, ?prv(PNum), ?trm(TNum), Weight, ?DOMAIN_CANDIDATE_PRIORITY, Pin),
    Route1 = hg_route:set_availability(ACond, AValue, Route0),
    hg_route:set_conversion(CCond, CValue, Route1).

balance_and_choose_route(Routes0) ->
    Routes1 = hg_route_balancer:fill(Routes0),
    {Route, Ctx} = choose_route(Routes1),
    {hg_route:terminal_ref(Route), {Route, Ctx}}.

-spec filter_routes_splits_accepted_and_rejected_test() -> _.
filter_routes_splits_accepted_and_rejected_test() ->
    AcceptedRoute = new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
    RejectedByTerms = hg_route:set_accepted(
        {false, {rejected, {'ProvisionTermSet', undefined}}},
        new_route(1, 2, 0, {1, 1.0}, {1, 1.0})
    ),
    RejectedByProhibition = hg_route:set_prohibit(
        {true, <<"blocked">>},
        new_route(1, 3, 0, {1, 1.0}, {1, 1.0})
    ),
    RejectedByBlacklist = hg_route:set_blacklisted(
        1,
        new_route(1, 4, 0, {1, 1.0}, {1, 1.0})
    ),
    Rejected = [
        hg_route:set_rejection_reason(
            {accepted, {false, {rejected, {'ProvisionTermSet', undefined}}}}, RejectedByTerms
        ),
        hg_route:set_rejection_reason({prohibit, {true, <<"blocked">>}}, RejectedByProhibition),
        hg_route:set_rejection_reason({blacklisted, 1}, RejectedByBlacklist)
    ],
    Result = #{
        routes => [AcceptedRoute],
        rejected_routes => Rejected
    },
    ?assertMatch(
        Result,
        filter(
            [AcceptedRoute, RejectedByTerms, RejectedByProhibition, RejectedByBlacklist],
            [{accepted, false}, {prohibit, true}, {blacklisted, 1}]
        )
    ).

-spec preferable_route_scoring_test_() -> [testcase()].
preferable_route_scoring_test_() ->
    RouteFallback0 = hg_route:new(1, ?prv(2), ?trm(99), 0, 0, #{}),
    RouteFallback1 = hg_route:set_availability(1, 1.0, RouteFallback0),
    RouteFallback2 = hg_route:set_conversion(1, 1.0, RouteFallback1),
    [
        ?_assertMatch(
            {?trm(1), _},
            balance_and_choose_route([
                new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
                RouteFallback2
            ])
        ),
        ?_assertMatch(
            {?trm(3), _},
            balance_and_choose_route([
                new_route(1, 1, 0, {0, 0.6}, {0, 0.4}),
                new_route(1, 2, 0, {0, 0.6}, {0, 0.4}),
                new_route(1, 3, 0, {1, 1.0}, {1, 1.0})
            ])
        ),
        ?_assertMatch(
            {
                ?trm(99),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(1)},
                    reject_reason := availability_condition
                }}
            },
            balance_and_choose_route([
                new_route(1, 1, 0, {0, 0.6}, {0, 0.4}),
                RouteFallback2
            ])
        ),
        ?_assertMatch(
            {
                ?trm(99),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(1)},
                    reject_reason := conversion_condition
                }}
            },
            balance_and_choose_route([
                new_route(1, 1, 0, {1, 0.9}, {0, 0.2}),
                RouteFallback2
            ])
        ),
        ?_assertMatch(
            {
                ?trm(1),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(2)},
                    reject_reason := conversion
                }}
            },
            balance_and_choose_route([
                new_route(1, 2, 0, {1, 1.0}, {1, 0.9}),
                new_route(1, 1, 0, {1, 1.0}, {1, 1.0})
            ])
        ),
        ?_assertMatch(
            {
                ?trm(1),
                {_, #{
                    preferable_route := #{terminal_ref := ?trm(2)},
                    reject_reason := availability
                }}
            },
            balance_and_choose_route([
                new_route(1, 2, 0, {1, 0.9}, {1, 0.9}),
                new_route(1, 1, 0, {1, 1.0}, {1, 1.0}),
                RouteFallback2
            ])
        )
    ].

-spec prefer_priority_over_availability_test() -> _.
prefer_priority_over_availability_test() ->
    Route1 = new_route(1, 1, 0, {1, 0.7}, {1, 0.7}),
    Route2 = hg_route:set_priority(1005, new_route(2, 2, 0, {1, 0.5}, {1, 0.7})),
    Route3 = new_route(3, 3, 0, {1, 0.7}, {1, 0.7}),
    Routes = [Route1, Route2, Route3],

    ?assertMatch({?trm(2), _}, balance_and_choose_route(Routes)).

-spec prefer_priority_over_conversion_test() -> _.
prefer_priority_over_conversion_test() ->
    Route1 = new_route(1, 1, 0, {1, 0.7}, {1, 0.7}),
    Route2 = hg_route:set_priority(1005, new_route(2, 2, 0, {1, 0.7}, {1, 0.5})),
    Route3 = new_route(3, 3, 0, {1, 0.7}, {1, 0.7}),
    Routes = [Route1, Route2, Route3],

    ?assertMatch({?trm(2), _}, balance_and_choose_route(Routes)).

-endif.
