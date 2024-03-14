%%% Naïve routing oracle

-module(hg_routing).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-export([gather_routes/5]).
-export([check_routes/2]).
-export([rate_routes/1]).
-export([choose_route/1]).
-export([choose_rated_route/1]).

-export([get_payment_terms/3]).

-export([get_logger_metadata/2]).
-export([prepare_log_message/1]).

%%

-export([filter_by_critical_provider_status/1]).
-export([filter_by_blacklist/2]).
-export([choose_route_with_ctx/1]).

%%

-type payment_terms() :: dmsl_domain_thrift:'PaymentsProvisionTerms'().
-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type route_predestination() :: payment | recurrent_paytool | recurrent_payment.

-define(rejected(Reason), {rejected, Reason}).

-define(fd_overrides(Enabled), #domain_RouteFaultDetectorOverrides{enabled = Enabled}).

-type fd_service_stats() :: fd_proto_fault_detector_thrift:'ServiceStatistics'().

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
-type party_id() :: dmsl_domain_thrift:'PartyID'().
-type client_ip() :: dmsl_domain_thrift:'IPAddress'().

-type gather_route_context() :: #{
    currency := currency(),
    payment_tool := payment_tool(),
    party_id := party_id(),
    client_ip := client_ip() | undefined
}.

-type varset() :: hg_varset:varset().
-type revision() :: hg_domain:revision().

-type route_scores() :: #domain_PaymentRouteScores{}.
-type limits() :: #{hg_route:payment_route() => [hg_limiter:turnover_limit_value()]}.
-type scores() :: #{hg_route:payment_route() => hg_routing:route_scores()}.
-type misconfiguration_error() :: {misconfiguration, {routing_decisions, _} | {routing_candidate, _}}.

-export_type([route_predestination/0]).
-export_type([route_choice_context/0]).
-export_type([fail_rated_route/0]).
-export_type([blacklisted_route/0]).
-export_type([route_scores/0]).
-export_type([limits/0]).
-export_type([scores/0]).

%%

-spec filter_by_critical_provider_status(T) -> T when T :: hg_routing_ctx:t().
filter_by_critical_provider_status(Ctx0) ->
    RoutesFailRates = rate_routes(hg_routing_ctx:candidates(Ctx0)),
    RouteScores = score_routes_map(RoutesFailRates),
    Ctx1 = hg_routing_ctx:stash_route_scores(RouteScores, Ctx0),
    lists:foldr(
        fun
            ({R, {{dead, _} = AvailabilityStatus, _ConversionStatus}}, C) ->
                R1 = hg_route:to_rejected_route(R, {'ProviderDead', AvailabilityStatus}),
                hg_routing_ctx:reject(adapter_unavailable, R1, C);
            ({_R, _ProviderStatus}, C) ->
                C
        end,
        hg_routing_ctx:with_fail_rates(RoutesFailRates, Ctx1),
        RoutesFailRates
    ).

-spec filter_by_blacklist(T, hg_inspector:blacklist_context()) -> T when T :: hg_routing_ctx:t().
filter_by_blacklist(Ctx, BlCtx) ->
    BlacklistedRoutes = check_routes(hg_routing_ctx:candidates(Ctx), BlCtx),
    lists:foldr(
        fun
            ({R, true = Status}, C) ->
                R1 = hg_route:to_rejected_route(R, {'InBlackList', Status}),
                Ctx0 = hg_routing_ctx:reject(in_blacklist, R1, C),
                Scores0 = score_route(R),
                Scores1 = Scores0#domain_PaymentRouteScores{blacklist_condition = 1},
                hg_routing_ctx:add_route_scores({hg_route:to_payment_route(R), Scores1}, Ctx0);
            ({_R, _ProviderStatus}, C) ->
                C
        end,
        Ctx,
        BlacklistedRoutes
    ).

