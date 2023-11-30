% Whitebox tests suite
-module(hg_route_rules_tests_SUITE).

-include("hg_ct_domain.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("damsel/include/dmsl_domain_conf_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").
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
-export([empty_terms_allow_test/1]).
-export([not_reduced_terms_allow_test/1]).
-export([routes_selected_for_high_risk_score/1]).
-export([routes_selected_for_low_risk_score/1]).
-export([terminal_priority_for_shop/1]).
-export([gather_pinned_route/1]).
-export([choose_pinned_route/1]).
-export([choose_route_w_override/1]).

-define(PROVIDER_MIN_ALLOWED, ?cash(1000, <<"RUB">>)).
-define(PROVIDER_MIN_ALLOWED_W_EXTRA_CASH(ExtraCash), ?cash(1000 + ExtraCash, <<"RUB">>)).
-define(dummy_party_id, <<"dummy_party_id">>).
-define(party_id_for_ruleset_w_no_delegates, <<"dummy_party_id_1">>).
-define(shop_id_for_ruleset_w_priority_distribution_1, <<"dummy_shop_id">>).
-define(shop_id_for_ruleset_w_priority_distribution_2, <<"dummy_another_shop_id">>).
-define(assert_set_equal(S1, S2), ?assertEqual(lists:sort(S1), lists:sort(S2))).
-define(assert_set_match(S1, S2), ?assertMatch(lists:sort(S1), lists:sort(S2))).

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

            choice_context_formats_ok,
            empty_terms_allow_test,
            not_reduced_terms_allow_test,

            terminal_priority_for_shop,

            gather_pinned_route,
            choose_pinned_route,
            choose_route_w_override
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
    {ok, SupPid} = hg_mock_helper:start_sup(),
    FDConfig = genlib_app:env(hellgate, fault_detector),
    application:set_env(hellgate, fault_detector, FDConfig#{enabled => true}),
    _ = unlink(SupPid),
    _ = mock_dominant(SupPid),
    _ = mock_party_management(SupPid),
    _ = mock_fault_detector(SupPid),
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
    hg_mock_helper:stop_sup(SupPid).

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> ok.
end_per_group(_GroupName, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_, C) ->
    Ctx = hg_context:set_party_client(cfg(party_client, C), hg_context:create()),
    ok = hg_context:save(Ctx),
    C.

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(_Name, _C) ->
    ok = hg_context:cleanup(),
    ok.

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

-define(base_routing_rule_domain_revision, 1).
-define(routing_with_risk_coverage_set_domain_revision, 2).
-define(routing_with_fail_rate_domain_revision, 3).
-define(terminal_priority_domain_revision, 4).
-define(pinned_route_revision, 5).
-define(empty_allow_revision, 6).
-define(not_reduced_allow_revision, 7).

mock_dominant(SupPid) ->
    Domain = construct_domain_fixture(),
    RoutingWithFailRateDomain = routing_with_risk_score_fixture(Domain, false),
    RoutingWithRiskCoverageSetDomain = routing_with_risk_score_fixture(Domain, true),
    _ = hg_mock_helper:mock_dominant(
        [
            {'Repository', fun
                ('Checkout', {{version, ?routing_with_fail_rate_domain_revision}}) ->
                    {ok, #'domain_conf_Snapshot'{
                        version = ?routing_with_fail_rate_domain_revision,
                        domain = RoutingWithFailRateDomain
                    }};
                ('Checkout', {{version, ?routing_with_risk_coverage_set_domain_revision}}) ->
                    {ok, #'domain_conf_Snapshot'{
                        version = ?routing_with_risk_coverage_set_domain_revision,
                        domain = RoutingWithRiskCoverageSetDomain
                    }};
                ('Checkout', {{version, Version}}) ->
                    {ok, #'domain_conf_Snapshot'{
                        version = Version,
                        domain = Domain
                    }}
            end}
        ],
        SupPid
    ).

