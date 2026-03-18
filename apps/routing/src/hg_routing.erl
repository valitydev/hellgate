%%% Naïve routing oracle

-module(hg_routing).

-compile({no_auto_import, [error/1]}).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-export([get_routes/1]).
-export([filter_routes/2]).
-export([gather_routes/5]).
-export([resolve/1]).
-export([rate_routes/1]).
-export([choose_route/1]).
-export([choose_rated_route/1]).

-export([get_payment_terms/3]).
-export([get_provision_terms/3]).

-export([get_logger_metadata/2]).
-export([prepare_log_message/1]).

%%

-export([filter_by_critical_provider_status/1]).
-export([filter_by_blacklist/2]).
-export([choose_route_with_ctx/1]).
-export([get_error/1]).
-export([rejected_routes/1]).
-export([rejections/1]).
-export([candidates/1]).
-export([considered_candidates/1]).
-export([accounted_candidates/1]).
-export([chosen_route/1]).
-export([choice_meta/1]).
-export([route_scores/1]).
-export([route_limits/1]).

%%

-type provision_terms() :: dmsl_domain_thrift:'ProvisionTermSet'().
-type payment_terms() :: dmsl_domain_thrift:'PaymentsProvisionTerms'().
-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type route_predestination() :: payment | recurrent_payment.
-type get_route_params() :: #{
    predestination := route_predestination(),
    revision := revision(),
    varset := varset(),
    payment_institution := payment_institution(),
    pin_context := gather_route_context(),
    blacklist_context => hg_route_collector:blacklist_context()
}.

-define(rejected(Reason), {rejected, Reason}).

-define(fd_overrides(Enabled), #domain_RouteFaultDetectorOverrides{enabled = Enabled}).

-define(ZERO, 0).

-type terminal_priority_rating() :: integer().

-type provider_status() :: {availability_status(), conversion_status()}.

-type availability_status() :: {availability_condition(), availability_fail_rate()}.
-type conversion_status() :: {conversion_condition(), conversion_fail_rate()}.

-type availability_condition() :: alive | dead.
-type availability_fail_rate() :: float().

-type conversion_condition() :: normal | lacking.
-type conversion_fail_rate() :: float().

-type route_groups_by_priority() :: #{{availability_condition(), terminal_priority_rating()} => [fail_rated_route()]}.

-type fail_rated_route() :: {hg_route:t(), provider_status()}.
-type blacklisted_route() :: {hg_route:t(), boolean()}.

-type scored_route() :: {route_scores(), hg_route:t()}.

-type route_choice_context() :: #{
    chosen_route => hg_route:t(),
    preferable_route => hg_route:t(),
    % Contains one of the field names defined in #domain_PaymentRouteScores{}
    reject_reason => atom()
}.

-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type client_ip() :: dmsl_domain_thrift:'IPAddress'().
-type email() :: binary().
-type card_token() :: dmsl_domain_thrift:'Token'().

-type gather_route_context() :: #{
    currency := currency(),
    payment_tool := payment_tool(),
    client_ip := client_ip() | undefined,
    email => email() | undefined,
    card_token => card_token() | undefined
}.

-type varset() :: hg_varset:varset().
-type revision() :: hg_domain:revision().

-type route_scores() :: #domain_PaymentRouteScores{}.
-type limits() :: #{hg_route:payment_route() => [hg_limiter:turnover_limit_value()]}.
-type scores() :: #{hg_route:payment_route() => hg_routing:route_scores()}.
-type misconfiguration_error() :: {misconfiguration, {routing_decisions, _} | {routing_candidate, _}}.
-type rejection_group() :: atom().
-type result() :: #{
    initial_candidates := [hg_route:t()],
    candidates := [hg_route:t()],
    rejections := #{rejection_group() => [hg_route:rejected_route()]},
    latest_rejection := rejection_group() | undefined,
    error := term() | undefined,
    chosen_route := hg_route:t() | undefined,
    choice_meta := route_choice_context() | undefined,
    stashed_candidates => [hg_route:t()],
    fail_rates => [fail_rated_route()],
    route_limits => limits(),
    route_scores => scores()
}.

-export_type([route_predestination/0]).
-export_type([get_route_params/0]).
-export_type([route_choice_context/0]).
-export_type([fail_rated_route/0]).
-export_type([blacklisted_route/0]).
-export_type([route_scores/0]).
-export_type([limits/0]).
-export_type([scores/0]).
-export_type([result/0]).

%%

-spec get_routes(get_route_params()) -> [hg_route:t()].
get_routes(Params) ->
    Routes0 = get_base_routes(Params),
    Routes1 = maybe_fill_blacklist(maps:get(blacklist_context, Params, undefined), Routes0),
    Routes2 = hg_route_fd:fill(Routes1),
    hg_route_balancer:fill(Routes2).

-spec filter_routes([hg_route:t()], [fun(([hg_route:t()]) -> [hg_route:t()])]) -> [hg_route:t()].
filter_routes(Routes0, WithFilterFuns) ->
    Routes1 = filter_flagged_routes(Routes0, [{accepted, false}, {prohibit, true}, {blacklisted, 1}]),
    lists:foldr(fun(Fun, Routes) -> Fun(Routes) end, Routes1, WithFilterFuns).

