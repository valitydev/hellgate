-module(ct_payment_system).

-export([setup/0]).
-export([setup/1]).
-export([shutdown/1]).

%% API types

-type options() :: #{
    identity_provider_config => map(),
    services => map(),
    domain_config => list(),
    default_termset => dmsl_domain_thrift:'TermSet'(),
    company_termset => dmsl_domain_thrift:'TermSet'(),
    payment_inst_identity_id => id(),
    dummy_payment_inst_identity_id => id(),
    provider_identity_id => id(),
    dummy_provider_identity_id => id(),
    optional_apps => list(),
    setup_dominant => fun((config()) -> config())
}.

-opaque system() :: #{
    started_apps := [atom()],
    suite_sup := pid()
}.

-export_type([options/0]).
-export_type([system/0]).

%% Internal types

-type id() :: binary().
-type config() :: ct_helper:config().

%% API

-spec setup() -> fun((config()) -> config()).
setup() ->
    setup(#{}).

-spec setup(options()) -> fun((config()) -> config()).
setup(Options) ->
    fun(C) -> do_setup(Options, C) end.

-spec shutdown(config()) -> ok.
shutdown(C) ->
    #{started_apps := Apps, suite_sup := Sup} = ct_helper:cfg(payment_system, C),
    ok = ct_sup:stop(Sup),
    ok = ct_helper:stop_apps(Apps).

%% Internals

-spec do_setup(options(), config()) -> config().
do_setup(Options0, C0) ->
    Options = Options0#{
        payment_inst_identity_id => genlib:unique(),
        dummy_payment_inst_identity_id => genlib:unique(),
        provider_identity_id => genlib:unique(),
        dummy_provider_identity_id => genlib:unique()
    },
    {ok, Processing0} = start_processing_apps(Options),
    C1 = ct_helper:makeup_cfg([ct_helper:woody_ctx()], [{services, services(Options)} | C0]),
    ok = ct_helper:set_context(C1),
    C2 = setup_dominant(C1, Options),
    ok = configure_processing_apps(Options),
    ok = ct_helper:unset_context(),
    [{payment_system, Processing0} | C2].

start_processing_apps(Options) ->
    {StartedApps, _StartupCtx} = ct_helper:start_apps([
        {epg_connector, [
            {databases, epg_databases()},
            {pools, epg_pools()}
        ]},
        {progressor, [
            {call_wait_timeout, 20},
            {defaults, progressor_defaults()},
            {namespaces, progressor_namespaces()}
        ]},
        scoper,
        woody,
        dmt_client,
        party_client,
        {fistful, [
            {machinery_backend, hybrid},
            {services, services(Options)}
        ]},
        ff_server,
        bender_client
    ]),
    SuiteSup = ct_sup:start(),
    {ok, _} = supervisor:start_child(
        SuiteSup,
        woody_server:child_spec(
            ?MODULE,
            #{
                ip => {127, 0, 0, 1},
                port => 8222,
                handlers => [
                    {
                        <<"/bank">>,
                        {{dmsl_wthd_provider_thrift, 'Adapter'}, {ff_ct_provider_handler, []}}
                    },
                    {
                        <<"/quotebank">>,
                        {{dmsl_wthd_provider_thrift, 'Adapter'}, {ff_ct_provider_handler, []}}
                    },
                    {
                        <<"/downbank">>,
                        {
                            {dmsl_wthd_provider_thrift, 'Adapter'},
                            {ff_ct_provider_handler, [{handler, ff_ct_fail_provider}]}
                        }
                    },
                    {
                        <<"/downbank2">>,
                        {
                            {dmsl_wthd_provider_thrift, 'Adapter'},
                            {ff_ct_provider_handler, [{handler, ff_ct_unknown_failure_provider}]}
                        }
                    },
                    {
                        <<"/sleepybank">>,
                        {
                            {dmsl_wthd_provider_thrift, 'Adapter'},
                            {ff_ct_provider_handler, [{handler, ff_ct_sleepy_provider}]}
                        }
                    },
                    {
                        <<"/binbase">>,
                        {{binbase_binbase_thrift, 'Binbase'}, {ff_ct_binbase_handler, []}}
                    }
                ],
                event_handler => ff_woody_event_handler
            }
        )
    ),
    Processing = #{
        started_apps => StartedApps ++ start_optional_apps(Options),
        suite_sup => SuiteSup
    },
    {ok, Processing}.