mock_party_management(SupPid) ->
    _ = hg_mock_helper:mock_party_management(
        [
            {party_management, fun
                (
                    'ComputeRoutingRuleset',
                    {
                        ?ruleset(2),
                        ?terminal_priority_domain_revision,
                        #payproc_Varset{shop_id = ?shop_id_for_ruleset_w_priority_distribution_1}
                    }
                ) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate(<<"high priority">>, {constant, true}, ?trm(11), 10),
                                ?candidate(<<"low priority">>, {constant, true}, ?trm(12), 5)
                            ]}
                    }};
                (
                    'ComputeRoutingRuleset',
                    {
                        ?ruleset(2),
                        ?terminal_priority_domain_revision,
                        #payproc_Varset{shop_id = ?shop_id_for_ruleset_w_priority_distribution_2}
                    }
                ) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate(<<"low priority">>, {constant, true}, ?trm(11), 5),
                                ?candidate(<<"high priority">>, {constant, true}, ?trm(12), 10)
                            ]}
                    }};
                (
                    'ComputeRoutingRuleset',
                    {
                        ?ruleset(2),
                        ?base_routing_rule_domain_revision,
                        #payproc_Varset{party_id = ?party_id_for_ruleset_w_no_delegates}
                    }
                ) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {delegates, []}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(2), DomainRevision, _}) when
                    DomainRevision == ?pinned_route_revision
                ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate(
                                    <<"">>,
                                    {constant, true},
                                    ?trm(1),
                                    0,
                                    0,
                                    ?pin([currency, payment_tool, party_id, client_ip])
                                ),
                                ?candidate(<<"">>, {constant, true}, ?trm(2), 0, 0, ?pin([currency, payment_tool])),
                                ?candidate(<<"">>, {constant, true}, ?trm(3), 0, 0, ?pin([currency, payment_tool]))
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
                                ?candidate({constant, true}, ?trm(3)),
                                ?candidate({constant, true}, ?trm(4)),
                                ?candidate({constant, true}, ?trm(7))
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
                        DomainRevision == ?terminal_priority_domain_revision orelse
                        DomainRevision == ?pinned_route_revision
                ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"No prohibition: all candidate is allowed">>,
                        decisions = {candidates, []}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(2), ?empty_allow_revision, _}) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate({constant, true}, ?trm(5))
                            ]}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(1), ?empty_allow_revision, _}) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"No prohibition: all candidate is allowed">>,
                        decisions = {candidates, []}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(2), ?not_reduced_allow_revision, _}) ->
                    {ok, #domain_RoutingRuleset{
                        name = <<"">>,
                        decisions =
                            {candidates, [
                                ?candidate({constant, true}, ?trm(6))
                            ]}
                    }};
                ('ComputeRoutingRuleset', {?ruleset(1), ?not_reduced_allow_revision, _}) ->
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
                ('ComputeProviderTerminalTerms', {?prv(4), _, ?base_routing_rule_domain_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            allow = {constant, false}
                        }
                    }};
                ('ComputeProviderTerminalTerms', {?prv(7), _, ?base_routing_rule_domain_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            allow = {constant, true},
                            global_allow = {constant, false}
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
                ('ComputeProviderTerminalTerms', {?prv(5), _, ?empty_allow_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            allow = undefined
                        }
                    }};
                ('ComputeProviderTerminalTerms', {?prv(6), _, ?not_reduced_allow_revision, _}) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms#domain_PaymentsProvisionTerms{
                            allow = {all_of, [{constant, false}]}
                        }
                    }};
                ('ComputeProviderTerminalTerms', _) ->
                    {ok, #domain_ProvisionTermSet{
                        payments = ?payment_terms
                    }}
            end}
        ],
        SupPid
    ).