-spec resolve(map()) -> result().
resolve(Params) ->
    Result0 =
        case maps:find(routing, Params) of
            {ok, Routing} ->
                Routing;
            error ->
                build_initial_result(Params)
        end,
    case get_error(Result0) of
        undefined ->
            AttemptedRoutes = maps:get(attempted_routes, Params, []),
            LimitHoldFun = maps:get(limit_hold_fun, Params, undefined),
            LimitOverflowFun = maps:get(limit_overflow_fun, Params, undefined),
            BlacklistContext = maps:get(blacklist_context, Params, undefined),
            Result1 = reject_attempted_routes(AttemptedRoutes, Result0),
            Result2 = process_result(Result1, fun(R) -> apply_limit_hold(LimitHoldFun, R) end),
            Result3 = process_result(Result2, fun(R) -> apply_limit_overflow(LimitOverflowFun, R) end),
            Result4 = process_result(Result3, fun(R) -> apply_blacklist(BlacklistContext, R) end),
            Result5 = process_result(Result4, fun filter_by_critical_provider_status/1),
            process_result(Result5, fun choose_route_with_ctx/1);
        _ ->
            Result0
    end.

-spec filter_by_critical_provider_status(result()) -> result().
filter_by_critical_provider_status(Result0) ->
    RoutesFailRates0 = rate_routes(candidates(Result0)),
    RouteScores0 = score_routes_map(RoutesFailRates0),
    Result1 = with_fail_rates(RoutesFailRates0, stash_route_scores(RouteScores0, Result0)),
    Result2 = lists:foldr(
        fun
            ({R, {{dead, _} = AvailabilityStatus, _ConversionStatus}}, Acc) ->
                RejectedRoute = hg_route:to_rejected_route(R, {'ProviderDead', AvailabilityStatus}),
                reject(adapter_unavailable, RejectedRoute, Acc);
            ({_R, _ProviderStatus}, Acc) ->
                Acc
        end,
        Result1,
        RoutesFailRates0
    ),
    BalancedRoutes = hg_route_balancer:fill(candidates(Result2)),
    RouteScores1 = routes_scores_map(BalancedRoutes),
    set_candidates(BalancedRoutes, stash_route_scores(RouteScores1, Result2)).

-spec filter_by_blacklist(result(), hg_inspector:blacklist_context()) -> result().
filter_by_blacklist(Result, undefined) ->
    Result;
filter_by_blacklist(Result, BlCtx) ->
    Routes = hg_route_collector:fill_blacklist(BlCtx, candidates(Result)),
    Result1 = set_candidates(Routes, Result),
    lists:foldr(
        fun(Route, Acc) ->
            case hg_route:blacklisted(Route) of
                1 ->
                    RejectedRoute = hg_route:to_rejected_route(Route, {'InBlackList', true}),
                    stash_route_scores(routes_scores_map([Route]), reject(in_blacklist, RejectedRoute, Acc));
                _ ->
                    Acc
            end
        end,
        Result1,
        Routes
    ).

-spec choose_route_with_ctx(result()) -> result().
choose_route_with_ctx(Result) ->
    {ChosenRoute, ChoiceContext} = choose_prepared_route(candidates(Result)),
    set_chosen(ChosenRoute, ChoiceContext, Result).

new(Candidates0) ->
    #{
        initial_candidates => Candidates0,
        candidates => Candidates0,
        rejections => #{},
        latest_rejection => undefined,
        error => undefined,
        chosen_route => undefined,
        choice_meta => undefined
    }.

build_initial_result(#{predefined_routes := Routes}) ->
    new(Routes);
build_initial_result(#{
    predestination := Predestination,
    payment_institution := PaymentInstitution,
    varset := VS,
    revision := Revision,
    pin_context := PinCtx
}) ->
    gather_routes(Predestination, PaymentInstitution, VS, Revision, PinCtx).

with_fail_rates(FailRates, Result) ->
    Result#{fail_rates => FailRates}.

set_candidates(Candidates, Result) ->
    Result#{candidates => Candidates}.

set_chosen(Route, ChoiceMeta, Result) ->
    Result#{chosen_route => Route, choice_meta => ChoiceMeta}.

set_error(ErrorReason, Result) ->
    Result#{error => ErrorReason}.

