%% TODO
%%%  - Do not share state between test cases
%%%  - Run cases in parallel

-module(hg_invoice_parallel_tests_SUITE).

-include("hg_ct_domain.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("hellgate/include/allocation.hrl").

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([payment_success/1]).
-export([payment_success_empty_cvv/1]).
-export([payment_success_additional_info/1]).
-export([payment_w_crypto_currency_success/1]).
-export([payment_w_wallet_success/1]).
-export([payment_w_mobile_commerce/1]).

%%

-behaviour(supervisor).

-export([init/1]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

%% tests descriptions

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name() :: hg_ct_helper:group_name().
-type test_return() :: _ | no_return().

-define(PARTY_ID_WITH_LIMIT, <<"bIg merch limit">>).
-define(PARTY_ID_WITH_SEVERAL_LIMITS, <<"bIg merch limit cascading">>).
-define(PARTYID_EXTERNAL, <<"DUBTV">>).
-define(LIMIT_ID, <<"ID">>).
-define(LIMIT_ID2, <<"ID2">>).
-define(LIMIT_ID3, <<"ID3">>).
-define(LIMIT_UPPER_BOUNDARY, 100000).

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        {group, all_non_destructive_tests}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {all_non_destructive_tests, [], [
            {group, base_payments}
        ]},

        {base_payments, [parallel], [
            payment_success,
            payment_success_empty_cvv,
            payment_success_additional_info,
            payment_w_crypto_currency_success,
            payment_w_wallet_success,
            payment_w_mobile_commerce
        ]}
    ].

%% starting/stopping

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    CowboySpec = hg_dummy_provider:get_http_cowboy_spec(),

    {Apps, Ret} = hg_ct_helper:start_apps([
        woody,
        scoper,
        dmt_client,
        bender_client,
        party_client,
        hg_proto,
        hellgate,
        snowflake,
        {cowboy, CowboySpec}
    ]),

    _ = hg_domain:insert(construct_domain_fixture()),
    RootUrl = maps:get(hellgate_root_url, Ret),

    PartyID = hg_utils:unique_id(),
    PartyClient = {party_client:create_client(), party_client:create_context()},
    ShopID = hg_ct_helper:create_party_and_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),

    {ok, SupPid} = hg_mock_helper:start_sup(),
    _ = unlink(SupPid),
    NewC = [
        {party_id, PartyID},
        {shop_id, ShopID},
        {root_url, RootUrl},
        {apps, Apps},
        {test_sup, SupPid}
        | C
    ],

    ok = hg_invoice_tests_utils:start_proxies([{hg_dummy_provider, 1, NewC}, {hg_dummy_inspector, 2, NewC}]),
    NewC.

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = hg_domain:cleanup(),
    _ = [application:stop(App) || App <- cfg(apps, C)],
    exit(cfg(test_sup, C), shutdown).

%% tests

-include("invoice_events.hrl").
-include("payment_events.hrl").
-include("customer_events.hrl").