mock_fault_detector(SupPid) ->
    hg_mock_helper:mock_services(
        [
            {fault_detector, fun('GetStatistics', _) ->
                {ok, [
                    #fault_detector_ServiceStatistics{
                        service_id = <<"hellgate_service.provider_conversion.1">>,
                        failure_rate = 0.9,
                        operations_count = 10,
                        error_operations_count = 9,
                        overtime_operations_count = 0,
                        success_operations_count = 1
                    },
                    #fault_detector_ServiceStatistics{
                        service_id = <<"hellgate_service.provider_conversion.2">>,
                        failure_rate = 0.1,
                        operations_count = 10,
                        error_operations_count = 1,
                        overtime_operations_count = 0,
                        success_operations_count = 9
                    },
                    #fault_detector_ServiceStatistics{
                        service_id = <<"hellgate_service.provider_conversion.3">>,
                        failure_rate = 0.2,
                        operations_count = 10,
                        error_operations_count = 1,
                        overtime_operations_count = 0,
                        success_operations_count = 9
                    },
                    #fault_detector_ServiceStatistics{
                        service_id = <<"hellgate_service.adapter_availability.1">>,
                        failure_rate = 0.9,
                        operations_count = 10,
                        error_operations_count = 9,
                        overtime_operations_count = 0,
                        success_operations_count = 1
                    },
                    #fault_detector_ServiceStatistics{
                        service_id = <<"hellgate_service.adapter_availability.2">>,
                        failure_rate = 0.1,
                        operations_count = 10,
                        error_operations_count = 1,
                        overtime_operations_count = 0,
                        success_operations_count = 9
                    },
                    #fault_detector_ServiceStatistics{
                        service_id = <<"hellgate_service.adapter_availability.3">>,
                        failure_rate = 0.2,
                        operations_count = 10,
                        error_operations_count = 1,
                        overtime_operations_count = 0,
                        success_operations_count = 9
                    }
                ]}
            end}
        ],
        SupPid
    ).

-spec no_route_found_for_payment(config()) -> test_return().
no_route_found_for_payment(_C) ->
    Currency0 = ?cur(<<"RUB">>),
    PaymentTool = {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
    VS = #{
        category => ?cat(1),
        currency => Currency0,
        cost => ?PROVIDER_MIN_ALLOWED_W_EXTRA_CASH(-1),
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        flow => instant
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    Ctx0 = #{
        currency => Currency0,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    {ok, {[], RejectedRoutes1}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision, Ctx0),

    ?assert_set_equal(
        [
            {?prv(1), ?trm(1), {'PaymentsProvisionTerms', cost}},
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}},
            {?prv(3), ?trm(3), {'PaymentsProvisionTerms', payment_tool}},
            {?prv(4), ?trm(4), {'PaymentsProvisionTerms', allow}},
            {?prv(7), ?trm(7), {'PaymentsProvisionTerms', global_allow}}
        ],
        RejectedRoutes1
    ),

    Currency1 = ?cur(<<"EUR">>),
    VS1 = VS#{
        currency => Currency1,
        cost => ?cash(1000, <<"EUR">>)
    },
    Ctx1 = Ctx0#{
        currency => Currency1
    },
    {ok, {[], RejectedRoutes2}} = hg_routing:gather_routes(payment, PaymentInstitution, VS1, Revision, Ctx1),
    ?assert_set_equal(
        [
            {?prv(1), ?trm(1), {'PaymentsProvisionTerms', currency}},
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}},
            {?prv(3), ?trm(3), {'PaymentsProvisionTerms', payment_tool}},
            {?prv(4), ?trm(4), {'PaymentsProvisionTerms', allow}},
            {?prv(7), ?trm(7), {'PaymentsProvisionTerms', global_allow}}
        ],
        RejectedRoutes2
    ).

-spec gather_route_success(config()) -> test_return().
gather_route_success(_C) ->
    Currency = ?cur(<<"RUB">>),
    PaymentTool = {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
    VS = #{
        category => ?cat(1),
        currency => Currency,
        cost => ?PROVIDER_MIN_ALLOWED,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        flow => instant,
        risk_score => low
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    Ctx = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    {ok, {[Route], RejectedRoutes}} = hg_routing:gather_routes(
        payment,
        PaymentInstitution,
        VS,
        Revision,
        Ctx
    ),
    ?assertMatch(?trm(1), hg_route:terminal_ref(Route)),
    ?assertMatch(
        [
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}},
            {?prv(3), ?trm(3), {'PaymentsProvisionTerms', payment_tool}},
            {?prv(4), ?trm(4), {'PaymentsProvisionTerms', allow}},
            {?prv(7), ?trm(7), {'PaymentsProvisionTerms', global_allow}}
        ],
        RejectedRoutes
    ).