-spec get_error(result()) -> term() | undefined.
get_error(#{error := ErrorReason}) ->
    ErrorReason.

-spec rejected_routes(result()) -> [hg_route:rejected_route()].
rejected_routes(#{rejections := Rejections}) ->
    {_, Rejected} = lists:unzip(maps:to_list(Rejections)),
    lists:flatten(Rejected).

-spec rejections(result()) -> [{atom(), [hg_route:rejected_route()]}].
rejections(#{rejections := Rejections}) ->
    maps:to_list(Rejections).

-spec candidates(result()) -> [hg_route:t()].
candidates(#{candidates := Candidates0}) ->
    Candidates0.

-spec considered_candidates(result()) -> [hg_route:t()].
considered_candidates(Result) ->
    maps:get(stashed_candidates, Result, candidates(Result)).

-spec accounted_candidates(result()) -> [hg_route:t()].
accounted_candidates(Result) ->
    maps:get(stashed_candidates, Result, maps:get(initial_candidates, Result, [])).

-spec chosen_route(result()) -> hg_route:t() | undefined.
chosen_route(#{chosen_route := Chosen}) ->
    Chosen.

-spec choice_meta(result()) -> route_choice_context() | undefined.
choice_meta(Result) ->
    maps:get(choice_meta, Result, undefined).

-spec route_scores(result()) -> scores() | undefined.
route_scores(Result) ->
    maps:get(route_scores, Result, undefined).

-spec route_limits(result()) -> limits() | undefined.
route_limits(Result) ->
    maps:get(route_limits, Result, undefined).

stash_current_candidates(#{candidates := []} = Result) ->
    Result;
stash_current_candidates(Result) ->
    Result#{stashed_candidates => candidates(Result)}.

stash_route_limits(RouteLimits, Result) ->
    Result#{route_limits => RouteLimits}.

stash_route_scores(RouteScoresNew, #{route_scores := RouteScores0} = Result) ->
    Result#{route_scores => maps:merge(RouteScores0, RouteScoresNew)};
stash_route_scores(RouteScores0, Result) ->
    Result#{route_scores => RouteScores0}.

reject(GroupReason, RejectedRoute, #{rejections := Rejections0, candidates := Candidates0} = Result) ->
    RejectedList = maps:get(GroupReason, Rejections0, []) ++ [RejectedRoute],
    Result#{
        rejections := Rejections0#{GroupReason => RejectedList},
        candidates := exclude_route(RejectedRoute, Candidates0),
        latest_rejection := GroupReason
    }.

exclude_route(Route, Routes) ->
    lists:foldr(
        fun(R, Acc) ->
            case hg_route:equal(Route, R) of
                true -> Acc;
                false -> [R | Acc]
            end
        end,
        [],
        Routes
    ).

latest_rejected_routes(#{latest_rejection := ReasonGroup, rejections := Rejections}) ->
    {ReasonGroup, maps:get(ReasonGroup, Rejections, [])}.

with_guard(#{candidates := [], error := undefined} = Result) ->
    Result#{error := {rejected_routes, latest_rejected_routes(Result)}};
with_guard(Result) ->
    Result.

reject_attempted_routes([], Result) ->
    Result;
reject_attempted_routes(AttemptedRoutes, Result) ->
    with_guard(
        lists:foldr(
            fun(Route, Acc) ->
                InnerRoute = hg_route:from_payment_route(Route),
                RejectedRoute = hg_route:to_rejected_route(InnerRoute, {'AlreadyAttempted', undefined}),
                reject(already_attempted, RejectedRoute, Acc)
            end,
            Result,
            AttemptedRoutes
        )
    ).

apply_limit_hold(undefined, Result) ->
    Result;
apply_limit_hold(Fun, Result0) ->
    {_HeldRoutes, RejectedRoutes} = Fun(candidates(Result0)),
    Result1 = lists:foldr(fun(Route, Acc) -> reject(limit_misconfiguration, Route, Acc) end, Result0, RejectedRoutes),
    stash_current_candidates(with_guard(Result1)).

apply_limit_overflow(undefined, Result) ->
    Result;
apply_limit_overflow(Fun, Result0) ->
    {_AllowedRoutes, RejectedRoutes, Limits} = Fun(candidates(Result0)),
    Result1 = stash_route_limits(Limits, Result0),
    with_guard(lists:foldr(fun(Route, Acc) -> reject(limit_overflow, Route, Acc) end, Result1, RejectedRoutes)).

apply_blacklist(undefined, Result) ->
    Result;
apply_blacklist(BlacklistContext, Result) ->
    with_guard(filter_by_blacklist(Result, BlacklistContext)).

process_result(Result, Fun) ->
    case get_error(Result) of
        undefined -> with_guard(Fun(Result));
        _ -> Result
    end.

%%

-spec prepare_log_message(misconfiguration_error()) -> {io:format(), [term()]}.
prepare_log_message({misconfiguration, {routing_decisions, Details}}) ->
    {"PaymentRoutingDecisions couldn't be reduced to candidates, ~p", [Details]};
prepare_log_message({misconfiguration, {routing_candidate, Candidate}}) ->
    {"PaymentRoutingCandidate couldn't be reduced, ~p", [Candidate]}.

%%

-spec gather_routes(route_predestination(), payment_institution(), varset(), revision(), gather_route_context()) ->
    result().
gather_routes(_, #domain_PaymentInstitution{payment_routing_rules = undefined}, _, _, _) ->
    new([]);
gather_routes(Predestination, PaymentInstitution, VS, Revision, PinCtx) ->
    try
        Routes = get_base_routes(#{
            predestination => Predestination,
            payment_institution => PaymentInstitution,
            varset => VS,
            revision => Revision,
            pin_context => PinCtx
        }),
        with_guard(build_result_from_base_routes(Routes))
    catch
        throw:{misconfiguration, _Reason} = Error ->
            set_error(Error, new([]))
    end.

-spec get_base_routes(get_route_params()) -> [hg_route:t()].
get_base_routes(#{
    predestination := Predestination,
    payment_institution := PaymentInstitution,
    varset := VS,
    revision := Revision,
    pin_context := PinCtx
}) ->
    Routes0 = hg_route_collector:get_routes(Revision, VS, PaymentInstitution, PinCtx),
    Routes1 = hg_route_collector:fill_accepted(Predestination, Revision, VS, Routes0),
    Routes2 = hg_route_collector:fill_prohibition(Revision, VS, PaymentInstitution, Routes1),
    hg_route_collector:fill_fd_overrides(Revision, Routes2).

maybe_fill_blacklist(undefined, Routes) ->
    Routes;
maybe_fill_blacklist(BlacklistContext, Routes) ->
    hg_route_collector:fill_blacklist(BlacklistContext, Routes).

build_result_from_base_routes(Routes) ->
    lists:foldl(
        fun(Route, ResultAcc) ->
            case route_filter_rejection(Route) of
                undefined ->
                    append_candidate(Route, ResultAcc);
                RejectedRoute ->
                    reject(forbidden, RejectedRoute, ResultAcc)
            end
        end,
        new([]),
        Routes
    ).

append_candidate(Route, #{initial_candidates := Initial, candidates := Candidates} = Result) ->
    Result#{
        initial_candidates := Initial ++ [Route],
        candidates := Candidates ++ [Route]
    }.

route_filter_rejection(Route) ->
    RouteData = hg_route:route_data(Route),
    case maps:get(accepted, RouteData, true) of
        false ->
            hg_route:to_rejected_route(Route, {'RoutingRule', undefined});
        {false, {rejected, Reason}} ->
            hg_route:to_rejected_route(Route, Reason);
        {false, {misconfiguration, Reason}} ->
            hg_route:to_rejected_route(Route, {'Misconfiguration', Reason});
        {false, Reason} ->
            hg_route:to_rejected_route(Route, Reason);
        _ ->
            route_prohibit_rejection(Route, RouteData)
    end.

route_prohibit_rejection(Route, RouteData) ->
    case maps:get(prohibit, RouteData, false) of
        true ->
            hg_route:to_rejected_route(Route, {'RoutingRule', undefined});
        {true, Description} ->
            hg_route:to_rejected_route(Route, {'RoutingRule', Description});
        _ ->
            undefined
    end.

filter_flagged_routes(Routes, Keys) ->
    lists:filter(
        fun(Route) ->
            RouteData = hg_route:route_data(Route),
            not lists:any(
                fun({Key, Value}) ->
                    route_data_matches(maps:get(Key, RouteData, undefined), Value)
                end,
                Keys
            )
        end,
        Routes
    ).

route_data_matches(Value, Expected) when Value =:= Expected ->
    true;
route_data_matches({Expected, _}, Expected) ->
    true;
route_data_matches(_, _) ->
    false.

routes_scores_map(Routes) ->
    lists:foldr(
        fun(Route, Acc) ->
            Acc#{hg_route:to_payment_route(Route) => hg_route:score(Route)}
        end,
        #{},
        Routes
    ).

route_provider_status(Route) ->
    #{
        availability_condition := AvailabilityCondition,
        availability := Availability,
        conversion_condition := ConversionCondition,
        conversion := Conversion
    } = hg_route:fd_score(Route),
    {
        map_availability_status(AvailabilityCondition, Availability),
        map_conversion_status(ConversionCondition, Conversion)
    }.

map_availability_status(0, Availability) ->
    {dead, 1.0 - Availability};
map_availability_status(_, Availability) ->
    {alive, 1.0 - Availability}.

map_conversion_status(0, Conversion) ->
    {lacking, 1.0 - Conversion};
map_conversion_status(_, Conversion) ->
    {normal, 1.0 - Conversion}.

-spec rate_routes([hg_route:t()]) -> [fail_rated_route()].
rate_routes(Routes) ->
    score_routes_with_fault_detector(Routes).

-spec choose_route([hg_route:t()]) -> {hg_route:t(), route_choice_context()}.
choose_route(Routes) ->
    PreparedRoutes = hg_route_balancer:fill(hg_route_fd:fill(Routes)),
    choose_prepared_route(PreparedRoutes).

choose_prepared_route([Route]) ->
    {Route, #{chosen_route => Route}};
choose_prepared_route([First | Rest]) ->
    {ChosenRoute, IdealRoute} = find_best_prepared_routes(Rest, {First, First}),
    {ChosenRoute, get_prepared_route_choice_context(ChosenRoute, IdealRoute)}.

-spec choose_rated_route([fail_rated_route()]) -> {hg_route:t(), route_choice_context()}.
choose_rated_route(FailRatedRoutes) ->
    BalancedRoutes = balance_routes(FailRatedRoutes),
    ScoredRoutes = score_routes(BalancedRoutes),
    {ChosenScoredRoute, IdealRoute} = find_best_routes(ScoredRoutes),
    RouteChoiceContext = get_route_choice_context(ChosenScoredRoute, IdealRoute),
    {_, Route} = ChosenScoredRoute,
    {Route, RouteChoiceContext}.

find_best_prepared_routes([], Routes) ->
    Routes;
find_best_prepared_routes([RouteIn | Rest], {CurrentChosen, CurrentIdeal}) ->
    NewIdeal = select_better_prepared_route_ideal(RouteIn, CurrentIdeal),
    NewChosen = select_better_prepared_route(RouteIn, CurrentChosen),
    find_best_prepared_routes(Rest, {NewChosen, NewIdeal}).

select_better_prepared_route_ideal(Left, Right) ->
    IdealLeft = set_ideal_route_score(Left),
    IdealRight = set_ideal_route_score(Right),
    case select_better_prepared_route(IdealLeft, IdealRight) of
        IdealLeft -> Left;
        IdealRight -> Right
    end.

set_ideal_route_score(Route0) ->
    Route1 = hg_route:set_availability(1, 1.0, Route0),
    hg_route:set_conversion(1, 1.0, Route1).

select_better_prepared_route(Left, Right) ->
    LeftPin = hg_route:pin_hash(Left),
    RightPin = hg_route:pin_hash(Right),
    case {LeftPin, RightPin} of
        _ when LeftPin /= ?ZERO, RightPin /= ?ZERO, RightPin =:= LeftPin ->
            select_better_prepared_pinned_route(Left, Right);
        _ ->
            select_better_prepared_regular_route(Left, Right)
    end.

select_better_prepared_pinned_route(Left, Right) ->
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
        LeftScore -> Left;
        RightScore -> Right
    end.

select_better_prepared_regular_route(Left, Right) ->
    LeftScore = (hg_route:score(Left))#domain_PaymentRouteScores{route_pin = 0},
    RightScore = (hg_route:score(Right))#domain_PaymentRouteScores{route_pin = 0},
    case max({LeftScore, Left}, {RightScore, Right}) of
        {LeftScore, Left} -> Left;
        {RightScore, Right} -> Right
    end.

get_prepared_route_choice_context(SameRoute, SameRoute) ->
    #{
        chosen_route => SameRoute
    };
get_prepared_route_choice_context(ChosenRoute, IdealRoute) ->
    #{
        chosen_route => ChosenRoute,
        preferable_route => IdealRoute,
        reject_reason => map_route_switch_reason(hg_route:score(ChosenRoute), hg_route:score(IdealRoute))
    }.

-spec find_best_routes([scored_route()]) -> {Chosen :: scored_route(), Ideal :: scored_route()}.
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

select_better_route({LeftScore, _} = Left, {RightScore, _} = Right) ->
    LeftPin = LeftScore#domain_PaymentRouteScores.route_pin,
    RightPin = RightScore#domain_PaymentRouteScores.route_pin,
    Res =
        case {LeftPin, RightPin} of
            _ when LeftPin /= ?ZERO, RightPin /= ?ZERO, RightPin == LeftPin ->
                select_better_pinned_route(Left, Right);
            _ ->
                select_better_regular_route(Left, Right)
        end,
    Res.

select_better_pinned_route({LeftScore0, LeftRoute} = Left, {RightScore0, RightRoute} = Right) ->
    LeftScore1 = LeftScore0#domain_PaymentRouteScores{
        random_condition = 0,
        route_pin = erlang:phash2({
            LeftScore0#domain_PaymentRouteScores.route_pin,
            hg_route:provider_ref(LeftRoute),
            hg_route:terminal_ref(LeftRoute)
        })
    },
    RightScore1 = RightScore0#domain_PaymentRouteScores{
        random_condition = 0,
        route_pin = erlang:phash2({
            RightScore0#domain_PaymentRouteScores.route_pin,
            hg_route:provider_ref(RightRoute),
            hg_route:terminal_ref(RightRoute)
        })
    },

    case max(LeftScore1, RightScore1) of
        LeftScore1 ->
            Left;
        RightScore1 ->
            Right
    end.

select_better_regular_route({LeftScore0, LRoute}, {RightScore0, RRoute}) ->
    LeftScore1 = LeftScore0#domain_PaymentRouteScores{
        route_pin = 0
    },
    RightScore1 = RightScore0#domain_PaymentRouteScores{
        route_pin = 0
    },
    case max({LeftScore1, LRoute}, {RightScore1, RRoute}) of
        {LeftScore1, LRoute} ->
            {LeftScore0, LRoute};
        {RightScore1, RRoute} ->
            {RightScore0, RRoute}
    end.

select_better_route_ideal(Left, Right) ->
    IdealLeft = set_ideal_score(Left),
    IdealRight = set_ideal_score(Right),
    case select_better_route(IdealLeft, IdealRight) of
        IdealLeft -> Left;
        IdealRight -> Right
    end.

set_ideal_score({RouteScores, PT}) ->
    {
        RouteScores#domain_PaymentRouteScores{
            availability_condition = 1,
            availability = 1.0,
            conversion_condition = 1,
            conversion = 1.0
        },
        PT
    }.

get_route_choice_context({_, SameRoute}, {_, SameRoute}) ->
    #{
        chosen_route => SameRoute
    };