-spec choose_route_with_ctx(T) -> T when T :: hg_routing_ctx:t().
choose_route_with_ctx(Ctx) ->
    Candidates = hg_routing_ctx:candidates(Ctx),
    {ChoosenRoute, ChoiceContext} =
        case hg_routing_ctx:fail_rates(Ctx) of
            undefined ->
                choose_route(Candidates);
            FailRates ->
                RatedCandidates = filter_rated_routes_with_candidates(FailRates, Candidates),
                choose_rated_route(RatedCandidates)
        end,
    hg_routing_ctx:set_choosen(ChoosenRoute, ChoiceContext, Ctx).

filter_rated_routes_with_candidates(FailRates, Candidates) ->
    lists:foldr(
        fun({R, _PS} = FR, Res) ->
            case lists:any(fun(CR) -> hg_route:equal(CR, R) end, Candidates) of
                true -> [FR | Res];
                _Else -> Res
            end
        end,
        [],
        FailRates
    ).

%%

-spec prepare_log_message(misconfiguration_error()) -> {io:format(), [term()]}.
prepare_log_message({misconfiguration, {routing_decisions, Details}}) ->
    {"PaymentRoutingDecisions couldn't be reduced to candidates, ~p", [Details]};
prepare_log_message({misconfiguration, {routing_candidate, Candidate}}) ->
    {"PaymentRoutingCandidate couldn't be reduced, ~p", [Candidate]}.

%%

-spec gather_routes(route_predestination(), payment_institution(), varset(), revision(), gather_route_context()) ->
    hg_routing_ctx:t().