start_optional_apps(#{optional_apps := Apps}) ->
    {StartedApps, _StartupCtx} = ct_helper:start_apps(Apps),
    StartedApps;
start_optional_apps(_) ->
    [].

setup_dominant(Config0, Options) ->
    Config1 = setup_dominant_internal(Config0, Options),
    DomainConfig = domain_config(Config1, Options),
    _ = ct_domain_config:upsert(DomainConfig),
    DomainConfigUpdate = domain_config_add_version(Options),
    _ = ct_domain_config:upsert(DomainConfigUpdate),
    Config1.

setup_dominant_internal(Config, #{setup_dominant := Func}) when is_function(Func, 1) ->
    Func(Config);
setup_dominant_internal(Config, _Options) ->
    Config.

configure_processing_apps(_Options) ->
    ok = set_app_env(
        [ff_transfer, withdrawal, system, accounts, settlement, <<"RUB">>],
        create_company_account()
    ),
    ok = set_app_env(
        [ff_transfer, withdrawal, system, accounts, subagent, <<"RUB">>],
        create_company_account()
    ),
    ok = set_app_env(
        [ff_transfer, withdrawal, provider, <<"mocketbank">>, accounts, <<"RUB">>],
        create_company_account()
    ).

create_company_account() ->
    PartyID = ct_objects:create_party(),
    {ok, Currency} = ff_currency:get(<<"RUB">>),
    {ok, [{created, Account}]} = ff_account:create(PartyID, live, Currency),
    Account.

set_app_env([App, Key | Path], Value) ->
    Env = genlib_app:env(App, Key, #{}),
    NewEnv = do_set_env(Path, Value, Env),
    application:set_env(App, Key, NewEnv).

do_set_env([], Value, _Env) ->
    Value;
do_set_env([Key | Path], Value, Env) ->
    SubEnv = maps:get(Key, Env, #{}),
    Env#{Key => do_set_env(Path, Value, SubEnv)}.

%% Default options

services(Options) ->
    Default = #{
        ff_withdrawal_adapter_host => "http://fistful-server:8022/v1/ff_withdrawal_adapter_host",
        automaton => "http://machinegun:8022/v1/automaton",
        accounter => "http://shumway:8022/accounter",
        partymgmt => "http://party-management:8022/v1/processing/partymgmt",
        binbase => "http://localhost:8222/binbase",
        limiter => "http://limiter:8022/v1/limiter",
        party_config => "http://party-management:8022/v1/processing/partymgmt"
    },
    maps:get(services, Options, Default).

epg_databases() ->
    #{
        default_db => #{
            host => "db",
            port => 5432,
            database => "fistful",
            username => "fistful",
            password => "postgres"
        }
    }.

epg_pools() ->
    #{
        default_pool => #{
            database => default_db,
            size => 30
        }
    }.

progressor_defaults() ->
    #{
        storage => #{
            client => prg_pg_backend,
            options => #{
                pool => default_pool
            }
        },
        retry_policy => #{
            initial_timeout => 5,
            backoff_coefficient => 1.0,
            %% seconds
            max_timeout => 180,
            max_attempts => 3,
            non_retryable_errors => []
        },
        task_scan_timeout => 1,
        worker_pool_size => 100,
        process_step_timeout => 30
    }.

progressor_namespaces() ->
    #{
        'ff/source_v1' => #{
            processor => #{
                client => machinery_prg_backend,
                options => #{
                    namespace => 'ff/source_v1',
                    %% TODO Party client create
                    handler => {fistful, #{handler => ff_source_machine, party_client => #{}}},
                    schema => ff_source_machinery_schema
                }
            }
        },
        'ff/destination_v2' => #{
            processor => #{
                client => machinery_prg_backend,
                options => #{
                    namespace => 'ff/destination_v2',
                    %% TODO Party client create
                    handler => {fistful, #{handler => ff_destination_machine, party_client => #{}}},
                    schema => ff_destination_machinery_schema
                }
            }
        },
        'ff/deposit_v1' => #{
            processor => #{
                client => machinery_prg_backend,
                options => #{
                    namespace => 'ff/deposit_v1',
                    %% TODO Party client create
                    handler => {fistful, #{handler => ff_deposit_machine, party_client => #{}}},
                    schema => ff_deposit_machinery_schema
                }
            }
        },
        'ff/withdrawal_v2' => #{
            processor => #{
                client => machinery_prg_backend,
                options => #{
                    namespace => 'ff/withdrawal_v2',
                    %% TODO Party client create
                    handler => {fistful, #{handler => ff_withdrawal_machine, party_client => #{}}},
                    schema => ff_withdrawal_machinery_schema
                }
            }
        },
        'ff/withdrawal/session_v2' => #{
            processor => #{
                client => machinery_prg_backend,
                options => #{
                    namespace => 'ff/withdrawal/session_v2',
                    %% TODO Party client create
                    handler => {fistful, #{handler => ff_withdrawal_session_machine, party_client => #{}}},
                    schema => ff_withdrawal_session_machinery_schema
                }
            }
        }
    }.

%%

-include_lib("ff_cth/include/ct_domain.hrl").

% NOTE
% Allocate those domain object identifiers at least 100 apart from each other.
% This space might be used to define additional object in place (see below).
-define(EMPTY_ROUTING_RULESET, 0).
-define(PAYINST1_ROUTING_POLICIES, 100).
-define(PAYINST1_ROUTING_PROHIBITIONS, 200).
-define(PAYINST2_ROUTING_POLICIES, 300).

