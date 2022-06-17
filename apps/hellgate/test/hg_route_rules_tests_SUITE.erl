% Whitebox tests suite
-module(hg_route_rules_tests_SUITE).

-include("hg_ct_domain.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("damsel/include/dmsl_domain_config_thrift.hrl").
-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").
-include_lib("damsel/include/dmsl_payment_processing_errors_thrift.hrl").
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
        {group, base_routing_rule},
        {group, routing_with_risk_coverage_set},
        {group, routing_with_fail_rate},
        {group, terminal_priority}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {base_routing_rule, [parallel], [
            gather_route_success,
            no_route_found_for_payment,
            rejected_by_table_prohibitions,
            empty_candidate_ok,
            ruleset_misconfig
        ]},
        {routing_with_risk_coverage_set, [parallel], [
            routes_selected_for_low_risk_score,
            routes_selected_for_high_risk_score
        ]},
        {routing_with_fail_rate, [parallel], [
            gathers_fail_rated_routes,
            choice_context_formats_ok
        ]},
        {terminal_priority, [], [
            terminal_priority_for_shop
        ]}
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    %%    genlib_adhoc_supervisor:init()
    CowboySpec = hg_dummy_provider:get_http_cowboy_spec(),
    {Apps, _Ret} = hg_ct_helper:start_apps([
        woody,
        scoper,
        dmt_client,
        bender_client,
        party_client,
        hg_proto,
        hellgate,
        {cowboy, CowboySpec}
    ]),
    _ = hg_domain:insert(construct_domain_fixture()),
    PartyID = hg_utils:unique_id(),
    PartyClient = party_client:create_client(),
    {ok, SupPid} = genlib_adhoc_supervisor:start_link(
        #{strategy => one_for_all, intensity => 1, period => 1}, []
    ),
    {ok, _} = supervisor:start_child(SupPid, hg_dummy_fault_detector:child_spec()),
    FDConfig = genlib_app:env(hellgate, fault_detector),
    application:set_env(hellgate, fault_detector, FDConfig#{enabled => true}),
    _ = unlink(SupPid),
    [
        {apps, Apps},
        {test_sup, SupPid},
        {party_client, PartyClient},
        {party_id, PartyID}
        | C
    ].

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    SupPid = cfg(test_sup, C),
    ok = supervisor:terminate_child(SupPid, hg_dummy_fault_detector),
    _ = hg_domain:cleanup().

-spec init_per_group(group_name(), config()) -> config().
init_per_group(base_routing_rule, C) ->
    _ = hg_domain:upsert(base_routing_rules_fixture(latest)),
    C;
init_per_group(routing_with_risk_coverage_set, C) ->
    _ = hg_domain:upsert(routing_with_risk_score_fixture(latest, true)),
    C;
init_per_group(routing_with_fail_rate, C) ->
    _ = hg_domain:upsert(routing_with_risk_score_fixture(latest, false)),
    C;
init_per_group(terminal_priority, C) ->
    _ = hg_domain:upsert(terminal_priority_fixture(latest)),
    C;
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_GroupName, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_, C) ->
    Ctx = hg_context:set_party_client(cfg(party_client, C), hg_context:create()),
    ok = hg_context:save(Ctx),
    C.

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, _C) ->
    ok = hg_context:cleanup(),
    ok.

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

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

    Revision = hg_domain:head(),
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

    Revision = hg_domain:head(),
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

    Revision = hg_domain:head(),
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

    Revision = hg_domain:head(),
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(2)}),
    {ok, {[], []}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision).

-spec ruleset_misconfig(config()) -> test_return().
ruleset_misconfig(_C) ->
    VS = #{
        party_id => <<"54321">>,
        flow => instant
    },

    Revision = hg_domain:head(),
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    {error, {misconfiguration, {routing_decisions, {delegates, []}}}} = hg_routing:gather_routes(
        payment,
        PaymentInstitution,
        VS,
        Revision
    ).

-spec routes_selected_for_low_risk_score(config()) -> test_return().
routes_selected_for_low_risk_score(C) ->
    routes_selected_with_risk_score(C, low, [?prv(21), ?prv(22), ?prv(23)]).

-spec routes_selected_for_high_risk_score(config()) -> test_return().
routes_selected_for_high_risk_score(C) ->
    routes_selected_with_risk_score(C, high, [?prv(22), ?prv(23)]).

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
    Revision = hg_domain:head(),
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
    Revision = hg_domain:head(),
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),

    {ok, {Routes0, _RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision),
    Result = hg_routing:gather_fail_rates(Routes0),
    ?assert_set_equal(
        [
            {hg_routing:new(?prv(21), ?trm(21)), {{dead, 0.9}, {lacking, 0.9}}},
            {hg_routing:new(?prv(22), ?trm(22)), {{alive, 0.1}, {normal, 0.1}}},
            {hg_routing:new(?prv(23), ?trm(23)), {{alive, 0.0}, {normal, 0.0}}}
        ],
        Result
    ).

-spec choice_context_formats_ok(config()) -> test_return().
choice_context_formats_ok(_C) ->
    Sup = hg_mock_helper:start_mocked_service_sup(),
    _ = hg_mock_helper:mock_services(
        [
            {repository_client, fun('checkoutObject', ok) -> {ok, 1} end}
        ],
        [{test_sup, Sup}]
    ),

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

    Revision = 42,
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
    ),
    hg_mock_helper:stop_mocked_service_sup(Sup).

%%% Terminal priority tests