get_route_choice_context({ChosenScores, ChosenRoute}, {IdealScores, IdealRoute}) ->
    #{
        chosen_route => ChosenRoute,
        preferable_route => IdealRoute,
        reject_reason => map_route_switch_reason(ChosenScores, IdealScores)
    }.

-spec get_logger_metadata(route_choice_context(), revision()) -> LoggerFormattedMetadata :: map().
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

-spec balance_routes([fail_rated_route()]) -> [fail_rated_route()].
balance_routes(FailRatedRoutes) ->
    FilteredRouteGroups = lists:foldl(
        fun group_routes_by_priority/2,
        #{},
        FailRatedRoutes
    ),
    balance_route_groups(FilteredRouteGroups).

-spec group_routes_by_priority(fail_rated_route(), Acc :: route_groups_by_priority()) -> route_groups_by_priority().
group_routes_by_priority({Route, {ProviderCondition, _}} = FailRatedRoute, SortedRoutes) ->
    TerminalPriority = hg_route:priority(Route),
    Key = {ProviderCondition, TerminalPriority},
    Routes = maps:get(Key, SortedRoutes, []),
    SortedRoutes#{Key => [FailRatedRoute | Routes]}.

-spec balance_route_groups(route_groups_by_priority()) -> [fail_rated_route()].
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