-spec rejected_by_table_prohibitions(config()) -> test_return().
rejected_by_table_prohibitions(_C) ->
    PaymentTool =
        {bank_card, #domain_BankCard{
            token = <<"bank card token">>,
            payment_system = ?pmt_sys(<<"visa-ref">>),
            bin = <<"411111">>,
            last_digits = <<"11">>
        }},
    Currency = ?cur(<<"RUB">>),
    VS = #{
        category => ?cat(1),
        currency => Currency,
        cost => ?PROVIDER_MIN_ALLOWED,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        flow => instant,
        risk_score => low
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    Ctx = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    {ok, {[], RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision, Ctx),
    ?assert_set_equal(
        [
            {?prv(3), ?trm(3), {'RoutingRule', undefined}},
            {?prv(1), ?trm(1), {'PaymentsProvisionTerms', payment_tool}},
            {?prv(2), ?trm(2), {'PaymentsProvisionTerms', category}},
            {?prv(4), ?trm(4), {'PaymentsProvisionTerms', allow}},
            {?prv(7), ?trm(7), {'PaymentsProvisionTerms', global_allow}}
        ],
        RejectedRoutes
    ),
    ok.

-spec empty_candidate_ok(config()) -> test_return().
empty_candidate_ok(_C) ->
    PaymentTool =
        {bank_card, #domain_BankCard{
            token = <<"bank card token">>,
            payment_system = ?pmt_sys(<<"visa-ref">>),
            bin = <<"411111">>,
            last_digits = <<"11">>
        }},
    Currency = ?cur(<<"RUB">>),
    VS = #{
        category => ?cat(1),
        currency => Currency,
        cost => ?cash(101010, <<"RUB">>),
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        flow => instant
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(2)}),
    Ctx = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    ?assertMatch(
        {ok, {[], []}},
        hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision, Ctx)
    ).

-spec ruleset_misconfig(config()) -> test_return().
ruleset_misconfig(_C) ->
    VS = #{
        party_id => ?party_id_for_ruleset_w_no_delegates,
        flow => instant
    },

    Revision = ?base_routing_rule_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    Ctx = #{
        currency => ?cur(<<"RUB">>),
        payment_tool => {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
        party_id => ?party_id_for_ruleset_w_no_delegates,
        client_ip => undefined
    },
    ?assertMatch(
        {error, {misconfiguration, {routing_decisions, {delegates, []}}}},
        hg_routing:gather_routes(
            payment,
            PaymentInstitution,
            VS,
            Revision,
            Ctx
        )
    ).

-spec routes_selected_for_low_risk_score(config()) -> test_return().
routes_selected_for_low_risk_score(C) ->
    routes_selected_with_risk_score(C, low, [?prv(1), ?prv(2), ?prv(3), ?prv(4), ?prv(7)]).

-spec routes_selected_for_high_risk_score(config()) -> test_return().
routes_selected_for_high_risk_score(C) ->
    routes_selected_with_risk_score(C, high, [?prv(2), ?prv(3), ?prv(4), ?prv(7)]).

routes_selected_with_risk_score(_C, RiskScore, ProviderRefs) ->
    Currency = ?cur(<<"RUB">>),
    PaymentTool = {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
    VS = #{
        category => ?cat(1),
        currency => Currency,
        cost => ?PROVIDER_MIN_ALLOWED,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        flow => instant,
        risk_score => RiskScore
    },
    Revision = ?routing_with_risk_coverage_set_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    Ctx = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    {ok, {Routes, _}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision, Ctx),
    ?assert_set_equal(ProviderRefs, lists:map(fun hg_route:provider_ref/1, Routes)).

