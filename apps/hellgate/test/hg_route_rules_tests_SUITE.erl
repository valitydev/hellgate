% Whitebox tests suite
-module(hg_route_rules_tests_SUITE).

-include("hg_ct_domain.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("damsel/include/dmsl_domain_config_thrift.hrl").
-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").
-include_lib("damsel/include/dmsl_payment_processing_errors_thrift.hrl").
-include_lib("damsel/include/dmsl_accounter_thrift.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([no_route_found_for_payment/1]).
-export([gather_route_success/1]).
-export([rejected_by_table_prohibitions/1]).
-export([empty_candidate_ok/1]).
-export([ruleset_misconfig/1]).
-export([choice_context_formats_ok/1]).
-export([routes_selected_for_high_risk_score/1]).
-export([routes_selected_for_low_risk_score/1]).
-export([gathers_fail_rated_routes/1]).
-export([terminal_priority_for_shop/1]).

-define(dummy_party_id, <<"dummy_party_id">>).
-define(dummy_shop_id, <<"dummy_shop_id">>).
-define(dummy_another_shop_id, <<"dummy_another_shop_id">>).
-define(assert_set_equal(S1, S2), ?assertEqual(lists:sort(S1), lists:sort(S2))).

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name() :: hg_ct_helper:group_name().
-type test_return() :: _ | no_return().

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        {group, routing_rule}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {routing_rule, [parallel], [
            gather_route_success,
            no_route_found_for_payment,
            rejected_by_table_prohibitions,
            empty_candidate_ok,
            ruleset_misconfig,

            routes_selected_for_low_risk_score,
            routes_selected_for_high_risk_score,

            gathers_fail_rated_routes,
            choice_context_formats_ok,

            terminal_priority_for_shop
        ]}
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    CowboySpec = hg_dummy_provider:get_http_cowboy_spec(),
    {Apps, _Ret} = hg_ct_helper:start_apps([
        woody,
        scoper,
        bender_client,
        dmt_client,
        hg_proto,
        hellgate,
        {cowboy, CowboySpec}
    ]),
    PartyID = hg_utils:unique_id(),
    PartyClient = party_client:create_client(),
    {ok, SupPid} = hg_mock_helper:start_mocked_service_sup(),
    {ok, _} = supervisor:start_child(SupPid, hg_dummy_fault_detector:child_spec()),
    FDConfig = genlib_app:env(hellgate, fault_detector),
    application:set_env(hellgate, fault_detector, FDConfig#{enabled => true}),
    _ = unlink(SupPid),
    _ = mock_dominant(SupPid),
    _ = mock_party_management(SupPid),
    [
        {apps, Apps},
        {suite_test_sup, SupPid},
        {party_client, PartyClient},
        {party_id, PartyID}
        | C
    ].

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    SupPid = cfg(suite_test_sup, C),
    hg_mock_helper:stop_mocked_service_sup(SupPid).

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_GroupName, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_, C) ->
    Ctx = hg_context:set_party_client(cfg(party_client, C), hg_context:create()),
    ok = hg_context:save(Ctx),
    {ok, SupPid} = hg_mock_helper:start_mocked_service_sup(),
    [{test_sup, SupPid} | C].

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, C) ->
    ok = hg_context:cleanup(),
    _ = hg_mock_helper:stop_mocked_service_sup(?config(test_sup, C)),
    ok.

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

-define(base_routing_rule_domain_revision, 1).
-define(routing_with_risk_coverage_set_domain_revision, 2).
-define(routing_with_fail_rate_domain_revision, 3).
-define(terminal_priority_domain_revision, 4).
-define(gathers_fail_rated_routes_domain_revision, 5).

mock_dominant(SupPid) ->
    Domain = construct_domain_fixture(),
    RoutingWithFailRateDomain = routing_with_risk_score_fixture(Domain, false),
    RoutingWithRiskCoverageSetDomain = routing_with_risk_score_fixture(Domain, true),
    _ = hg_mock_helper:mock_services(
        [
            {repository, fun
                ('Checkout', {{version, ?routing_with_fail_rate_domain_revision}}) ->
                    {ok, #'Snapshot'{
                        version = ?routing_with_fail_rate_domain_revision,
                        domain = RoutingWithFailRateDomain
                    }};
                ('Checkout', {{version, ?routing_with_risk_coverage_set_domain_revision}}) ->
                    {ok, #'Snapshot'{
                        version = ?routing_with_risk_coverage_set_domain_revision,
                        domain = RoutingWithRiskCoverageSetDomain
                    }};
                ('Checkout', {{version, Version}}) ->
                    {ok, #'Snapshot'{
                        version = Version,
                        domain = Domain
                    }}
            end}
        ],
        [{test_sup, SupPid}]
    ).