-spec terminal_priority_for_shop(config()) -> test_return().
terminal_priority_for_shop(C) ->
    Route1 = hg_routing:new(?prv(41), ?trm(41), 0, 10),
    Route2 = hg_routing:new(?prv(42), ?trm(42), 0, 10),
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
    Revision = hg_domain:head(),
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    {ok, {Routes, _RejectedRoutes}} = hg_routing:gather_routes(payment, PaymentInstitution, VS, Revision),
    hg_routing:choose_route(Routes).

%%% Domain config fixtures

base_routing_rules_fixture(Revision) ->
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstitution#domain_PaymentInstitution{
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(1)
                }
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(1),
            data = #domain_RoutingRuleset{
                name = <<"Prohibition: bank_card terminal is denied">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(3))
                    ]}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {delegates, [
                        ?delegate(condition(party, <<"12345">>), ?ruleset(3))
                    ]}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(3),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(1)),
                        ?candidate({constant, true}, ?trm(2)),
                        ?candidate({constant, true}, ?trm(3))
                    ]}
            }
        }},
        {terminal, ?terminal_obj(?trm(1), ?prv(1))},
        {terminal, ?terminal_obj(?trm(2), ?prv(2))},
        {terminal, ?terminal_obj(?trm(3), ?prv(3))},
        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms
            })
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(2),
            data = ?provider(#domain_ProvisionTermSet{
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
            })
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(3),
            data = ?provider(#domain_ProvisionTermSet{
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
            })
        }}
    ].

routing_with_risk_score_fixture(Revision, AddRiskScore) ->
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstitution#domain_PaymentInstitution{
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(1)
                }
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {delegates, [
                        ?delegate(condition(party, <<"12345">>), ?ruleset(3)),
                        ?delegate(condition(party, <<"54321">>), ?ruleset(4))
                    ]}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(3),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(21)),
                        ?candidate({constant, true}, ?trm(22)),
                        ?candidate({constant, true}, ?trm(23))
                    ]}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(4),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(21)),
                        ?candidate(<<"high priority">>, {constant, true}, ?trm(22), 1005),
                        ?candidate({constant, true}, ?trm(23))
                    ]}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(1),
            data = #domain_RoutingRuleset{
                name = <<"No prohibition: all candidate is allowed">>,
                decisions = {candidates, []}
            }
        }},
        {terminal, ?terminal_obj(?trm(21), ?prv(21))},
        {terminal, ?terminal_obj(?trm(22), ?prv(22))},
        {terminal, ?terminal_obj(?trm(23), ?prv(23))},
        {provider, #domain_ProviderObject{
            ref = ?prv(21),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms#domain_PaymentsProvisionTerms{
                    risk_coverage = maybe_set_risk_coverage(AddRiskScore, low)
                }
            })
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(22),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms#domain_PaymentsProvisionTerms{
                    risk_coverage = maybe_set_risk_coverage(AddRiskScore, high)
                }
            })
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(23),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms
            })
        }}
    ].

terminal_priority_fixture(Revision) ->
    PartyID = ?dummy_party_id,
    ShopID = ?dummy_shop_id,
    AnotherShopID = ?dummy_another_shop_id,
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstitution#domain_PaymentInstitution{
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(1)
                }
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {delegates, [
                        ?delegate(condition(party_shop, PartyID, ShopID), ?ruleset(3)),
                        ?delegate(condition(party_shop, PartyID, AnotherShopID), ?ruleset(4))
                    ]}
            }
        }},

        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(3),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate(<<"high priority">>, {constant, true}, ?trm(41), 10),
                        ?candidate(<<"low priority">>, {constant, true}, ?trm(42), 5)
                    ]}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(4),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate(<<"low priority">>, {constant, true}, ?trm(41), 5),
                        ?candidate(<<"high priority">>, {constant, true}, ?trm(42), 10)
                    ]}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(1),
            data = #domain_RoutingRuleset{
                name = <<"No prohibition: all candidate is allowed">>,
                decisions = {candidates, []}
            }
        }},

        {terminal, ?terminal_obj(?trm(41), ?prv(41))},
        {terminal, ?terminal_obj(?trm(42), ?prv(42))},
        {provider, #domain_ProviderObject{
            ref = ?prv(41),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms
            })
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(42),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms
            })
        }}
    ].

construct_domain_fixture() ->
    [
        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),
        hg_ct_fixture:construct_currency(?cur(<<"USD">>)),
        hg_ct_fixture:construct_currency(?cur(<<"EUR">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),
        hg_ct_fixture:construct_category(?cat(2), <<"Generic Store">>, live),

        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(payment_terminal, ?pmt_srv(<<"euroset-ref">>))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_contract_template(?tmpl(1), ?trms(1)),

        hg_ct_fixture:construct_system_account_set(?sas(1)),
        hg_ct_fixture:construct_system_account_set(?sas(2)),
        hg_ct_fixture:construct_external_account_set(?eas(1)),

        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set =
                    {decisions, [
                        #domain_ExternalAccountSetDecision{
                            if_ = {constant, true},
                            then_ = {value, ?eas(1)}
                        }
                    ]},
                payment_institutions = ?ordset([?pinst(1), ?pinst(2)])
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_sets = []
            }
        }},
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                default_contract_template = {value, ?tmpl(1)},
                % TODO do we realy need this decision hell here?
                inspector = {decisions, []},
                residences = [],
                realm = test
            }
        }},
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
    ].

condition(party, ID) ->
    {condition, {party, #domain_PartyCondition{id = ID}}}.

condition(party_shop, PartyID, ShopID) ->
    {condition, {party, #domain_PartyCondition{id = PartyID, definition = {shop_is, ShopID}}}}.

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