domain_config_add_version(_Options) ->
    {ok, Provider} = ff_domain_config:object({provider, ?prv(1)}),
    #domain_Provider{
        accounts = #{
            ?cur(<<"RUB">>) := #domain_ProviderAccount{settlement = AccountID}
        }
    } = Provider,
    ProviderTermSet = #domain_ProvisionTermSet{
        wallet = #domain_WalletProvisionTerms{
            withdrawals = #domain_WithdrawalProvisionTerms{
                currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                cash_limit =
                    {value,
                        ?cashrng(
                            {inclusive, ?cash(0, <<"RUB">>)},
                            {exclusive, ?cash(10000000, <<"RUB">>)}
                        )},
                cash_flow =
                    {decisions, [
                        #domain_CashFlowDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {system, settlement},
                                        {provider, settlement},
                                        {product,
                                            {min_of,
                                                ?ordset([
                                                    ?fixed(10, <<"RUB">>),
                                                    ?share(5, 100, operation_amount, round_half_towards_zero)
                                                ])}}
                                    )
                                ]}
                        }
                    ]}
            }
        }
    },
    [
        ct_domain:withdrawal_provider(AccountID, ?prv(1), ?prx(2), live, ProviderTermSet)
    ].

domain_config(Config, Options) ->
    ProviderTermSet = #domain_ProvisionTermSet{
        wallet = #domain_WalletProvisionTerms{
            withdrawals = #domain_WithdrawalProvisionTerms{
                currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                cash_limit =
                    {value,
                        ?cashrng(
                            {inclusive, ?cash(0, <<"RUB">>)},
                            {exclusive, ?cash(10000000, <<"RUB">>)}
                        )},
                cash_flow =
                    {decisions, [
                        #domain_CashFlowDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {system, settlement},
                                        {provider, settlement},
                                        {product,
                                            {min_of,
                                                ?ordset([
                                                    ?fixed(10, <<"RUB">>),
                                                    ?share(5, 100, operation_amount, round_half_towards_zero)
                                                ])}}
                                    )
                                ]}
                        }
                    ]}
            }
        }
    },
    TempProviderTermSet = #domain_ProvisionTermSet{
        wallet = #domain_WalletProvisionTerms{
            withdrawals = #domain_WithdrawalProvisionTerms{
                currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                cash_limit =
                    {value,
                        ?cashrng(
                            {inclusive, ?cash(0, <<"RUB">>)},
                            {exclusive, ?cash(10000000, <<"RUB">>)}
                        )},
                cash_flow =
                    {decisions, [
                        #domain_CashFlowDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {system, settlement},
                                        {provider, settlement},
                                        ?fixed(2, <<"RUB">>)
                                    )
                                ]}
                        }
                    ]}
            }
        }
    },
    Default = [
        ct_domain:globals(?eas(1), [?payinst(1)]),
        ct_domain:external_account_set(?eas(1), <<"Default">>, ?cur(<<"RUB">>)),

        ct_domain:build_party_obj(<<"12345">>),
        ct_domain:build_party_obj(<<"67890">>),

        routing_ruleset(
            ?ruleset(?EMPTY_ROUTING_RULESET),
            <<"Empty Ruleset">>,
            {candidates, []}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES),
            <<"PayInst1 Withdrawal Ruleset">>,
            {delegates, [
                delegate(condition(party, <<"12345">>), ?ruleset(?PAYINST1_ROUTING_POLICIES + 1)),
                delegate(condition(party, <<"67890">>), ?ruleset(?PAYINST1_ROUTING_POLICIES + 3)),
                delegate({constant, true}, ?ruleset(?PAYINST1_ROUTING_POLICIES + 4))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 1),
            {delegates, [
                delegate(condition(cost_in, {0, 1000, <<"RUB">>}), ?ruleset(?PAYINST1_ROUTING_POLICIES + 2))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 2),
            {candidates, [
                candidate({constant, true}, ?trm(1)),
                candidate({constant, true}, ?trm(2))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 3),
            {candidates, [
                candidate({constant, true}, ?trm(3)),
                candidate({constant, true}, ?trm(4)),
                candidate({constant, true}, ?trm(5))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 4),
            {delegates, [
                delegate(
                    condition(cost_in, {300, 302, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 5)
                ),
                delegate(
                    condition(cost_in, {123123, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 6)
                ),
                delegate(
                    condition(cost_in, {100500, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 10)
                ),
                delegate(
                    condition(cost_in, {500100, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 11)
                ),
                delegate(
                    condition(cost_in, {500500, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 12)
                ),
                delegate(
                    condition(cost_in, {700700, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 13)
                ),
                delegate(
                    condition(cost_in, {800800, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 16)
                ),
                delegate(
                    condition(cost_in, {900900, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 17)
                ),
                delegate(
                    condition(cost_in, {901000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 18)
                ),
                delegate(
                    condition(cost_in, {902000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 19)
                ),
                delegate(
                    condition(cost_in, {903000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 19)
                ),
                delegate(
                    condition(cost_in, {904000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 20)
                ),
                delegate(
                    condition(cost_in, {3000000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 21)
                ),
                delegate(
                    condition(cost_in, {905000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 22)
                ),
                delegate(
                    condition(cost_in, {3001000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 23)
                ),
                delegate(
                    condition(cost_in, {3002000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 24)
                ),
                delegate(
                    condition(cost_in, {910000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 30)
                ),
                delegate(
                    condition(cost_in, {920000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 31)
                ),
                delegate(
                    condition(cost_in, {930000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 32)
                ),
                delegate(
                    condition(cost_in, {940000, <<"RUB">>}),
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 33)
                ),
                delegate(
                    {condition,
                        {payment_tool,
                            {bank_card, #domain_BankCardCondition{
                                definition = {issuer_country_is, 'rus'}
                            }}}},
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 14)
                ),
                delegate(
                    {condition, {payment_tool, {crypto_currency, #domain_CryptoCurrencyCondition{}}}},
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 15)
                ),
                delegate(
                    {condition,
                        {payment_tool,
                            {digital_wallet, #domain_DigitalWalletCondition{
                                definition = {payment_service_is, ?pmtsrv(<<"webmoney">>)}
                            }}}},
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 15)
                ),
                delegate(
                    {condition,
                        {payment_tool,
                            {generic,
                                {payment_service_is, #domain_PaymentServiceRef{
                                    id = <<"IND">>
                                }}}}},
                    ?ruleset(?PAYINST1_ROUTING_POLICIES + 15)
                )
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 5),
            {candidates, [
                candidate(condition(cost_in, {300, <<"RUB">>}), ?trm(1701)),
                candidate(condition(cost_in, {301, <<"RUB">>}), ?trm(1708))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 6),
            {candidates, [
                candidate({constant, true}, ?trm(6))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 10),
            {candidates, [
                % provider 4 will be discarded by proxy 6
                candidate({constant, true}, ?trm(401)),
                candidate({constant, true}, ?trm(501))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 11),
            {candidates, [
                candidate({constant, true}, ?trm(401)),
                candidate({constant, true}, ?trm(601)),
                candidate({constant, true}, ?trm(701)),
                candidate({constant, true}, ?trm(801))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 12),
            {candidates, [
                candidate({constant, true}, ?trm(901), 500),
                candidate({constant, true}, ?trm(1001), 1000)
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 13),
            {candidates, [
                candidate({constant, true}, ?trm(1101))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 14),
            {candidates, [
                candidate(
                    condition(cost_in, {0, 1000000, <<"RUB">>}),
                    ?trm(1)
                ),
                candidate(
                    condition(cost_in, {3000000, 10000000, <<"RUB">>}),
                    ?trm(307)
                )
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 15),
            {candidates, [
                candidate(
                    condition(cost_in, {0, 1000000, <<"RUB">>}),
                    ?trm(201)
                ),
                candidate(
                    condition(cost_in, {3000000, 10000000, <<"RUB">>}),
                    ?trm(307)
                )
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 16),
            {candidates, [
                candidate({constant, true}, ?trm(1800))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 17),
            {candidates, [
                candidate({constant, true}, ?trm(1900))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 18),
            {candidates, [
                candidate({constant, true}, ?trm(2000), 1000),
                candidate({constant, true}, ?trm(1900), 4000)
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 19),
            {candidates, [
                candidate({constant, true}, ?trm(2200), 1000),
                candidate({constant, true}, ?trm(2100), 4000)
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 20),
            {candidates, [
                candidate({constant, true}, ?trm(2300), 4000),
                candidate({constant, true}, ?trm(2400), 1000)
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 21),
            {candidates, [
                candidate({constant, true}, ?trm(2400))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 22),
            {candidates, [
                candidate({constant, true}, ?trm(2500), 4000),
                candidate({constant, true}, ?trm(2600), 1000)
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 23),
            {candidates, [
                candidate({constant, true}, ?trm(2700))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 24),
            {candidates, [
                candidate({constant, true}, ?trm(2800))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 30),
            {candidates, [
                candidate({constant, true}, ?trm(3000))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 31),
            {candidates, [
                candidate({constant, true}, ?trm(3100))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 32),
            {candidates, [
                candidate({constant, true}, ?trm(3200))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_POLICIES + 33),
            {candidates, [
                candidate({constant, true}, ?trm(3300))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST1_ROUTING_PROHIBITIONS),
            <<"PayInst1 Withdrawal Prohibitions">>,
            {candidates, [
                candidate({constant, true}, ?trm(4))
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST2_ROUTING_POLICIES),
            <<"PayInst2 Withdrawal Ruleset">>,
            {delegates, [
                delegate(
                    condition(cost_in, {123, <<"RUB">>}),
                    ?ruleset(?PAYINST2_ROUTING_POLICIES + 1)
                ),
                delegate(
                    {condition,
                        {payment_tool,
                            {crypto_currency, #domain_CryptoCurrencyCondition{
                                definition = {crypto_currency_is, ?crptcur(<<"Litecoin">>)}
                            }}}},
                    ?ruleset(?PAYINST2_ROUTING_POLICIES + 1)
                ),
                delegate(
                    {condition,
                        {payment_tool,
                            {digital_wallet, #domain_DigitalWalletCondition{
                                definition = {payment_service_is, ?pmtsrv(<<"webmoney">>)}
                            }}}},
                    ?ruleset(?PAYINST2_ROUTING_POLICIES + 1)
                ),
                delegate(
                    {condition,
                        {payment_tool,
                            {bank_card, #domain_BankCardCondition{
                                definition = {issuer_country_is, 'rus'}
                            }}}},
                    ?ruleset(?PAYINST2_ROUTING_POLICIES + 1)
                )
            ]}
        ),

        routing_ruleset(
            ?ruleset(?PAYINST2_ROUTING_POLICIES + 1),
            <<"PayInst2 Withdrawal Ruleset #1">>,
            {candidates, [
                candidate(
                    condition(cost_in, {0, 1000000, <<"RUB">>}),
                    ?trm(301)
                ),
                candidate(
                    condition(cost_in, {3000000, 10000000, <<"RUB">>}),
                    ?trm(307)
                )
            ]}
        ),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?payinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Generic Payment Institution">>,
                system_account_set = {value, ?sas(1)},
                withdrawal_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(?PAYINST1_ROUTING_POLICIES),
                    prohibitions = ?ruleset(?PAYINST1_ROUTING_PROHIBITIONS)
                },
                inspector = {value, ?insp(1)},
                residences = ['rus'],
                realm = live,
                wallet_system_account_set = {value, ?sas(1)},
                payment_system =
                    {decisions, [
                        #domain_PaymentSystemDecision{
                            if_ =
                                {any_of,
                                    ordsets:from_list([
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"VISA">>},
                                                bank_name = {equals, <<"uber">>}
                                            }}},
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"VISA">>},
                                                bank_name = {equals, <<"sber">>}
                                            }}}
                                    ])},
                            then_ = {value, ?pmtsys(<<"VISA">>)}
                        },
                        #domain_PaymentSystemDecision{
                            if_ =
                                {any_of,
                                    ordsets:from_list([
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"NSPK MIR">>},
                                                bank_name = {equals, <<"poopa">>}
                                            }}}
                                    ])},
                            then_ = {value, ?pmtsys(<<"NSPK MIR">>)}
                        }
                    ]}
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?payinst(2),
            data = #domain_PaymentInstitution{
                name = <<"Generic Payment Institution">>,
                system_account_set = {value, ?sas(1)},
                inspector = {value, ?insp(1)},
                residences = ['rus'],
                realm = live,
                wallet_system_account_set = {value, ?sas(1)},
                withdrawal_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(?PAYINST2_ROUTING_POLICIES),
                    prohibitions = ?ruleset(?EMPTY_ROUTING_RULESET)
                },
                payment_system =
                    {decisions, [
                        #domain_PaymentSystemDecision{
                            if_ =
                                {any_of,
                                    ordsets:from_list([
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"VISA">>},
                                                bank_name = {equals, <<"uber">>}
                                            }}},
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"VISA">>},
                                                bank_name = {equals, <<"sber">>}
                                            }}}
                                    ])},
                            then_ = {value, ?pmtsys(<<"VISA">>)}
                        },
                        #domain_PaymentSystemDecision{
                            if_ =
                                {any_of,
                                    ordsets:from_list([
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"NSPK MIR">>},
                                                bank_name = {equals, <<"poopa">>}
                                            }}}
                                    ])},
                            then_ = {value, ?pmtsys(<<"NSPK MIR">>)}
                        }
                    ]}
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?payinst(3),
            data = #domain_PaymentInstitution{
                name = <<"Generic Payment Institution">>,
                system_account_set = {value, ?sas(1)},
                inspector = {value, ?insp(1)},
                residences = ['rus'],
                realm = test,
                wallet_system_account_set = {value, ?sas(1)},
                withdrawal_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(?PAYINST2_ROUTING_POLICIES),
                    prohibitions = ?ruleset(?EMPTY_ROUTING_RULESET)
                },
                payment_system =
                    {decisions, [
                        #domain_PaymentSystemDecision{
                            if_ =
                                {any_of,
                                    ordsets:from_list([
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"VISA">>},
                                                bank_name = {equals, <<"uber">>}
                                            }}},
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"VISA">>},
                                                bank_name = {equals, <<"sber">>}
                                            }}}
                                    ])},
                            then_ = {value, ?pmtsys(<<"VISA">>)}
                        },
                        #domain_PaymentSystemDecision{
                            if_ =
                                {any_of,
                                    ordsets:from_list([
                                        {condition,
                                            {bin_data, #domain_BinDataCondition{
                                                payment_system = {equals, <<"NSPK MIR">>},
                                                bank_name = {equals, <<"poopa">>}
                                            }}}
                                    ])},
                            then_ = {value, ?pmtsys(<<"NSPK MIR">>)}
                        }
                    ]}
            }
        }},

        ct_domain:system_account_set(?sas(1), <<"System">>, ?cur(<<"RUB">>)),

        ct_domain:inspector(?insp(1), <<"Low Life">>, ?prx(1), #{<<"risk_score">> => <<"low">>}),
        ct_domain:proxy(?prx(1), <<"Inspector proxy">>),
        ct_domain:proxy(?prx(2), <<"Mocket proxy">>, <<"http://localhost:8222/bank">>),
        ct_domain:proxy(?prx(3), <<"Quote proxy">>, <<"http://localhost:8222/quotebank">>),
        ct_domain:proxy(?prx(6), <<"Down proxy">>, <<"http://localhost:8222/downbank">>),
        ct_domain:proxy(?prx(7), <<"Another down proxy">>, <<"http://localhost:8222/downbank2">>),
        ct_domain:proxy(?prx(8), <<"Sleep proxy">>, <<"http://localhost:8222/sleepybank">>),

        ct_domain:withdrawal_provider(?prv(1), ?prx(2), live, TempProviderTermSet),
        ct_domain:withdrawal_provider(?prv(2), ?prx(2), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(3), ?prx(3), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(4), ?prx(6), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(5), ?prx(2), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(6), ?prx(6), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(7), ?prx(6), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(8), ?prx(2), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(9), ?prx(7), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(10), ?prx(6), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(11), ?prx(8), live, ProviderTermSet),
        ct_domain:withdrawal_provider(?prv(16), ?prx(2), live, undefined),
        ct_domain:withdrawal_provider(?prv(17), ?prx(2), live, ProviderTermSet),

        ct_domain:term_set_hierarchy(?trms(1), default_termset(Options)),
        ct_domain:term_set_hierarchy(?trms(2), company_termset(Options)),

        ct_domain:withdrawal_terminal(?trm(1), ?prv(1)),
        ct_domain:withdrawal_terminal(?trm(2), ?prv(1)),
        ct_domain:withdrawal_terminal(?trm(3), ?prv(1)),
        ct_domain:withdrawal_terminal(?trm(4), ?prv(1)),
        ct_domain:withdrawal_terminal(?trm(5), ?prv(1)),

        ct_domain:withdrawal_terminal(?trm(6), ?prv(16)),

        ct_domain:withdrawal_terminal(?trm(201), ?prv(2)),

        ct_domain:withdrawal_terminal(?trm(301), ?prv(3)),
        ct_domain:withdrawal_terminal(
            ?trm(307),
            ?prv(3),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        currencies = {value, ?ordset([?cur(<<"BTC">>)])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000000, <<"BTC">>)},
                                    {exclusive, ?cash(10000000, <<"BTC">>)}
                                )},
                        cash_flow = {value, ?ordset([])}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(?trm(401), ?prv(4)),
        ct_domain:withdrawal_terminal(?trm(501), ?prv(5)),
        ct_domain:withdrawal_terminal(?trm(601), ?prv(6)),
        ct_domain:withdrawal_terminal(?trm(701), ?prv(7)),
        ct_domain:withdrawal_terminal(?trm(801), ?prv(8)),
        ct_domain:withdrawal_terminal(?trm(901), ?prv(9)),
        ct_domain:withdrawal_terminal(?trm(1001), ?prv(10)),
        ct_domain:withdrawal_terminal(?trm(1101), ?prv(11)),

        ct_domain:withdrawal_terminal(?trm(1701), ?prv(17)),
        ct_domain:withdrawal_terminal(
            ?trm(1708),
            ?prv(17),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        cash_flow =
                            {decisions, [
                                #domain_CashFlowDecision{
                                    if_ = {constant, true},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?fixed(16, <<"RUB">>)
                                            )
                                        ]}
                                }
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(1800),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        currencies = {value, ?ordset([?cur(<<"RUB">>), ?cur(<<"BTC">>)])},
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_NUM_PAYTOOL_ID1, 1000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(1900),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_NUM_PAYTOOL_ID2, 0, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2000),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_NUM_PAYTOOL_ID2, 1000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2100),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1, 1804000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2200),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, 903000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2300),
            ?prv(4),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, 2000000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2400),
            ?prv(5),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, 3000000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2500),
            ?prv(4),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID3, 2000000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2600),
            ?prv(5),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID4, 3000000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2700),
            ?prv(5),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID3, 4000000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(2800),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        currencies = {value, ?ordset([?cur(<<"RUB">>), ?cur(<<"BTC">>)])},
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_NUM_SENDER_ID1, 1000, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(3000),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        allow = {constant, true}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(3100),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        allow = {constant, false},
                        turnover_limit =
                            {value, [
                                ?trnvrlimit(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2, 123123, Config)
                            ]}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(3200),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        allow = {condition, {category_is, ?cat(1)}}
                    }
                }
            }
        ),

        ct_domain:withdrawal_terminal(
            ?trm(3300),
            ?prv(1),
            #domain_ProvisionTermSet{
                wallet = #domain_WalletProvisionTerms{
                    withdrawals = #domain_WithdrawalProvisionTerms{
                        global_allow = {constant, false}
                    }
                }
            }
        ),

        ct_domain:currency(?cur(<<"RUB">>)),
        ct_domain:currency(?cur(<<"USD">>)),
        ct_domain:currency(?cur(<<"EUR">>)),
        ct_domain:currency(?cur(<<"BTC">>)),

        ct_domain:category(?cat(1), <<"Generic Store">>, live),

        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_BANK_CARD(<<"VISA">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_BANK_CARD(<<"MASTERCARD">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_BANK_CARD_WITH_EMPTY_CVV(<<"MASTERCARD">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_BANK_CARD(<<"NSPK MIR">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_GENERIC(<<"IND">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_DIGITAL_WALLET(<<"webmoney">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_CRYPTO_CURRENCY(<<"Litecoin">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_CRYPTO_CURRENCY(<<"bitcoin_cash">>))),
        ct_domain:payment_method(?pmt(?PAYMENT_METHOD_CRYPTO_CURRENCY(<<"ripple">>))),

        ct_domain:payment_system(?pmtsys(<<"MASTERCARD">>), <<"MASTERCARD">>),
        ct_domain:payment_system(?pmtsys(<<"VISA">>), <<"VISA">>),
        ct_domain:payment_system(?pmtsys(<<"NSPK MIR">>), <<"NSPK MIR">>),

        ct_domain:payment_service(?pmtsrv(<<"webmoney">>), <<"Webmoney">>),
        ct_domain:payment_service(?pmtsrv(<<"qiwi">>), <<"Qiwi">>),
        ct_domain:payment_service(?pmtsrv(<<"IND">>), <<"INDbank">>),
        ct_domain:crypto_currency(?crptcur(<<"Litecoin">>), <<"Litecoin">>),
        ct_domain:crypto_currency(?crptcur(<<"bitcoin_cash">>), <<"bitcoin_cash">>),
        ct_domain:crypto_currency(?crptcur(<<"ripple">>), <<"ripple">>)
    ],
    maps:get(domain_config, Options, Default).

default_termset(Options) ->
    Default = #domain_TermSet{
        wallets = #domain_WalletServiceTerms{
            currencies = {value, ?ordset([?cur(<<"RUB">>), ?cur(<<"USD">>)])},
            wallet_limit =
                {decisions, [
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"RUB">>)},
                                    {exclusive, ?cash(5000001, <<"RUB">>)}
                                )}
                    },
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"USD">>)},
                                    {exclusive, ?cash(10000001, <<"USD">>)}
                                )}
                    }
                ]},
            withdrawals = #domain_WithdrawalServiceTerms{
                currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                attempt_limit = {value, #domain_AttemptLimit{attempts = 3}},
                cash_limit =
                    {decisions, [
                        #domain_CashLimitDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {value,
                                    ?cashrng(
                                        {inclusive, ?cash(0, <<"RUB">>)},
                                        {exclusive, ?cash(10000001, <<"RUB">>)}
                                    )}
                        },
                        #domain_CashLimitDecision{
                            if_ = {condition, {currency_is, ?cur(<<"EUR">>)}},
                            then_ =
                                {value,
                                    ?cashrng(
                                        {inclusive, ?cash(0, <<"EUR">>)},
                                        {exclusive, ?cash(10000001, <<"EUR">>)}
                                    )}
                        },
                        #domain_CashLimitDecision{
                            if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                            then_ =
                                {value,
                                    ?cashrng(
                                        {inclusive, ?cash(0, <<"USD">>)},
                                        {exclusive, ?cash(10000001, <<"USD">>)}
                                    )}
                        }
                    ]},
                methods =
                    {value,
                        ?ordset([
                            ?pmt(?PAYMENT_METHOD_BANK_CARD(<<"MASTERCARD">>)),
                            ?pmt(?PAYMENT_METHOD_BANK_CARD_WITH_EMPTY_CVV(<<"MASTERCARD">>)),
                            ?pmt(?PAYMENT_METHOD_BANK_CARD(<<"VISA">>)),
                            ?pmt(?PAYMENT_METHOD_BANK_CARD(<<"NSPK MIR">>)),
                            ?pmt(?PAYMENT_METHOD_GENERIC(<<"IND">>)),
                            ?pmt(?PAYMENT_METHOD_DIGITAL_WALLET(<<"webmoney">>)),
                            ?pmt(?PAYMENT_METHOD_CRYPTO_CURRENCY(<<"Litecoin">>)),
                            ?pmt(?PAYMENT_METHOD_CRYPTO_CURRENCY(<<"bitcoin_cash">>)),
                            ?pmt(?PAYMENT_METHOD_CRYPTO_CURRENCY(<<"ripple">>))
                        ])},
                cash_flow =
                    {decisions, [
                        % this is impossible cash flow decision to check
                        % if withdrawals cash flow calculates properly
                        #domain_CashFlowDecision{
                            if_ = {
                                condition,
                                {payment_tool, {payment_terminal, #domain_PaymentTerminalCondition{}}}
                            },
                            then_ = {value, []}
                        },
                        #domain_CashFlowDecision{
                            if_ =
                                {any_of,
                                    ?ordset([
                                        {all_of,
                                            ?ordset([
                                                {condition, {currency_is, ?cur(<<"RUB">>)}},
                                                {condition,
                                                    {payment_tool,
                                                        {bank_card, #domain_BankCardCondition{
                                                            definition =
                                                                {payment_system, #domain_PaymentSystemCondition{
                                                                    payment_system_is = #domain_PaymentSystemRef{
                                                                        id = <<"VISA">>
                                                                    }
                                                                }}
                                                        }}}}
                                            ])},
                                        {all_of,
                                            ?ordset([
                                                condition(cost_in, {424242, <<"RUB">>})
                                            ])}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        },
                        #domain_CashFlowDecision{
                            if_ =
                                {all_of,
                                    ?ordset([
                                        {condition, {currency_is, ?cur(<<"EUR">>)}},
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = #domain_PaymentSystemRef{
                                                                id = <<"VISA">>
                                                            }
                                                        }}
                                                }}}}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        },
                        #domain_CashFlowDecision{
                            if_ =
                                {all_of,
                                    ?ordset([
                                        {condition, {currency_is, ?cur(<<"USD">>)}},
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = #domain_PaymentSystemRef{
                                                                id = <<"VISA">>
                                                            }
                                                        }}
                                                }}}}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        },
                        #domain_CashFlowDecision{
                            if_ =
                                {all_of,
                                    ?ordset([
                                        {condition, {currency_is, ?cur(<<"RUB">>)}},
                                        {condition,
                                            {payment_tool, {crypto_currency, #domain_CryptoCurrencyCondition{}}}}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        },
                        #domain_CashFlowDecision{
                            if_ =
                                {all_of,
                                    ?ordset([
                                        {condition, {currency_is, ?cur(<<"RUB">>)}},
                                        {condition, {payment_tool, {digital_wallet, #domain_DigitalWalletCondition{}}}}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        },
                        #domain_CashFlowDecision{
                            if_ =
                                {all_of,
                                    ?ordset([
                                        {condition, {currency_is, ?cur(<<"RUB">>)}},
                                        {condition,
                                            {payment_tool,
                                                {generic,
                                                    {payment_service_is, #domain_PaymentServiceRef{
                                                        id = <<"IND">>
                                                    }}}}}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        },
                        #domain_CashFlowDecision{
                            if_ =
                                {all_of,
                                    ?ordset([
                                        {condition, {currency_is, ?cur(<<"RUB">>)}},
                                        {condition,
                                            {payment_tool,
                                                {generic,
                                                    {payment_service_is, #domain_PaymentServiceRef{
                                                        id = <<"qiwi">>
                                                    }}}}}
                                    ])},
                            then_ =
                                {value, [
                                    ?cfpost(
                                        {wallet, sender_settlement},
                                        {wallet, receiver_destination},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, settlement},
                                        ?share(10, 100, operation_amount)
                                    ),
                                    ?cfpost(
                                        {wallet, receiver_destination},
                                        {system, subagent},
                                        ?share(10, 100, operation_amount)
                                    )
                                ]}
                        }
                    ]}
            }
        }
    },
    maps:get(default_termset, Options, Default).

company_termset(Options) ->
    Default = #domain_TermSet{
        wallets = #domain_WalletServiceTerms{
            currencies = {value, ?ordset([?cur(<<"RUB">>), ?cur(<<"USD">>)])},
            wallet_limit =
                {decisions, [
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"RUB">>)},
                                    {exclusive, ?cash(5000000, <<"RUB">>)}
                                )}
                    },
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"USD">>)},
                                    {exclusive, ?cash(5000000, <<"USD">>)}
                                )}
                    }
                ]}
        }
    },
    maps:get(company_termset, Options, Default).