mock_party_management(SupPid) ->
    _ = hg_mock_helper:mock_services(
        [
            {party_management, fun
                (
                    'ComputeRoutingRuleset',
                    {
                        ?ruleset(2),
                        ?terminal_priority_domain_revision,
                        #payproc_Varset{shop_id = ?dummy_shop_id}
                    }
                ) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate(<<"high priority">>, {constant, true}, ?trm(1), 10),
                                ?candidate(<<"low priority">>, {constant, true}, ?trm(2), 5)
                            ]}
                    }};
                (
                    'ComputeRoutingRuleset',
                    {
                        ?ruleset(2),
                        ?terminal_priority_domain_revision,
                        #payproc_Varset{
                            shop_id = ?dummy_another_shop_id
                        }
                    }
                ) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate(<<"low priority">>, {constant, true}, ?trm(1), 5),
                                ?candidate(<<"high priority">>, {constant, true}, ?trm(2), 10)
                            ]}
                    }};
                (
                    'ComputeRoutingRuleset',
                    {
                        ?ruleset(2),
                        ?base_routing_rule_domain_revision,
                        #payproc_Varset{party_id = <<"54321">>}
                    }
                ) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {delegates, []}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(2), ?gathers_fail_rated_routes_domain_revision, _}) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate({constant, true}, ?trm(11)),
                                ?candidate({constant, true}, ?trm(12)),
                                ?candidate({constant, true}, ?trm(13))
                            ]}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(2), DomainRevision, _}) when
                    DomainRevision == ?routing_with_fail_rate_domain_revision orelse
                        DomainRevision == ?routing_with_risk_coverage_set_domain_revision orelse
                        DomainRevision == ?base_routing_rule_domain_revision
                ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate({constant, true}, ?trm(1)),
                                ?candidate({constant, true}, ?trm(2)),
                                ?candidate({constant, true}, ?trm(3))
                            ]}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(1), ?base_routing_rule_domain_revision, _}) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate({constant, true}, ?trm(3))
                            ]}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(1), DomainRevision, _}) when
                    DomainRevision == ?routing_with_fail_rate_domain_revision orelse
                        DomainRevision == ?routing_with_risk_coverage_set_domain_revision orelse
                        DomainRevision == ?gathers_fail_rated_routes_domain_revision orelse
                        DomainRevision == ?terminal_priority_domain_revision
                ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"No prohibition: all candidate is allowed">>,
                        decisions = {candidates, []}
                    }};
                ('ComputeProviderTerminalTerms', {?prv(2), _, ?base_routing_rule_domain_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            categories =
                                {value,
                                    ?ordset([
                                        ?cat(2)
                                    ])},
                            currencies =
                                {value,
                                    ?ordset([
                                        ?cur(<<"RUB">>),
                                        ?cur(<<"EUR">>)
                                    ])}
                        }
                    }};
                ('ComputeProviderTerminalTerms', {?prv(3), _, ?base_routing_rule_domain_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            payment_methods =
                                {value,
                                    ?ordset([
                                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                    ])},
                            currencies =
                                {value,
                                    ?ordset([
                                        ?cur(<<"RUB">>),
                                        ?cur(<<"EUR">>)
                                    ])}
                        }
                    }};
                ('ComputeProviderTerminalTerms', {?prv(1), _, ?routing_with_risk_coverage_set_domain_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            risk_coverage = {value, low}
                        }
                    }};
                ('ComputeProviderTerminalTerms', {?prv(2), _, ?routing_with_risk_coverage_set_domain_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            risk_coverage = {value, high}
                        }
                    }};
                ('ComputeProviderTerminalTerms', _) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms
                    }}
            end}
        ],
        [{test_sup, SupPid}]
    ).