get_summary_weight(FailRatedRoutes) ->
    lists:foldl(
        fun({Route, _}, Acc) ->
            Weight = hg_route:weight(Route),
            Acc + Weight
        end,
        0,
        FailRatedRoutes
    ).

calc_random_condition(_, _, [], Routes) ->
    Routes;
calc_random_condition(StartFrom, Random, [FailRatedRoute | Rest], Routes) ->
    {Route, Status} = FailRatedRoute,
    Weight = hg_route:weight(Route),
    InRange = (Random >= StartFrom) and (Random < StartFrom + Weight),
    case InRange of
        true ->
            NewRoute = hg_route:set_weight(1, Route),
            calc_random_condition(StartFrom + Weight, Random, Rest, [{NewRoute, Status} | Routes]);
        false ->
            NewRoute = hg_route:set_weight(0, Route),
            calc_random_condition(StartFrom + Weight, Random, Rest, [{NewRoute, Status} | Routes])
    end.

-spec score_routes_map([fail_rated_route()]) -> #{hg_route:payment_route() => route_scores()}.
score_routes_map(Routes) ->
    lists:foldl(
        fun({Route, _} = FailRatedRoute, Acc) ->
            Acc#{hg_route:to_payment_route(Route) => score_route_ext(FailRatedRoute)}
        end,
        #{},
        Routes
    ).