-define(invoice(ID), #domain_Invoice{id = ID}).
-define(payment(ID), #domain_InvoicePayment{id = ID}).
-define(payment(ID, Revision), #domain_InvoicePayment{id = ID, party_revision = Revision}).
-define(adjustment(ID), #domain_InvoicePaymentAdjustment{id = ID}).
-define(adjustment(ID, Status), #domain_InvoicePaymentAdjustment{id = ID, status = Status}).
-define(adjustment_revision(Revision), #domain_InvoicePaymentAdjustment{party_revision = Revision}).
-define(adjustment_reason(Reason), #domain_InvoicePaymentAdjustment{reason = Reason}).
-define(invoice_state(Invoice), #payproc_Invoice{invoice = Invoice}).
-define(invoice_state(Invoice, Payments), #payproc_Invoice{invoice = Invoice, payments = Payments}).
-define(payment_state(Payment), #payproc_InvoicePayment{payment = Payment}).
-define(payment_state(Payment, Refunds), #payproc_InvoicePayment{payment = Payment, refunds = Refunds}).
-define(payment_route(Route), #payproc_InvoicePayment{route = Route}).
-define(refund_state(Refund), #payproc_InvoicePaymentRefund{refund = Refund}).
-define(payment_cashflow(CashFlow), #payproc_InvoicePayment{cash_flow = CashFlow}).
-define(payment_last_trx(Trx), #payproc_InvoicePayment{last_transaction_info = Trx}).
-define(invoice_w_status(Status), #domain_Invoice{status = Status}).
-define(invoice_w_revision(Revision), #domain_Invoice{party_revision = Revision}).
-define(payment_w_status(Status), #domain_InvoicePayment{status = Status}).
-define(payment_w_status(ID, Status), #domain_InvoicePayment{id = ID, status = Status}).
-define(invoice_payment_refund(Cash, Status), #domain_InvoicePaymentRefund{cash = Cash, status = Status}).
-define(trx_info(ID), #domain_TransactionInfo{id = ID}).
-define(trx_info(ID, Extra), #domain_TransactionInfo{id = ID, extra = Extra}).
-define(refund_id(RefundID), #domain_InvoicePaymentRefund{id = RefundID}).
-define(refund_id(RefundID, ExternalID), #domain_InvoicePaymentRefund{id = RefundID, external_id = ExternalID}).

-define(CB_PROVIDER_LEVY, 50).
-define(merchant_to_system_share_1, ?share(45, 1000, operation_amount)).
-define(merchant_to_system_share_2, ?share(100, 1000, operation_amount)).
-define(merchant_to_system_share_3, ?share(40, 1000, operation_amount)).

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_Name, C) ->
    init_per_testcase(C).

init_per_testcase(C) ->
    ApiClient = hg_ct_helper:create_client(cfg(root_url, C)),
    Client = hg_client_invoicing:start_link(ApiClient),
    ClientTpl = hg_client_invoice_templating:start_link(ApiClient),
    ok = hg_context:save(hg_context:create()),
    [{client, Client}, {client_tpl, ClientTpl} | C].

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, _C) ->
    ok = hg_context:cleanup(),
    ok.

-spec payment_success(config()) -> test_return().
payment_success(C) ->
    Client = cfg(client, C),
    InvoiceID = hg_invoice_tests_utils:start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Context = #base_Content{
        type = <<"application/x-erlang-binary">>,
        data = erlang:term_to_binary({you, 643, "not", [<<"welcome">>, here]})
    },
    PayerSessionInfo = #domain_PayerSessionInfo{
        redirect_url = RedirectURL = <<"https://redirectly.io/merchant">>
    },
    PaymentParams = (hg_invoice_tests_utils:make_payment_params(?pmt_sys(<<"visa-ref">>)))#payproc_InvoicePaymentParams{
        payer_session_info = PayerSessionInfo,
        context = Context
    },
    PaymentID = hg_invoice_tests_utils:process_payment(InvoiceID, PaymentParams, Client),
    PaymentID = hg_invoice_tests_utils:await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [PaymentSt = ?payment_state(Payment)]
    ) = hg_client_invoicing:get(InvoiceID, Client),
    ?payment_w_status(PaymentID, ?captured()) = Payment,
    ?payment_last_trx(Trx) = PaymentSt,
    ?assertMatch(
        #domain_InvoicePayment{
            payer_session_info = PayerSessionInfo,
            context = Context
        },
        Payment
    ),
    ?assertMatch(
        #domain_TransactionInfo{
            extra = #{
                <<"payment.payer_session_info.redirect_url">> := RedirectURL
            }
        },
        Trx
    ).

-spec payment_success_empty_cvv(config()) -> test_return().
payment_success_empty_cvv(C) ->
    Client = cfg(client, C),
    InvoiceID = hg_invoice_tests_utils:start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(empty_cvv, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = hg_invoice_tests_utils:make_payment_params(PaymentTool, Session, instant),
    PaymentID = hg_invoice_tests_utils:execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).
%%
-spec payment_success_additional_info(config()) -> test_return().
payment_success_additional_info(C) ->
    Client = cfg(client, C),
    InvoiceID = hg_invoice_tests_utils:start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(empty_cvv, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = hg_invoice_tests_utils:make_payment_params(PaymentTool, Session, instant),
    PaymentID = hg_invoice_tests_utils:start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = hg_invoice_tests_utils:await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(Trx))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded())))
    ] = hg_invoice_tests_utils:next_event(InvoiceID, Client),
    #domain_TransactionInfo{additional_info = AdditionalInfo} = Trx,
    AdditionalInfo = hg_ct_fixture:construct_dummy_additional_info(),
    [
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = hg_invoice_tests_utils:next_event(InvoiceID, Client),

    PaymentID = hg_invoice_tests_utils:await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_w_crypto_currency_success(config()) -> _ | no_return().
payment_w_crypto_currency_success(C) ->
    Client = cfg(client, C),
    PayCash = 2000,
    InvoiceID = hg_invoice_tests_utils:start_invoice(<<"cryptoduck">>, make_due_date(10), PayCash, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
    PaymentParams = hg_invoice_tests_utils:make_payment_params(PaymentTool, Session, instant),
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID,
        owner_id = PartyID,
        shop_id = ShopID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending())))
    ] = hg_invoice_tests_utils:next_event(InvoiceID, Client),
    {CF, Route} = hg_invoice_tests_utils:await_payment_cash_flow(InvoiceID, PaymentID, Client),
    CFContext = hg_invoice_tests_utils:construct_ta_context(PartyID, ShopID, Route),
    ?cash(PayCash, <<"RUB">>) = hg_invoice_tests_utils:get_cashflow_volume(
        {provider, settlement}, {merchant, settlement}, CF, CFContext
    ),
    ?cash(40, <<"RUB">>) = hg_invoice_tests_utils:get_cashflow_volume(
        {system, settlement}, {provider, settlement}, CF, CFContext
    ),
    ?cash(90, <<"RUB">>) = hg_invoice_tests_utils:get_cashflow_volume(
        {merchant, settlement}, {system, settlement}, CF, CFContext
    ).

-spec payment_w_mobile_commerce(config()) -> _ | no_return().
payment_w_mobile_commerce(C) ->
    Client = cfg(client, C),
    PayCash = 1001,
    InvoiceID = hg_invoice_tests_utils:start_invoice(<<"oatmeal">>, make_due_date(10), PayCash, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool({mobile_commerce, success}, ?mob(<<"mts-ref">>)),
    PaymentParams = hg_invoice_tests_utils:make_payment_params(PaymentTool, Session, instant),
    hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending())))
    ] = hg_invoice_tests_utils:next_event(InvoiceID, Client),
    _ = hg_invoice_tests_utils:await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = hg_invoice_tests_utils:await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded())))
    ] = hg_invoice_tests_utils:next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = hg_invoice_tests_utils:next_event(InvoiceID, Client).
%%
-spec payment_w_wallet_success(config()) -> _ | no_return().
payment_w_wallet_success(C) ->
    Client = cfg(client, C),
    InvoiceID = hg_invoice_tests_utils:start_invoice(<<"bubbleblob">>, make_due_date(10), 42000, C),
    PaymentParams = hg_invoice_tests_utils:make_wallet_payment_params(?pmt_srv(<<"qiwi-ref">>)),
    PaymentID = hg_invoice_tests_utils:execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

make_due_date(LifetimeSeconds) ->
    genlib_time:unow() + LifetimeSeconds.

-spec construct_domain_fixture() -> [hg_domain:object()].
construct_domain_fixture() ->
    TestTermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies =
                {value,
                    ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
            categories =
                {value,
                    ?ordset([
                        ?cat(1)
                    ])},
            payment_methods =
                {value,
                    ?ordset([
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                        ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>)),
                        ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                        ?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>)),
                        ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
                        ?pmt(mobile, ?mob(<<"mts-ref">>))
                    ])},
            cash_limit =
                {decisions, [
                    #domain_CashLimitDecision{
                        if_ =
                            {condition,
                                {payment_tool,
                                    {crypto_currency, #domain_CryptoCurrencyCondition{
                                        definition = {crypto_currency_is, ?crypta(<<"bitcoin-ref">>)}
                                    }}}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(10, <<"RUB">>)},
                                    {inclusive, ?cash(4200000000, <<"RUB">>)}
                                )}
                    },
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(10, <<"RUB">>)},
                                    {exclusive, ?cash(420000000, <<"RUB">>)}
                                )}
                    }
                ]},
            fees =
                {decisions, [
                    #domain_CashFlowDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value, [
                                ?cfpost(
                                    {merchant, settlement},
                                    {system, settlement},
                                    ?merchant_to_system_share_1
                                )
                            ]}
                    }
                ]},
            allocations = #domain_PaymentAllocationServiceTerms{
                allow = {constant, true}
            }
        }
    },
    [
        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),

        hg_ct_fixture:construct_payment_method(?pmt(mobile, ?mob(<<"mts-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_inspector(?insp(1), <<"Rejector">>, ?prx(2), #{<<"risk_score">> => <<"low">>}),
        hg_ct_fixture:construct_inspector(?insp(2), <<"Skipper">>, ?prx(2), #{<<"risk_score">> => <<"high">>}),
        hg_ct_fixture:construct_inspector(?insp(3), <<"Fatalist">>, ?prx(2), #{<<"risk_score">> => <<"fatal">>}),

        hg_ct_fixture:construct_contract_template(?tmpl(1), ?trms(1)),

        hg_ct_fixture:construct_system_account_set(?sas(1)),

        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(1),
            <<"SubMain">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(1)),
                ?candidate({constant, true}, ?trm(11))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(2),
            <<"Main">>,
            {delegates, [
                ?delegate(<<"Common">>, {constant, true}, ?ruleset(1))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(?ruleset(3), <<"Prohibitions">>, {candidates, []}),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                default_contract_template = {value, ?tmpl(1)},
                providers =
                    {value,
                        ?ordset([
                            ?prv(1),
                            ?prv(4)
                        ])},
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(3)
                },
                inspector =
                    {decisions, [
                        #domain_InspectorDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {decisions, [
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(0, <<"RUB">>)},
                                                        {exclusive, ?cash(500000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(1)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(500000, <<"RUB">>)},
                                                        {exclusive, ?cash(100000000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(2)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(100000000, <<"RUB">>)},
                                                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(3)}
                                    }
                                ]}
                        }
                    ]},
                residences = [],
                realm = test
            }
        }},

        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set =
                    {decisions, []},
                payment_institutions = ?ordset([
                    ?pinst(1)
                ])
            }
        }},

        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = TestTermSet
                    }
                ]
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"brovider">>
                    }
                },
                abs_account = <<"1234567890">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                    %%                                    ?cat(2)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>)),
                                    ?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>)),
                                    ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(1000000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {decisions, [
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {digital_wallet, #domain_DigitalWalletCondition{
                                                    definition = {payment_service_is, ?pmt_srv(<<"qiwi-ref">>)}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(18, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(18, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"mastercard-ref">>)
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(19, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {crypto_currency, #domain_CryptoCurrencyCondition{
                                                    definition = {crypto_currency_is, ?crypta(<<"bitcoin-ref">>)}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(20, 1000, operation_amount)
                                            )
                                        ]}
                                }
                            ]}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(1),
            data = #domain_Terminal{
                name = <<"Brominal 1">>,
                description = <<"Brominal 1">>,
                provider_ref = ?prv(1)
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(4),
            data = #domain_Provider{
                name = <<"UnionTelecom">>,
                description = <<"Mobile commerce terminal provider">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"Union Telecom">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(mobile, ?mob(<<"mts-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(10000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(21, 1000, operation_amount)
                                )
                            ]}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(11),
            data = #domain_Terminal{
                name = <<"Parking Payment Terminal">>,
                description = <<"Mts">>,
                provider_ref = #domain_ProviderRef{id = 4},
                options = #{
                    <<"goodPhone">> => <<"7891">>,
                    <<"prefix">> => <<"1234567890">>
                }
            }
        }},

        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"visa-ref">>), <<"visa payment system">>),
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"mastercard-ref">>), <<"mastercard payment system">>),
        hg_ct_fixture:construct_mobile_operator(?mob(<<"mts-ref">>), <<"mts mobile operator">>),
        hg_ct_fixture:construct_payment_service(?pmt_srv(<<"qiwi-ref">>), <<"qiwi payment service">>),
        hg_ct_fixture:construct_crypto_currency(?crypta(<<"bitcoin-ref">>), <<"bitcoin currency">>)
    ].