-spec no_route_found_for_payment(config()) -> test_return().
no_route_found_for_payment(_C) ->
    VS = #{
        category => ?cat(1),
        currency => ?cur(<<"RUB">>),
        cost => ?cash(999, <<"RUB">>),
        payment_tool => {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
        party_id => <<"12345">>,
        flow => instant
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    {ok, {[], RejectedRoutes1}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision),

    ?assert_set_equal(
        [
            {?prv(1), ?trm(1), {'PaymentsProvisionTerms', cost}},
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}},
            {?prv(3), ?trm(3), {'PaymentsProvisionTerms', payment_tool}}
        ],
        RejectedRoutes1
    ),

    VS1 = VS#{
        currency => ?cur(<<"EUR">>),
        cost => ?cash(1000, <<"EUR">>)
    },
    {ok, {[], RejectedRoutes2}} = hg_routing:gather_routes(payment, PaymentInstitution, VS1, Revision),
    ?assert_set_equal(
        [
            {?prv(1), ?trm(1), {'PaymentsProvisionTerms', currency}},
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}},
            {?prv(3), ?trm(3), {'PaymentsProvisionTerms', payment_tool}}
        ],
        RejectedRoutes2
    ).

-spec gather_route_success(config()) -> test_return().
gather_route_success(_C) ->
    VS = #{
        category => ?cat(1),
        currency => ?cur(<<"RUB">>),
        cost => ?cash(1000, <<"RUB">>),
        payment_tool => {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
        party_id => <<"12345">>,
        flow => instant,
        risk_score => low
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    {ok, {[Route], RejectedRoutes}} = hg_routing:gather_routes(
        payment,
        PaymentInstitution,
        VS,
        Revision
    ),
    ?assertMatch(?trm(1), hg_routing:terminal_ref(Route)),
    ?assertMatch(
        [
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}},
            {?prv(3), ?trm(3), {'PaymentsProvisionTerms', payment_tool}}
        ],
        RejectedRoutes
    ).

-spec rejected_by_table_prohibitions(config()) -> test_return().
rejected_by_table_prohibitions(_C) ->
    BankCard = #domain_BankCard{
        token = <<"bank card token">>,
        payment_system = ?pmt_sys(<<"visa-ref">>),
        bin = <<"411111">>,
        last_digits = <<"11">>
    },
    VS = #{
        category => ?cat(1),
        currency => ?cur(<<"RUB">>),
        cost => ?cash(1000, <<"RUB">>),
        payment_tool => {bank_card, BankCard},
        party_id => <<"12345">>,
        flow => instant,
        risk_score => low
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    {ok, {[], RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision),
    ?assert_set_equal(
        [
            {?prv(3), ?trm(3), {'RoutingRule', undefined}},
            {?prv(1), ?trm(1), {'PaymentsProvisionTerms', payment_tool}},
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}}
        ],
        RejectedRoutes
    ),
    ok.

-spec empty_candidate_ok(config()) -> test_return().
empty_candidate_ok(_C) ->
    BankCard = #domain_BankCard{
        token = <<"bank card token">>,
        payment_system = ?pmt_sys(<<"visa-ref">>),
        bin = <<"411111">>,
        last_digits = <<"11">>
    },
    VS = #{
        category => ?cat(1),
        currency => ?cur(<<"RUB">>),
        cost => ?cash(101010, <<"RUB">>),
        payment_tool => {bank_card, BankCard},
        party_id => <<"12345">>,
        flow => instant
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(2)}),
    ?assertMatch(
        {ok, {[], []}},
        hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision)
    ).

-spec ruleset_misconfig(config()) -> test_return().
ruleset_misconfig(_C) ->
    VS = #{
        party_id => <<"54321">>,
        flow => instant
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    ?assertMatch(
        {error, {misconfiguration, {routing_decisions, {delegates, []}}}},
        hg_routing:gather_routes(
            payment,
            PaymentInstitution,
            VS,
            Revision
        )
    ).

-spec routes_selected_for_low_risk_score(config()) -> test_return().
routes_selected_for_low_risk_score(C) ->
    routes_selected_with_risk_score(C, low, [?prv(1), ?prv(2), ?prv(3)]).

-spec routes_selected_for_high_risk_score(config()) -> test_return().
routes_selected_for_high_risk_score(C) ->
    routes_selected_with_risk_score(C, high, [?prv(2), ?prv(3)]).

routes_selected_with_risk_score(_C, RiskScore, ProviderRefs) ->
    VS = #{
        category => ?cat(1),
        currency => ?cur(<<"RUB">>),
        cost => ?cash(1000, <<"RUB">>),
        payment_tool => {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
        party_id => <<"12345">>,
        flow => instant,
        risk_score => RiskScore
    },
    Revision = ?routing_with_risk_coverage_set_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    {ok, {Routes, _}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision),
    ?assert_set_equal(ProviderRefs, lists:map(fun hg_routing:provider_ref/1, Routes)).