gather_routes(_, #domain_PaymentInstitution{payment_routing_rules = undefined}, _, _, _) ->
    hg_routing_ctx:new([]);
gather_routes(Predestination, #domain_PaymentInstitution{payment_routing_rules = RoutingRules}, VS, Revision, Ctx) ->
    #domain_RoutingRules{
        policies = Policies,
        prohibitions = Prohibitions
    } = RoutingRules,
    try
        Candidates = get_candidates(Policies, VS, Revision),
        {Accepted, RejectedRoutes} = filter_routes(
            collect_routes(Predestination, Candidates, VS, Revision, Ctx),
            get_table_prohibitions(Prohibitions, VS, Revision)
        ),
        lists:foldr(
            fun(R, C) -> hg_routing_ctx:reject(forbidden, R, C) end,
            hg_routing_ctx:new(Accepted),
            lists:reverse(RejectedRoutes)
        )
    catch
        throw:{misconfiguration, _Reason} = Error ->
            hg_routing_ctx:set_error(Error, hg_routing_ctx:new([]))
    end.

get_table_prohibitions(Prohibitions, VS, Revision) ->
    RuleSetDeny = compute_rule_set(Prohibitions, VS, Revision),
    lists:foldr(
        fun(#domain_RoutingCandidate{terminal = K, description = V}, AccIn) ->
            AccIn#{K => V}
        end,
        #{},
        get_decisions_candidates(RuleSetDeny)
    ).

get_candidates(RoutingRule, VS, Revision) ->
    get_decisions_candidates(
        compute_rule_set(RoutingRule, VS, Revision)
    ).

get_decisions_candidates(#domain_RoutingRuleset{decisions = Decisions}) ->
    case Decisions of
        {delegates, _Delegates} ->
            throw({misconfiguration, {routing_decisions, Decisions}});
        {candidates, Candidates} ->
            ok = validate_decisions_candidates(Candidates),
            Candidates
    end.

validate_decisions_candidates([]) ->
    ok;
validate_decisions_candidates([#domain_RoutingCandidate{allowed = {constant, true}} | Rest]) ->
    validate_decisions_candidates(Rest);
validate_decisions_candidates([Candidate | _]) ->
    throw({misconfiguration, {routing_candidate, Candidate}}).

collect_routes(Predestination, Candidates, VS, Revision, Ctx) ->
    lists:foldr(
        fun(Candidate, {Accepted, Rejected}) ->
            #domain_RoutingCandidate{
                terminal = TerminalRef,
                priority = Priority,
                weight = Weight,
                pin = Pin
            } = Candidate,
            {ProviderRef, FdOverrides} = get_provider_fd_overrides(Revision, TerminalRef),
            GatheredPinInfo = gather_pin_info(Pin, Ctx),
            try
                true = acceptable_terminal(Predestination, ProviderRef, TerminalRef, VS, Revision),
                Route = hg_route:new(ProviderRef, TerminalRef, Weight, Priority, GatheredPinInfo, FdOverrides),
                {[Route | Accepted], Rejected}
            catch
                {rejected, Reason} ->
                    {Accepted, [{ProviderRef, TerminalRef, Reason} | Rejected]};
                error:{misconfiguration, Reason} ->
                    {Accepted, [{ProviderRef, TerminalRef, {'Misconfiguration', Reason}} | Rejected]}
            end
        end,
        {[], []},
        Candidates
    ).

get_provider_fd_overrides(Revision, TerminalRef) ->
    % Looks like overhead, we got Terminal only for provider_ref. Maybe
    % we can remove provider_ref from hg_route:t().
    % https://github.com/rbkmoney/hellgate/pull/583#discussion_r682745123
    #domain_Terminal{provider_ref = ProviderRef, route_fd_overrides = TrmFdOverrides} =
        hg_domain:get(Revision, {terminal, TerminalRef}),
    #domain_Provider{route_fd_overrides = PrvFdOverrides} =
        hg_domain:get(Revision, {provider, ProviderRef}),
    %% TODO Consider moving this logic to party-management before (or after)
    %%      internal route structure refactoring.
    {ProviderRef, merge_fd_overrides(PrvFdOverrides, TrmFdOverrides)}.

merge_fd_overrides(_A, B = ?fd_overrides(Enabled)) when Enabled =/= undefined ->
    B;
merge_fd_overrides(A = ?fd_overrides(Enabled), _B) when Enabled =/= undefined ->
    A;
merge_fd_overrides(_A, _B) ->
    ?fd_overrides(undefined).

gather_pin_info(undefined, _Ctx) ->
    #{};
gather_pin_info(#domain_RoutingPin{features = Features}, Ctx) ->
    FeaturesList = ordsets:to_list(Features),
    lists:foldl(
        fun(Feature, Acc) ->
            Acc#{Feature => maps:get(Feature, Ctx)}
        end,
        #{},
        FeaturesList
    ).

filter_routes({Routes, Rejected}, Prohibitions) ->
    lists:foldr(
        fun(Route, {AccIn, RejectedIn}) ->
            TRef = hg_route:terminal_ref(Route),
            case maps:find(TRef, Prohibitions) of
                error ->
                    {[Route | AccIn], RejectedIn};
                {ok, Description} ->
                    RejectedOut = [hg_route:to_rejected_route(Route, {'RoutingRule', Description}) | RejectedIn],
                    {AccIn, RejectedOut}
            end
        end,
        {[], Rejected},
        Routes
    ).

compute_rule_set(RuleSetRef, VS, Revision) ->
    Ctx = hg_context:load(),
    {ok, RuleSet} = party_client_thrift:compute_routing_ruleset(
        RuleSetRef,
        Revision,
        hg_varset:prepare_varset(VS),
        hg_context:get_party_client(Ctx),
        hg_context:get_party_client_context(Ctx)
    ),
    RuleSet.

-spec check_routes([hg_route:t()], hg_inspector:blacklist_context()) -> [blacklisted_route()].
check_routes(Routes, BlCtx) ->
    score_routes_with_inspector(Routes, BlCtx).

-spec rate_routes([hg_route:t()]) -> [fail_rated_route()].
rate_routes(Routes) ->
    score_routes_with_fault_detector(Routes).

-spec choose_route([hg_route:t()]) -> {hg_route:t(), route_choice_context()}.
choose_route(Routes) ->
    FailRatedRoutes = rate_routes(Routes),
    choose_rated_route(FailRatedRoutes).

-spec choose_rated_route([fail_rated_route()]) -> {hg_route:t(), route_choice_context()}.
choose_rated_route(FailRatedRoutes) ->
    BalancedRoutes = balance_routes(FailRatedRoutes),
    ScoredRoutes = score_routes(BalancedRoutes),
    {ChosenScoredRoute, IdealRoute} = find_best_routes(ScoredRoutes),
    RouteChoiceContext = get_route_choice_context(ChosenScoredRoute, IdealRoute),
    {_, Route} = ChosenScoredRoute,
    {Route, RouteChoiceContext}.

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

select_better_route(Left, Right) ->
    max(Left, Right).

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
group_routes_by_priority(FailRatedRoute = {Route, {ProviderCondition, _}}, SortedRoutes) ->
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
    RandomCondition = hg_route:weight(Route),
    Pin = hg_route:pin(Route),
    PinHash = erlang:phash2(Pin),
    #domain_PaymentRouteScores{
        terminal_priority_rating = PriorityRate,
        route_pin = PinHash,
        random_condition = RandomCondition,
        blacklist_condition = 0
    }.

get_availability_score({alive, FailRate}) -> {1, 1.0 - FailRate};
get_availability_score({dead, FailRate}) -> {0, 1.0 - FailRate}.

get_conversion_score({normal, FailRate}) -> {1, 1.0 - FailRate};
get_conversion_score({lacking, FailRate}) -> {0, 1.0 - FailRate}.

-spec score_routes_with_fault_detector([hg_route:t()]) -> [fail_rated_route()].
score_routes_with_fault_detector([]) ->
    [];
score_routes_with_fault_detector(Routes) ->
    IDs = build_ids(Routes),
    FDStats = hg_fault_detector_client:get_statistics(IDs),
    [{R, get_provider_status(R, FDStats)} || R <- Routes].

-spec get_provider_status(hg_route:t(), [fd_service_stats()]) -> provider_status().
get_provider_status(Route, FDStats) ->
    ProviderRef = hg_route:provider_ref(Route),
    FdOverrides = hg_route:fd_overrides(Route),
    AvailabilityServiceID = build_fd_availability_service_id(ProviderRef),
    ConversionServiceID = build_fd_conversion_service_id(ProviderRef),
    AvailabilityStatus = get_adapter_availability_status(FdOverrides, AvailabilityServiceID, FDStats),
    ConversionStatus = get_provider_conversion_status(FdOverrides, ConversionServiceID, FDStats),
    {AvailabilityStatus, ConversionStatus}.

get_adapter_availability_status(?fd_overrides(true), _FDID, _Stats) ->
    %% ignore fd statistic if set override
    {alive, 0.0};
get_adapter_availability_status(_, FDID, Stats) ->
    AvailabilityConfig = maps:get(availability, genlib_app:env(hellgate, fault_detector, #{}), #{}),
    CriticalFailRate = maps:get(critical_fail_rate, AvailabilityConfig, 0.7),
    case lists:keysearch(FDID, #fault_detector_ServiceStatistics.service_id, Stats) of
        {value, #fault_detector_ServiceStatistics{failure_rate = FailRate}} when FailRate >= CriticalFailRate ->
            {dead, FailRate};
        {value, #fault_detector_ServiceStatistics{failure_rate = FailRate}} ->
            {alive, FailRate};
        false ->
            {alive, 0.0}
    end.

get_provider_conversion_status(?fd_overrides(true), _FDID, _Stats) ->
    %% ignore fd statistic if set override
    {normal, 0.0};
get_provider_conversion_status(_, FDID, Stats) ->
    ConversionConfig = maps:get(conversion, genlib_app:env(hellgate, fault_detector, #{}), #{}),
    CriticalFailRate = maps:get(critical_fail_rate, ConversionConfig, 0.7),
    case lists:keysearch(FDID, #fault_detector_ServiceStatistics.service_id, Stats) of
        {value, #fault_detector_ServiceStatistics{failure_rate = FailRate}} when FailRate >= CriticalFailRate ->
            {lacking, FailRate};
        {value, #fault_detector_ServiceStatistics{failure_rate = FailRate}} ->
            {normal, FailRate};
        false ->
            {normal, 0.0}
    end.

-spec score_routes_with_inspector([hg_route:t()], hg_inspector:blacklist_context()) -> [blacklisted_route()].
score_routes_with_inspector([], _BlCtx) ->
    [];
score_routes_with_inspector(Routes, BlCtx) ->
    [{R, hg_inspector:check_blacklist(BlCtx#{route => R})} || R <- Routes].

build_ids(Routes) ->
    lists:foldl(fun build_fd_ids/2, [], Routes).

build_fd_ids(Route, IDs) ->
    ProviderRef = hg_route:provider_ref(Route),
    AvailabilityID = build_fd_availability_service_id(ProviderRef),
    ConversionID = build_fd_conversion_service_id(ProviderRef),
    [AvailabilityID, ConversionID | IDs].

build_fd_availability_service_id(#domain_ProviderRef{id = ID}) ->
    hg_fault_detector_client:build_service_id(adapter_availability, ID).

build_fd_conversion_service_id(#domain_ProviderRef{id = ID}) ->
    hg_fault_detector_client:build_service_id(provider_conversion, ID).

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

-spec acceptable_terminal(
    route_predestination(),
    hg_route:provider_ref(),
    hg_route:terminal_ref(),
    varset(),
    revision()
) -> true | no_return().
acceptable_terminal(Predestination, ProviderRef, TerminalRef, VS, Revision) ->
    {Client, Context} = get_party_client(),
    Result = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        Revision,
        hg_varset:prepare_varset(VS),
        Client,
        Context
    ),
    case Result of
        {ok, ProvisionTermSet} ->
            check_terms_acceptability(Predestination, ProvisionTermSet, VS);
        {error, #payproc_ProvisionTermSetUndefined{}} ->
            throw(?rejected({'ProvisionTermSet', undefined}))
    end.

%%

get_party_client() ->
    HgContext = hg_context:load(),
    Client = hg_context:get_party_client(HgContext),
    Context = hg_context:get_party_client_context(HgContext),
    {Client, Context}.

check_terms_acceptability(payment, Terms, VS) ->
    acceptable_payment_terms(Terms#domain_ProvisionTermSet.payments, VS);
check_terms_acceptability(recurrent_paytool, Terms, VS) ->
    acceptable_recurrent_paytool_terms(Terms#domain_ProvisionTermSet.recurrent_paytools, VS);
check_terms_acceptability(recurrent_payment, Terms, VS) ->
    % Use provider check combined from recurrent_paytool and payment check
    _ = acceptable_payment_terms(Terms#domain_ProvisionTermSet.payments, VS),
    acceptable_recurrent_paytool_terms(Terms#domain_ProvisionTermSet.recurrent_paytools, VS).

acceptable_payment_terms(
    #domain_PaymentsProvisionTerms{
        allow = Allow,
        global_allow = GlobalAllow,
        currencies = CurrenciesSelector,
        categories = CategoriesSelector,
        payment_methods = PMsSelector,
        cash_limit = CashLimitSelector,
        holds = HoldsTerms,
        refunds = RefundsTerms,
        risk_coverage = RiskCoverageSelector
    },
    VS
) ->
    % TODO varsets getting mixed up
    %      it seems better to pass down here hierarchy of contexts w/ appropriate module accessors
    ParentName = 'PaymentsProvisionTerms',
    _ = acceptable_allow(ParentName, global_allow, GlobalAllow),
    _ = acceptable_allow(ParentName, allow, Allow),
    _ = try_accept_term(ParentName, currency, getv(currency, VS), CurrenciesSelector),
    _ = try_accept_term(ParentName, category, getv(category, VS), CategoriesSelector),
    _ = try_accept_term(ParentName, payment_tool, getv(payment_tool, VS), PMsSelector),
    _ = try_accept_term(ParentName, cost, getv(cost, VS), CashLimitSelector),
    _ = acceptable_holds_terms(HoldsTerms, getv(flow, VS, undefined)),
    _ = acceptable_refunds_terms(RefundsTerms, getv(refunds, VS, undefined)),
    _ = acceptable_risk(ParentName, RiskCoverageSelector, VS),
    %% TODO Check chargeback terms when there will be any
    %% _ = acceptable_chargeback_terms(...)
    true;
acceptable_payment_terms(undefined, _VS) ->
    throw(?rejected({'PaymentsProvisionTerms', undefined})).

acceptable_holds_terms(_Terms, undefined) ->
    true;
acceptable_holds_terms(_Terms, instant) ->
    true;
acceptable_holds_terms(Terms, {hold, Lifetime}) ->
    case Terms of
        #domain_PaymentHoldsProvisionTerms{lifetime = LifetimeSelector} ->
            _ = try_accept_term('PaymentHoldsProvisionTerms', lifetime, Lifetime, LifetimeSelector),
            true;
        undefined ->
            throw(?rejected({'PaymentHoldsProvisionTerms', undefined}))
    end.

acceptable_risk(_ParentName, undefined, _VS) ->
    true;
acceptable_risk(ParentName, Selector, VS) ->
    RiskCoverage = get_selector_value(risk_coverage, Selector),
    RiskScore = getv(risk_score, VS),
    hg_inspector:compare_risk_score(RiskCoverage, RiskScore) >= 0 orelse
        throw(?rejected({ParentName, risk_coverage})).

acceptable_refunds_terms(_Terms, undefined) ->
    true;
acceptable_refunds_terms(
    #domain_PaymentRefundsProvisionTerms{
        partial_refunds = PartialRefundsTerms
    },
    RVS
) ->
    _ = acceptable_partial_refunds_terms(
        PartialRefundsTerms,
        getv(partial, RVS, undefined)
    ),
    true;
acceptable_refunds_terms(undefined, _RVS) ->
    throw(?rejected({'PaymentRefundsProvisionTerms', undefined})).

acceptable_partial_refunds_terms(_Terms, undefined) ->
    true;
acceptable_partial_refunds_terms(
    #domain_PartialRefundsProvisionTerms{cash_limit = CashLimitSelector},
    #{cash_limit := MerchantLimit}
) ->
    ProviderLimit = get_selector_value(cash_limit, CashLimitSelector),
    hg_cash_range:is_subrange(MerchantLimit, ProviderLimit) == true orelse
        throw(?rejected({'PartialRefundsProvisionTerms', cash_limit}));
acceptable_partial_refunds_terms(undefined, _RVS) ->
    throw(?rejected({'PartialRefundsProvisionTerms', undefined})).

acceptable_allow(_ParentName, _Type, undefined) ->
    true;
acceptable_allow(_ParentName, _Type, {constant, true}) ->
    true;
acceptable_allow(ParentName, Type, {constant, false}) ->
    throw(?rejected({ParentName, Type}));
acceptable_allow(_ParentName, Type, Ambiguous) ->
    erlang:error({misconfiguration, {'Could not reduce predicate to a value', {Type, Ambiguous}}}).

%%

acceptable_recurrent_paytool_terms(
    #domain_RecurrentPaytoolsProvisionTerms{
        categories = CategoriesSelector,
        payment_methods = PMsSelector
    },
    VS
) ->
    _ = try_accept_term('RecurrentPaytoolsProvisionTerms', category, getv(category, VS), CategoriesSelector),
    _ = try_accept_term('RecurrentPaytoolsProvisionTerms', payment_tool, getv(payment_tool, VS), PMsSelector),
    true;
acceptable_recurrent_paytool_terms(undefined, _VS) ->
    throw(?rejected({'RecurrentPaytoolsProvisionTerms', undefined})).

try_accept_term(ParentName, Name, _Value, undefined) ->
    throw(?rejected({ParentName, Name}));
try_accept_term(ParentName, Name, Value, Selector) ->
    Values = get_selector_value(Name, Selector),
    test_term(Name, Value, Values) orelse throw(?rejected({ParentName, Name})).

test_term(currency, V, Vs) ->
    ordsets:is_element(V, Vs);
test_term(category, V, Vs) ->
    ordsets:is_element(V, Vs);
test_term(payment_tool, PT, PMs) ->
    hg_payment_tool:has_any_payment_method(PT, PMs);
test_term(cost, Cost, CashRange) ->
    hg_cash_range:is_inside(Cost, CashRange) == within;
test_term(lifetime, ?hold_lifetime(Lifetime), ?hold_lifetime(Allowed)) ->
    Lifetime =< Allowed.

%%

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            erlang:error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

getv(Name, VS) ->
    maps:get(Name, VS).

getv(Name, VS, Default) ->
    maps:get(Name, VS, Default).

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

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