-spec score_routes([fail_rated_route()]) -> [scored_route()].
score_routes(Routes) ->
    [{score_route_ext(FailRatedRoute), Route} || {Route, _} = FailRatedRoute <- Routes].

score_route_ext({Route, ProviderStatus}) ->
    {AvailabilityStatus, ConversionStatus} = ProviderStatus,
    {AvailabilityCondition, Availability} = get_availability_score(AvailabilityStatus),
    {ConversionCondition, Conversion} = get_conversion_score(ConversionStatus),
    Scores = score_route(Route),
    Scores#domain_PaymentRouteScores{
        availability_condition = AvailabilityCondition,
        conversion_condition = ConversionCondition,
        availability = Availability,
        conversion = Conversion
    }.

score_route(Route) ->
    PriorityRate = hg_route:priority(Route),
    Pin = hg_route:pin(Route),
    #domain_PaymentRouteScores{
        terminal_priority_rating = PriorityRate,
        route_pin = get_pin_hash(Pin),
        random_condition = hg_route:weight(Route),
        blacklist_condition = 0
    }.

get_pin_hash(Pin) when map_size(Pin) == 0 ->
    ?ZERO;
get_pin_hash(Pin) ->
    erlang:phash2(Pin).

get_availability_score({alive, FailRate}) -> {1, 1.0 - FailRate};
get_availability_score({dead, FailRate}) -> {0, 1.0 - FailRate}.

get_conversion_score({normal, FailRate}) -> {1, 1.0 - FailRate};
get_conversion_score({lacking, FailRate}) -> {0, 1.0 - FailRate}.

-spec score_routes_with_fault_detector([hg_route:t()]) -> [fail_rated_route()].
score_routes_with_fault_detector([]) ->
    [];
score_routes_with_fault_detector(Routes) ->
    PreparedRoutes = hg_route_fd:fill(Routes),
    [{Route, route_provider_status(Route)} || Route <- PreparedRoutes].

-spec get_payment_terms(hg_route:payment_route(), varset(), revision()) -> payment_terms() | undefined.
get_payment_terms(?route(ProviderRef, TerminalRef), VS, Revision) ->
    PreparedVS = hg_varset:prepare_varset(VS),
    {Client, Context} = get_party_client(),
    {ok, TermsSet} = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        Revision,
        PreparedVS,
        Client,
        Context
    ),
    TermsSet#domain_ProvisionTermSet.payments.

-spec get_provision_terms(hg_route:payment_route(), varset(), revision()) -> provision_terms() | undefined.
get_provision_terms(?route(ProviderRef, TerminalRef), VS, Revision) ->
    PreparedVS = hg_varset:prepare_varset(VS),
    {Client, Context} = get_party_client(),
    {ok, TermsSet} = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        Revision,
        PreparedVS,
        Client,
        Context
    ),
    TermsSet.

get_party_client() ->
    HgContext = hg_context:load(),
    Client = hg_context:get_party_client(HgContext),
    Context = hg_context:get_party_client_context(HgContext),
    {Client, Context}.

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec merge_fd_overrides(term(), term()) -> term().
merge_fd_overrides(_A, B = ?fd_overrides(Enabled)) when Enabled =/= undefined ->
    B;
merge_fd_overrides(A = ?fd_overrides(Enabled), _B) when Enabled =/= undefined ->
    A;
merge_fd_overrides(_A, _B) ->
    ?fd_overrides(undefined).

-spec test() -> _.
-type testcase() :: {_, fun(() -> _)}.

-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).