-spec gathers_fail_rated_routes(config()) -> test_return().
gathers_fail_rated_routes(_C) ->
    VS = #{
        category => ?cat(1),
        currency => ?cur(<<"RUB">>),
        cost => ?cash(1000, <<"RUB">>),
        payment_tool => {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
        party_id => <<"12345">>,
        flow => instant
    },
    Revision = ?gathers_fail_rated_routes_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    {ok, {Routes0, _RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision),
    Result = hg_routing:gather_fail_rates(Routes0),
    ?assert_set_equal(
        [
            {hg_routing:new(?prv(11), ?trm(11)), {{dead, 0.9}, {lacking, 0.9}}},
            {hg_routing:new(?prv(12), ?trm(12)), {{alive, 0.1}, {normal, 0.1}}},
            {hg_routing:new(?prv(13), ?trm(13)), {{alive, 0.0}, {normal, 0.0}}}
        ],
        Result
    ).

-spec choice_context_formats_ok(config()) -> test_return().
choice_context_formats_ok(_C) ->
    Route1 = hg_routing:new(?prv(1), ?trm(1)),
    Route2 = hg_routing:new(?prv(2), ?trm(2)),
    Route3 = hg_routing:new(?prv(3), ?trm(3)),
    Routes = [Route1, Route2, Route3],

    ProviderStatuses = [
        {{alive, 0.1}, {normal, 0.1}},
        {{alive, 0.0}, {normal, 0.1}},
        {{dead, 1.0}, {lacking, 1.0}}
    ],
    FailRatedRoutes = lists:zip(Routes, ProviderStatuses),

    Revision = ?routing_with_fail_rate_domain_revision,
    Result = {_, Context} = hg_routing:choose_rated_route(FailRatedRoutes),
    ?assertMatch(
        {Route2, #{reject_reason := availability_condition, preferable_route := Route3}},
        Result
    ),
    ?assertMatch(
        #{
            reject_reason := availability_condition,
            chosen_route := #{
                provider := #{id := 2, name := <<_/binary>>},
                terminal := #{id := 2, name := <<_/binary>>},
                priority := ?DOMAIN_CANDIDATE_PRIORITY,
                weight := ?DOMAIN_CANDIDATE_WEIGHT
            },
            preferable_route := #{
                provider := #{id := 3, name := <<_/binary>>},
                terminal := #{id := 3, name := <<_/binary>>},
                priority := ?DOMAIN_CANDIDATE_PRIORITY,
                weight := ?DOMAIN_CANDIDATE_WEIGHT
            }
        },
        hg_routing:get_logger_metadata(Context, Revision)
    ).

%%% Terminal priority tests

-spec terminal_priority_for_shop(config()) -> test_return().
terminal_priority_for_shop(C) ->
    Route1 = hg_routing:new(?prv(1), ?trm(1), 0, 10),
    Route2 = hg_routing:new(?prv(2), ?trm(2), 0, 10),
    ?assertMatch({Route1, _}, terminal_priority_for_shop(?dummy_party_id, ?dummy_shop_id, C)),
    ?assertMatch({Route2, _}, terminal_priority_for_shop(?dummy_party_id, ?dummy_another_shop_id, C)).

terminal_priority_for_shop(PartyID, ShopID, _C) ->
    VS = #{
        category => ?cat(1),
        currency => ?cur(<<"RUB">>),
        cost => ?cash(1000, <<"RUB">>),
        payment_tool => {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
        party_id => PartyID,
        shop_id => ShopID,
        flow => instant
    },
    Revision = ?terminal_priority_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    {ok, {Routes, _RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision),
    hg_routing:choose_route(Routes).

%%% Domain config fixtures

routing_with_risk_score_fixture(Domain, AddRiskScore) ->
    Domain#{
        {provider, ?prv(1)} =>
            {provider, #domain_ProviderObject{
                ref = ?prv(1),
                data = ?provider(#domain_ProvisionTermSet{
                    payments = ?payment_terms#domain_PaymentsProvisionTerms{
                        risk_coverage = maybe_set_risk_coverage(AddRiskScore, low)
                    }
                })
            }},
        {provider, ?prv(2)} =>
            {provider, #domain_ProviderObject{
                ref = ?prv(2),
                data = ?provider(#domain_ProvisionTermSet{
                    payments = ?payment_terms#domain_PaymentsProvisionTerms{
                        risk_coverage = maybe_set_risk_coverage(AddRiskScore, high)
                    }
                })
            }},
        {provider, ?prv(3)} =>
            {provider, #domain_ProviderObject{
                ref = ?prv(3),
                data = ?provider(#domain_ProvisionTermSet{
                    payments = ?payment_terms
                })
            }}
    }.