routing_ruleset(?ruleset(ID) = Ref, Decisions) ->
    routing_ruleset(Ref, genlib:format("Withdrawal Ruleset #~B", [ID]), Decisions).

routing_ruleset(Ref, Name, Decisions) ->
    {routing_rules, #domain_RoutingRulesObject{
        ref = Ref,
        data = #domain_RoutingRuleset{
            name = Name,
            decisions = Decisions
        }
    }}.

condition(cost_in, {CostExact, Currency}) ->
    {condition,
        {cost_in,
            ?cashrng(
                {inclusive, ?cash(CostExact, Currency)},
                {inclusive, ?cash(CostExact, Currency)}
            )}};
condition(cost_in, {Min, Max, Currency}) ->
    {condition,
        {cost_in,
            ?cashrng(
                {inclusive, ?cash(Min, Currency)},
                {exclusive, ?cash(Max, Currency)}
            )}};
condition(party, ID) ->
    {condition, {party, #domain_PartyCondition{party_ref = #domain_PartyConfigRef{id = ID}}}}.

delegate(Allowed, RuleSetRef) ->
    #domain_RoutingDelegate{
        allowed = Allowed,
        ruleset = RuleSetRef
    }.

candidate(Allowed, Terminal) ->
    #domain_RoutingCandidate{
        allowed = Allowed,
        terminal = Terminal
    }.

candidate(Allowed, Terminal, Prio) ->
    #domain_RoutingCandidate{
        allowed = Allowed,
        terminal = Terminal,
        priority = Prio
    }.