-spec record_comparsion_test() -> _.
record_comparsion_test() ->
    Bigger = {
        #domain_PaymentRouteScores{
            availability_condition = 1,
            availability = 0.5,
            conversion_condition = 1,
            conversion = 0.5,
            terminal_priority_rating = 1,
            route_pin = 0,
            random_condition = 1
        },
        {42, 42}
    },
    Smaller = {
        #domain_PaymentRouteScores{
            availability_condition = 0,
            availability = 0.1,
            conversion_condition = 1,
            conversion = 0.5,
            terminal_priority_rating = 1,
            route_pin = 0,
            random_condition = 1
        },
        {99, 99}
    },
    ?assertEqual(Bigger, select_better_route(Bigger, Smaller)).

-spec pin_random_test() -> _.
pin_random_test() ->
    Pin = #{
        email => <<"example@mail.com">>
    },
    Scores = {{alive, 0.0}, {normal, 0.0}},
    Route1 = {hg_route:new(?prv(1), ?trm(1), 50, 1, Pin), Scores},
    Route2 = {hg_route:new(?prv(2), ?trm(2), 50, 1, Pin), Scores},
    lists:foldl(
        fun(_I, Acc) ->
            {ST, _} = ShuffledRoute = shuffle_routes([Route1, Route2]),
            case Acc of
                undefined ->
                    ShuffledRoute;
                {ST, _} ->
                    ShuffledRoute;
                _ ->
                    erlang:error({ShuffledRoute, Acc})
            end
        end,
        undefined,
        lists:seq(0, 1000)
    ).