construct_domain_fixture() ->
    #{
        {terminal, ?trm(1)} => {terminal, ?terminal_obj(?trm(1), ?prv(1))},
        {terminal, ?trm(2)} => {terminal, ?terminal_obj(?trm(2), ?prv(2))},
        {terminal, ?trm(3)} => {terminal, ?terminal_obj(?trm(3), ?prv(3))},
        {terminal, ?trm(11)} => {terminal, ?terminal_obj(?trm(11), ?prv(11))},
        {terminal, ?trm(12)} => {terminal, ?terminal_obj(?trm(12), ?prv(12))},
        {terminal, ?trm(13)} => {terminal, ?terminal_obj(?trm(13), ?prv(13))},
        {contract_template, ?tmpl(1)} =>
            hg_ct_fixture:construct_contract_template(?tmpl(1), ?trms(1)),
        {system_account_set, ?sas(1)} =>
            hg_ct_fixture:construct_system_account_set(?sas(1)),
        {term_set_hierarchy, ?trms(1)} =>
            {term_set_hierarchy, #domain_TermSetHierarchyObject{
                ref = ?trms(1),
                data = #domain_TermSetHierarchy{
                    term_sets = []
                }
            }},
        {payment_institution, ?pinst(1)} =>
            {payment_institution, #domain_PaymentInstitutionObject{
                ref = ?pinst(1),
                data = #domain_PaymentInstitution{
                    name = <<"Test Inc.">>,
                    system_account_set = {value, ?sas(1)},
                    default_contract_template = {value, ?tmpl(1)},
                    % TODO do we realy need this decision hell here?
                    inspector = {decisions, []},
                    residences = [],
                    realm = test,
                    payment_routing_rules = #domain_RoutingRules{
                        policies = ?ruleset(2),
                        prohibitions = ?ruleset(1)
                    }
                }
            }},
        {payment_institution, ?pinst(2)} =>
            {payment_institution, #domain_PaymentInstitutionObject{
                ref = ?pinst(2),
                data = #domain_PaymentInstitution{
                    name = <<"Chetky Payments Inc.">>,
                    system_account_set = {value, ?sas(2)},
                    default_contract_template = {value, ?tmpl(1)},
                    inspector = {decisions, []},
                    residences = [],
                    realm = live
                }
            }}
    }.

maybe_set_risk_coverage(false, _) ->
    undefined;
maybe_set_risk_coverage(true, V) ->
    {value, V}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec prefer_alive_test() -> _.
prefer_alive_test() ->
    Route1 = hg_routing:new(?prv(1), ?trm(1)),
    Route2 = hg_routing:new(?prv(2), ?trm(2)),
    Route3 = hg_routing:new(?prv(3), ?trm(3)),
    Routes = [Route1, Route2, Route3],

    Alive = {alive, 0.0},
    Dead = {dead, 1.0},
    Normal = {normal, 0.0},

    ProviderStatuses0 = [{Alive, Normal}, {Dead, Normal}, {Dead, Normal}],
    ProviderStatuses1 = [{Dead, Normal}, {Alive, Normal}, {Dead, Normal}],
    ProviderStatuses2 = [{Dead, Normal}, {Dead, Normal}, {Alive, Normal}],

    FailRatedRoutes0 = lists:zip(Routes, ProviderStatuses0),
    FailRatedRoutes1 = lists:zip(Routes, ProviderStatuses1),
    FailRatedRoutes2 = lists:zip(Routes, ProviderStatuses2),

    {Route1, Meta0} = hg_routing:choose_rated_route(FailRatedRoutes0),
    {Route2, Meta1} = hg_routing:choose_rated_route(FailRatedRoutes1),
    {Route3, Meta2} = hg_routing:choose_rated_route(FailRatedRoutes2),

    #{reject_reason := availability_condition, preferable_route := Route3} = Meta0,
    #{reject_reason := availability_condition, preferable_route := Route3} = Meta1,
    false = maps:is_key(reject_reason, Meta2).