-spec choice_context_formats_ok(config()) -> test_return().
choice_context_formats_ok(_C) ->
    Route1 = hg_route:new(?prv(1), ?trm(1)),
    Route2 = hg_route:new(?prv(2), ?trm(2)),
    Route3 = hg_route:new(?prv(3), ?trm(3)),
    Routes = [Route1, Route2, Route3],

    Revision = ?routing_with_fail_rate_domain_revision,
    Result = {_, Context} = hg_routing:choose_route(Routes),
    ?assertMatch(
        {Route2, #{reject_reason := availability, preferable_route := Route3}},
        Result
    ),
    ?assertMatch(
        #{
            reject_reason := availability,
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

-spec empty_terms_allow_test(config()) -> test_return().
empty_terms_allow_test(_C) ->
    do_gather_routes(?empty_allow_revision, ?trm(5), []).

-spec not_reduced_terms_allow_test(config()) -> test_return().
not_reduced_terms_allow_test(_C) ->
    Error = {'Misconfiguration', {'Could not reduce predicate to a value', {allow, {all_of, [{constant, false}]}}}},
    do_gather_routes(?not_reduced_allow_revision, undefined, [{?prv(6), ?trm(6), Error}]).

do_gather_routes(Revision, ExpectedRouteTerminal, ExpectedRejectedRoutes) ->
    Currency = ?cur(<<"RUB">>),
    PaymentTool = {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
    VS = #{
        category => ?cat(1),
        currency => Currency,
        cost => ?PROVIDER_MIN_ALLOWED,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        flow => instant,
        risk_score => low
    },

    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    Ctx = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    {ok, {Routes, RejectedRoutes}} = hg_routing:gather_routes(
        payment,
        PaymentInstitution,
        VS,
        Revision,
        Ctx
    ),
    case ExpectedRouteTerminal of
        undefined ->
            ok;
        Terminal ->
            [Route] = Routes,
            ?assertMatch(Terminal, hg_route:terminal_ref(Route))
    end,
    ?assertMatch(ExpectedRejectedRoutes, RejectedRoutes).

%%% Terminal priority tests

-spec terminal_priority_for_shop(config()) -> test_return().
terminal_priority_for_shop(C) ->
    Route1 = hg_route:new(?prv(11), ?trm(11), 0, 10),
    Route2 = hg_route:new(?prv(12), ?trm(12), 0, 10),
    ?assertMatch({Route1, _}, terminal_priority_for_shop(?shop_id_for_ruleset_w_priority_distribution_1, C)),
    ?assertMatch({Route2, _}, terminal_priority_for_shop(?shop_id_for_ruleset_w_priority_distribution_2, C)).

terminal_priority_for_shop(ShopID, _C) ->
    Currency = ?cur(<<"RUB">>),
    PaymentTool = {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
    VS = #{
        category => ?cat(1),
        currency => Currency,
        cost => ?PROVIDER_MIN_ALLOWED,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        shop_id => ShopID,
        flow => instant
    },
    Revision = ?terminal_priority_domain_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    Ctx = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    {ok, {Routes, _RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision, Ctx),
    hg_routing:choose_route(Routes).

-spec gather_pinned_route(config()) -> test_return().
gather_pinned_route(_C) ->
    Currency = ?cur(<<"RUB">>),
    PaymentTool = {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
    VS = #{
        category => ?cat(1),
        currency => Currency,
        cost => ?PROVIDER_MIN_ALLOWED,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        flow => instant
    },
    Revision = ?pinned_route_revision,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    Ctx = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    {ok, {Routes, _RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision, Ctx),
    Pin = #{
        currency => Currency,
        payment_tool => PaymentTool
    },
    ?assert_set_equal(
        [
            hg_route:new(?prv(1), ?trm(1), 0, 0, Ctx),
            hg_route:new(?prv(2), ?trm(2), 0, 0, Pin),
            hg_route:new(?prv(3), ?trm(3), 0, 0, Pin)
        ],
        Routes
    ).

-spec choose_pinned_route(config()) -> test_return().
choose_pinned_route(_C) ->
    Currency = ?cur(<<"RUB">>),
    PaymentTool = {payment_terminal, #domain_PaymentTerminal{payment_service = ?pmt_srv(<<"euroset-ref">>)}},
    Pin1 = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id,
        client_ip => undefined
    },
    Pin2 = #{
        currency => Currency,
        payment_tool => PaymentTool,
        party_id => ?dummy_party_id
    },
    Pin3 = #{
        currency => Currency,
        payment_tool => PaymentTool
    },
    Route1 = hg_route:new(?prv(1), ?trm(1), 0, 0, Pin1),
    Route2 = hg_route:new(?prv(1), ?trm(1), 0, 0, Pin2),
    Route3 = hg_route:new(?prv(1), ?trm(1), 0, 0, Pin3),
    Routes = [
        Route1,
        Route2,
        Route3
    ],
    [ChosenRoute | _] = lists:sort(Routes),
    {ChosenRoute, _} = hg_routing:choose_route(Routes).

-spec choose_route_w_override(config()) -> test_return().
choose_route_w_override(_C) ->
    %% without overrides
    Route1 = hg_route:new(?prv(1), ?trm(1)),
    Route2 = hg_route:new(?prv(2), ?trm(2)),
    Route3 = hg_route:new(?prv(3), ?trm(3)),
    Routes = [Route1, Route2, Route3],
    {
        Route2,
        #{
            preferable_route := Route3,
            reject_reason := availability
        }
    } = hg_routing:choose_route(Routes),

    %% with overrides
    Route3WithOV = hg_route:new(?prv(3), ?trm(3), 0, 1000, #{}, #domain_RouteFaultDetectorOverrides{enabled = true}),
    RoutesWithOV = [Route1, Route2, Route3WithOV],
    {Route3WithOV, _} = hg_routing:choose_route(RoutesWithOV).

%%% Domain config fixtures

routing_with_risk_score_fixture(Domain, AddRiskScore) ->
    Domain#{
        {provider, ?prv(1)} =>
            {provider, #domain_ProviderObject{
                ref = ?prv(1),
                data = ?provider(#domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        risk_coverage = maybe_set_risk_coverage(AddRiskScore, low)
                    }
                })
            }},
        {provider, ?prv(2)} =>
            {provider, #domain_ProviderObject{
                ref = ?prv(2),
                data = ?provider(#domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        risk_coverage = maybe_set_risk_coverage(AddRiskScore, high)
                    }
                })
            }},
        {provider, ?prv(3)} =>
            {provider, #domain_ProviderObject{
                ref = ?prv(3),
                data = ?provider(#domain_ProvisionTermSet{})
            }}
    }.