-spec diff_pin_test() -> _.
diff_pin_test() ->
    Pin = #{
        email => <<"example@mail.com">>
    },
    Scores = {{alive, 0.0}, {normal, 0.0}},
    Route1 = {hg_route:new(?prv(1), ?trm(1), 50, 33, Pin), Scores},
    Route2 = {hg_route:new(?prv(1), ?trm(2), 50, 33, Pin), Scores},
    Route3 = {hg_route:new(?prv(1), ?trm(3), 50, 33, Pin#{client_ip => <<"IP">>}), Scores},
    {I1, I2, I3} = lists:foldl(
        fun(_I, {Iter1, Iter2, Iter3}) ->
            {ST, _} = shuffle_routes([Route1, Route2, Route3]),
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
            erlang:error({{i1, i2}, SomethingElse})
    end,
    case I3 of
        _ when I3 > 300 ->
            true;
        _ ->
            erlang:error({i3, I3})
    end.

-spec pin_weight_test() -> _.
pin_weight_test() ->
    Pin0 = #{
        email => <<"example@mail.com">>
    },
    Pin1 = #{
        email => <<"example1@mail.com">>
    },
    Scores1 = {{alive, 0.0}, {normal, 0.0}},
    Scores2 = {{alive, 0.0}, {normal, 0.0}},
    Route1 = {hg_route:new(?prv(1), ?trm(1), 50, 1, Pin0, ?fd_overrides(true)), Scores1},
    Route2 = {hg_route:new(?prv(1), ?trm(2), 50, 1, Pin0, ?fd_overrides(true)), Scores2},
    Route3 = {hg_route:new(?prv(1), ?trm(1), 50, 1, Pin1, ?fd_overrides(true)), Scores1},
    Route4 = {hg_route:new(?prv(1), ?trm(2), 50, 1, Pin1, ?fd_overrides(true)), Scores2},
    true = lists:foldl(
        fun(_I, _A) ->
            {ShuffledRoute1, _} = shuffle_routes([Route1, Route2]),
            {ShuffledRoute2, _} = shuffle_routes([Route3, Route4]),
            case true of
                _ when ShuffledRoute1 == ?trm(1), ShuffledRoute2 == ?trm(2) ->
                    true;
                _ ->
                    erlang:error({ShuffledRoute1, ShuffledRoute2})
            end
        end,
        true,
        lists:seq(0, 1000)
    ).

shuffle_routes(Routes) ->
    BalancedRoutes = balance_routes(Routes),
    ScoredRoutes = score_routes(BalancedRoutes),
    {{_, ChosenScoredRoute}, _IdealRoute} = find_best_routes(ScoredRoutes),
    {hg_route:terminal_ref(ChosenScoredRoute), ChosenScoredRoute}.

-spec balance_routes_test_() -> [testcase()].
balance_routes_test_() ->
    Status = {{alive, 0.0}, {normal, 0.0}},
    WithWeight = [
        {hg_route:new(?prv(1), ?trm(1), 1, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(2), ?trm(1), 2, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(3), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(4), ?trm(1), 1, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(5), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status}
    ],

    Result1 = [
        {hg_route:new(?prv(1), ?trm(1), 1, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(2), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(3), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(4), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(5), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status}
    ],
    Result2 = [
        {hg_route:new(?prv(1), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(2), ?trm(1), 1, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(3), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(4), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(5), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status}
    ],
    Result3 = [
        {hg_route:new(?prv(1), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(2), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(3), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(4), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(5), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status}
    ],
    [
        ?_assertEqual(Result1, lists:reverse(calc_random_condition(0.0, 0.2, WithWeight, []))),
        ?_assertEqual(Result2, lists:reverse(calc_random_condition(0.0, 1.5, WithWeight, []))),
        ?_assertEqual(Result3, lists:reverse(calc_random_condition(0.0, 4.0, WithWeight, [])))
    ].

-spec balance_routes_with_default_weight_test_() -> testcase().
balance_routes_with_default_weight_test_() ->
    Status = {{alive, 0.0}, {normal, 0.0}},
    Routes = [
        {hg_route:new(?prv(1), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(2), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status}
    ],
    Result = [
        {hg_route:new(?prv(1), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status},
        {hg_route:new(?prv(2), ?trm(1), 0, ?DOMAIN_CANDIDATE_PRIORITY), Status}
    ],
    ?_assertEqual(Result, set_routes_random_condition(Routes)).

-spec preferable_route_scoring_test_() -> [testcase()].
preferable_route_scoring_test_() ->
    StatusAlive = {{alive, 0.0}, {normal, 0.0}},
    StatusAliveLowerConversion = {{alive, 0.0}, {normal, 0.1}},
    StatusDead = {{dead, 0.4}, {lacking, 0.6}},
    StatusDegraded = {{alive, 0.1}, {normal, 0.1}},
    StatusBroken = {{alive, 0.1}, {lacking, 0.8}},
    RoutePreferred1 = hg_route:new(?prv(1), ?trm(1), 0, 1),
    RoutePreferred2 = hg_route:new(?prv(1), ?trm(2), 0, 1),
    RoutePreferred3 = hg_route:new(?prv(1), ?trm(3), 0, 1),
    RouteFallback = hg_route:new(?prv(2), ?trm(2), 0, 0),
    [
        ?_assertMatch(
            {RoutePreferred1, #{}},
            choose_rated_route([
                {RoutePreferred1, StatusAlive},
                {RouteFallback, StatusAlive}
            ])
        ),
        ?_assertEqual(
            {RoutePreferred3, #{
                chosen_route => RoutePreferred3
            }},
            choose_rated_route([
                {RoutePreferred1, StatusDead},
                {RoutePreferred2, StatusDead},
                {RoutePreferred3, StatusAlive}
            ])
        ),
        ?_assertMatch(
            {RouteFallback, #{
                preferable_route := RoutePreferred1,
                reject_reason := availability_condition
            }},
            choose_rated_route([
                {RoutePreferred1, StatusDead},
                {RouteFallback, StatusAlive}
            ])
        ),
        ?_assertMatch(
            {RouteFallback, #{
                preferable_route := RoutePreferred1,
                reject_reason := conversion_condition
            }},
            choose_rated_route([
                {RoutePreferred1, StatusBroken},
                {RouteFallback, StatusAlive}
            ])
        ),
        ?_assertMatch(
            {RoutePreferred1, #{
                preferable_route := RoutePreferred2,
                reject_reason := conversion
            }},
            choose_rated_route([
                {RoutePreferred1, StatusAlive},
                {RoutePreferred2, StatusAliveLowerConversion}
            ])
        ),
        % TODO TD-344
        % We rely here on inverted order of preference which is just an accidental
        % side effect.
        ?_assertMatch(
            {RoutePreferred1, #{
                preferable_route := RoutePreferred2,
                reject_reason := availability
            }},
            choose_rated_route([
                {RoutePreferred1, StatusAlive},
                {RoutePreferred2, StatusDegraded},
                {RouteFallback, StatusAlive}
            ])
        )
    ].

-spec prefer_weight_over_availability_test() -> _.
prefer_weight_over_availability_test() ->
    Route1 = hg_route:new(?prv(1), ?trm(1), 0, 1000),
    Route2 = hg_route:new(?prv(2), ?trm(2), 0, 1005),
    Route3 = hg_route:new(?prv(3), ?trm(3), 0, 1000),
    Routes = [Route1, Route2, Route3],

    ProviderStatuses = [
        {{alive, 0.3}, {normal, 0.3}},
        {{alive, 0.5}, {normal, 0.3}},
        {{alive, 0.3}, {normal, 0.3}}
    ],
    FailRatedRoutes = lists:zip(Routes, ProviderStatuses),
    ?assertMatch({Route2, _}, choose_rated_route(FailRatedRoutes)).

-spec prefer_weight_over_conversion_test() -> _.
prefer_weight_over_conversion_test() ->
    Route1 = hg_route:new(?prv(1), ?trm(1), 0, 1000),
    Route2 = hg_route:new(?prv(2), ?trm(2), 0, 1005),
    Route3 = hg_route:new(?prv(3), ?trm(3), 0, 1000),
    Routes = [Route1, Route2, Route3],

    ProviderStatuses = [
        {{alive, 0.3}, {normal, 0.5}},
        {{alive, 0.3}, {normal, 0.3}},
        {{alive, 0.3}, {normal, 0.3}}
    ],
    FailRatedRoutes = lists:zip(Routes, ProviderStatuses),
    {Route2, _Meta} = choose_rated_route(FailRatedRoutes).

-spec merge_fd_overrides_test_() -> _.
merge_fd_overrides_test_() ->
    [
        ?_assertEqual(?fd_overrides(undefined), merge_fd_overrides(undefined, ?fd_overrides(undefined))),
        ?_assertEqual(?fd_overrides(true), merge_fd_overrides(?fd_overrides(true), undefined)),
        ?_assertEqual(?fd_overrides(true), merge_fd_overrides(?fd_overrides(true), ?fd_overrides(undefined))),
        ?_assertEqual(?fd_overrides(false), merge_fd_overrides(?fd_overrides(true), ?fd_overrides(false)))
    ].

-endif.