-spec prefer_normal_conversion_test() -> _.
prefer_normal_conversion_test() ->
    Route1 = hg_routing:new(?prv(1), ?trm(1)),
    Route2 = hg_routing:new(?prv(2), ?trm(2)),
    Route3 = hg_routing:new(?prv(3), ?trm(3)),
    Routes = [Route1, Route2, Route3],

    Alive = {alive, 0.0},
    Normal = {normal, 0.0},
    Lacking = {lacking, 1.0},

    ProviderStatuses0 = [{Alive, Normal}, {Alive, Lacking}, {Alive, Lacking}],
    ProviderStatuses1 = [{Alive, Lacking}, {Alive, Normal}, {Alive, Lacking}],
    ProviderStatuses2 = [{Alive, Lacking}, {Alive, Lacking}, {Alive, Normal}],

    FailRatedRoutes0 = lists:zip(Routes, ProviderStatuses0),
    FailRatedRoutes1 = lists:zip(Routes, ProviderStatuses1),
    FailRatedRoutes2 = lists:zip(Routes, ProviderStatuses2),

    {Route1, Meta0} = hg_routing:choose_rated_route(FailRatedRoutes0),
    {Route2, Meta1} = hg_routing:choose_rated_route(FailRatedRoutes1),
    {Route3, Meta2} = hg_routing:choose_rated_route(FailRatedRoutes2),

    #{reject_reason := conversion_condition, preferable_route := Route3} = Meta0,
    #{reject_reason := conversion_condition, preferable_route := Route3} = Meta1,
    false = maps:is_key(reject_reason, Meta2).

-spec prefer_higher_availability_test() -> _.
prefer_higher_availability_test() ->
    Route1 = hg_routing:new(?prv(1), ?trm(1)),
    Route2 = hg_routing:new(?prv(2), ?trm(2)),
    Route3 = hg_routing:new(?prv(3), ?trm(3)),
    Routes = [Route1, Route2, Route3],

    ProviderStatuses = [
        {{alive, 0.5}, {normal, 0.5}},
        {{dead, 0.8}, {lacking, 1.0}},
        {{alive, 0.6}, {normal, 0.5}}
    ],
    FailRatedRoutes = lists:zip(Routes, ProviderStatuses),

    Result = hg_routing:choose_rated_route(FailRatedRoutes),
    ?assertMatch({Route1, #{reject_reason := availability, preferable_route := Route3}}, Result).

-spec prefer_higher_conversion_test() -> _.
prefer_higher_conversion_test() ->
    Route1 = hg_routing:new(?prv(1), ?trm(1)),
    Route2 = hg_routing:new(?prv(2), ?trm(2)),
    Route3 = hg_routing:new(?prv(3), ?trm(3)),
    Routes = [Route1, Route2, Route3],

    ProviderStatuses = [
        {{dead, 0.8}, {lacking, 1.0}},
        {{alive, 0.5}, {normal, 0.3}},
        {{alive, 0.5}, {normal, 0.5}}
    ],
    FailRatedRoutes = lists:zip(Routes, ProviderStatuses),

    Result = hg_routing:choose_rated_route(FailRatedRoutes),
    ?assertMatch({Route2, #{reject_reason := conversion, preferable_route := Route3}}, Result).

-spec prefer_weight_over_availability_test() -> _.
prefer_weight_over_availability_test() ->
    Route1 = hg_routing:new(?prv(1), ?trm(1), 0, 1000),
    Route2 = hg_routing:new(?prv(2), ?trm(2), 0, 1005),
    Route3 = hg_routing:new(?prv(3), ?trm(3), 0, 1000),
    Routes = [Route1, Route2, Route3],

    ProviderStatuses = [
        {{alive, 0.3}, {normal, 0.3}},
        {{alive, 0.5}, {normal, 0.3}},
        {{alive, 0.3}, {normal, 0.3}}
    ],
    FailRatedRoutes = lists:zip(Routes, ProviderStatuses),

    ?assertMatch({Route2, _}, hg_routing:choose_rated_route(FailRatedRoutes)).

-spec prefer_weight_over_conversion_test() -> _.
prefer_weight_over_conversion_test() ->
    Route1 = hg_routing:new(?prv(1), ?trm(1), 0, 1000),
    Route2 = hg_routing:new(?prv(2), ?trm(2), 0, 1005),
    Route3 = hg_routing:new(?prv(3), ?trm(3), 0, 1000),
    Routes = [Route1, Route2, Route3],

    ProviderStatuses = [
        {{alive, 0.3}, {normal, 0.5}},
        {{alive, 0.3}, {normal, 0.3}},
        {{alive, 0.3}, {normal, 0.3}}
    ],
    FailRatedRoutes = lists:zip(Routes, ProviderStatuses),
    {Route2, _Meta} = hg_routing:choose_rated_route(FailRatedRoutes).

-endif.