construct_domain_fixture() ->
    #{
        {terminal, ?trm(1)} => {terminal, ?terminal_obj(?trm(1), ?prv(1))},
        {terminal, ?trm(2)} => {terminal, ?terminal_obj(?trm(2), ?prv(2))},
        {terminal, ?trm(3)} => {terminal, ?terminal_obj(?trm(3), ?prv(3))},
        {terminal, ?trm(4)} => {terminal, ?terminal_obj(?trm(4), ?prv(4))},
        {terminal, ?trm(5)} => {terminal, ?terminal_obj(?trm(5), ?prv(5))},
        {terminal, ?trm(6)} => {terminal, ?terminal_obj(?trm(6), ?prv(6))},
        {terminal, ?trm(7)} => {terminal, ?terminal_obj(?trm(7), ?prv(7))},
        {terminal, ?trm(11)} => {terminal, ?terminal_obj(?trm(11), ?prv(11))},
        {terminal, ?trm(12)} => {terminal, ?terminal_obj(?trm(12), ?prv(12))},
        {payment_institution, ?pinst(1)} =>
            {payment_institution, #domain_PaymentInstitutionObject{
                ref = ?pinst(1),
                data = #domain_PaymentInstitution{
                    name = <<"Test Inc.">>,
                    system_account_set = {decisions, []},
                    default_contract_template = {decisions, []},
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
                    system_account_set = {decisions, []},
                    default_contract_template = {decisions, []},
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
