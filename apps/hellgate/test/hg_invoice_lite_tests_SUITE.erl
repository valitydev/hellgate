-module(hg_invoice_lite_tests_SUITE).

-include("hg_ct_invoice.hrl").
-include("hg_ct_domain.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([payment_ok_test/1]).
-export([payment_start_idempotency/1]).
-export([payment_success/1]).
-export([payment_w_first_blacklisted_success/1]).
-export([payment_w_all_blacklisted/1]).
-export([register_payment_success/1]).
-export([register_payment_customer_payer_success/1]).
-export([payment_success_additional_info/1]).
-export([payment_w_mobile_commerce/1]).
-export([payment_suspend_timeout_failure/1]).
-export([payment_w_crypto_currency_success/1]).
-export([payment_w_wallet_success/1]).
-export([payment_success_empty_cvv/1]).
-export([payment_has_optional_fields/1]).
-export([payment_last_trx_correct/1]).

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name() :: hg_ct_helper:group_name().
-type test_return() :: _ | no_return().

%% Supervisor
-behaviour(supervisor).

-export([init/1]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

%% Tests
-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        {group, payments}
        % {group, wrap_load}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {wrap_load, [], [
            {group, load}
        ]},
        {load, [{repeat, 10}], [
            {group, pool_payments}
        ]},
        {pool_payments, [parallel], lists:foldl(fun(_, Acc) -> [payment_ok_test | Acc] end, [], lists:seq(1, 100))},
        {payments, [parallel], [
            payment_start_idempotency,
            payment_success,
            payment_w_first_blacklisted_success,
            payment_w_all_blacklisted,
            register_payment_success,
            register_payment_customer_payer_success,
            payment_success_additional_info,
            payment_w_mobile_commerce,
            payment_suspend_timeout_failure,
            payment_w_crypto_currency_success,
            payment_w_wallet_success,
            payment_success_empty_cvv,
            payment_has_optional_fields,
            payment_last_trx_correct
        ]}
    ].

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
        epg_connector,
        progressor,
        hellgate,
        {cowboy, CowboySpec},
        snowflake
    ]),
    RootUrl = maps:get(hellgate_root_url, Ret),
    _ = hg_limiter_helper:init_per_suite(C),
    _ = hg_domain:insert(construct_domain_fixture()),
    PartyID = hg_utils:unique_id(),
    PartyClient = {party_client:create_client(), party_client:create_context()},
    CustomerClient = hg_client_customer:start(hg_ct_helper:create_client(RootUrl)),
    ShopID = hg_ct_helper:create_party_and_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    _ = unlink(SupPid),
    ok = hg_invoice_helper:start_kv_store(SupPid),
    NewC = [
        {party_id, PartyID},
        {shop_id, ShopID},
        {customer_client, CustomerClient},
        {root_url, RootUrl},
        {test_sup, SupPid},
        {apps, Apps}
        | C
    ],
    ok = hg_invoice_helper:start_proxies([{hg_dummy_provider, 1, NewC}, {hg_dummy_inspector, 2, NewC}]),
    NewC.

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = hg_domain:cleanup(),
    _ = application:stop(progressor),
    _ = hg_progressor:cleanup(),
    _ = [application:stop(App) || App <- cfg(apps, C)],
    hg_invoice_helper:stop_kv_store(cfg(test_sup, C)),
    exit(cfg(test_sup, C), shutdown).

-spec init_per_group(group_name(), config()) -> config().
init_per_group(wrap_load, C) ->
    io:format(user, "START LOAD: ~p~n", [calendar:local_time()]),
    C;
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(wrap_load, _C) ->
    io:format(user, "FINISH LOAD: ~p~n", [calendar:local_time()]),
    io:format(user, prometheus_text_format:format(), []),
    ok;
end_per_group(_Group, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(_, C) ->
    ApiClient = hg_ct_helper:create_client(hg_ct_helper:cfg(root_url, C)),
    Client = hg_client_invoicing:start_link(ApiClient),
    ok = hg_context:save(hg_context:create()),
    [
        {client, Client}
        | C
    ].

-spec end_per_testcase(test_case_name(), config()) -> config().
end_per_testcase(_, C) ->
    C.

%% TESTS
-spec payment_ok_test(config()) -> test_return().
payment_ok_test(C) ->
    Client = cfg(client, C),
    %timer:sleep(rand:uniform(30)),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Context = #base_Content{
        type = <<"application/x-erlang-binary">>,
        data = erlang:term_to_binary({you, 643, "not", [<<"welcome">>, here]})
    },
    PayerSessionInfo = #domain_PayerSessionInfo{
        redirect_url = <<"https://redirectly.io/merchant">>
    },
    PaymentParams = (make_payment_params(?pmt_sys(<<"visa-ref">>)))#payproc_InvoicePaymentParams{
        payer_session_info = PayerSessionInfo,
        context = Context
    },
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    try await_payment_capture(InvoiceID, PaymentID, Client) of
        PaymentID -> ok
    catch
        _:_ ->
            io:format(user, "MAYBE FAILED INVOICE: ~p~n", [InvoiceID])
    end,
    #payproc_Invoice{} = hg_client_invoicing:get(InvoiceID, Client),
    ok.

-spec payment_start_idempotency(config()) -> test_return().
payment_start_idempotency(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams0 = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID1 = <<"1">>,
    ExternalID = <<"42">>,
    PaymentParams1 = PaymentParams0#payproc_InvoicePaymentParams{
        id = PaymentID1,
        external_id = ExternalID
    },
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID1,
        external_id = ExternalID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams1, Client),
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID1,
        external_id = ExternalID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams1, Client),
    PaymentParams2 = PaymentParams0#payproc_InvoicePaymentParams{id = <<"2">>},
    %    {exception, #payproc_InvoicePaymentPending{id = PaymentID1}} =
    {exception, _} =
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams2, Client),
    PaymentID1 = execute_payment(InvoiceID, PaymentParams1, Client),
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID1,
        external_id = ExternalID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams1, Client).

-spec payment_success(config()) -> test_return().
payment_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Context = #base_Content{
        type = <<"application/x-erlang-binary">>,
        data = erlang:term_to_binary({you, 643, "not", [<<"welcome">>, here]})
    },
    PayerSessionInfo = #domain_PayerSessionInfo{
        redirect_url = RedirectURL = <<"https://redirectly.io/merchant">>
    },
    PaymentParams = (make_payment_params(?pmt_sys(<<"visa-ref">>)))#payproc_InvoicePaymentParams{
        payer_session_info = PayerSessionInfo,
        context = Context
    },
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
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

-spec payment_w_first_blacklisted_success(config()) -> test_return().
payment_w_first_blacklisted_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(inspector_fail_first, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [_PaymentSt]
    ) = hg_client_invoicing:get(InvoiceID, Client),
    _Explanation =
        #payproc_InvoicePaymentExplanation{
            explained_routes = [
                #payproc_InvoicePaymentRouteExplanation{
                    route = ?route(?prv(1), ?trm(2)),
                    is_chosen = true
                },
                #payproc_InvoicePaymentRouteExplanation{
                    route = ?route(?prv(1), ?trm(1)),
                    is_chosen = false,
                    rejection_description = Desc
                }
            ]
        } = hg_client_invoicing:explain_route(InvoiceID, PaymentID, Client),
    ?assertEqual(
        <<"Route was blacklisted {domain_PaymentRoute,{domain_ProviderRef,1},{domain_TerminalRef,1}}.">>, Desc
    ).

-spec payment_w_all_blacklisted(config()) -> test_return().
payment_w_all_blacklisted(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(inspector_fail_all, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))),
        ?payment_ev(PaymentID, ?shop_limit_initiated()),
        ?payment_ev(PaymentID, ?shop_limit_applied()),
        ?payment_ev(PaymentID, ?risk_score_changed(_RiskScore)),
        ?payment_ev(PaymentID, ?route_changed(_Route)),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, _Failure}))
    ] = next_changes(InvoiceID, 6, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_unpaid()),
        [_PaymentSt]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec register_payment_success(config()) -> test_return().
register_payment_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Context = #base_Content{
        type = <<"application/x-erlang-binary">>,
        data = erlang:term_to_binary({you, 643, "not", [<<"welcome">>, here]})
    },
    PayerSessionInfo = #domain_PayerSessionInfo{},
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    Route = ?route(?prv(1), ?trm(1)),
    Cost = ?cash(41999, <<"RUB">>),
    ID = hg_utils:unique_id(),
    ExternalID = hg_utils:unique_id(),
    TransactionInfo = ?trx_info(<<"1">>, #{}),
    OccurredAt = hg_datetime:format_now(),
    PaymentParams = #payproc_RegisterInvoicePaymentParams{
        payer_params =
            {payment_resource, #payproc_PaymentResourcePayerParams{
                resource = #domain_DisposablePaymentResource{
                    payment_tool = PaymentTool,
                    payment_session_id = Session,
                    client_info = #domain_ClientInfo{}
                },
                contact_info = ?contact_info()
            }},
        route = Route,
        payer_session_info = PayerSessionInfo,
        context = Context,
        cost = Cost,
        id = ID,
        external_id = ExternalID,
        transaction_info = TransactionInfo,
        risk_score = high,
        occurred_at = OccurredAt
    },
    PaymentID = register_payment(InvoiceID, PaymentParams, true, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(?invoice_w_status(?invoice_paid())) =
        hg_client_invoicing:get(InvoiceID, Client),
    PaymentSt = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),

    ?payment_route(Route) = PaymentSt,
    ?payment_last_trx(TransactionInfo) = PaymentSt,
    ?payment_state(Payment) = PaymentSt,
    ?payment_w_status(PaymentID, ?captured()) = Payment,
    ?assertMatch(
        #domain_InvoicePayment{
            id = ID,
            payer_session_info = PayerSessionInfo,
            context = Context,
            flow = ?invoice_payment_flow_instant(),
            cost = Cost,
            external_id = ExternalID
        },
        Payment
    ).

-spec register_payment_customer_payer_success(config()) -> test_return().
register_payment_customer_payer_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Route = ?route(?prv(1), ?trm(1)),
    CustomerID = make_customer_w_rec_tool(
        cfg(party_id, C), cfg(shop_id, C), cfg(customer_client, C), ?pmt_sys(<<"visa-ref">>)
    ),
    PaymentParams = #payproc_RegisterInvoicePaymentParams{
        payer_params =
            {customer, #payproc_CustomerPayerParams{
                customer_id = CustomerID
            }},
        route = Route,
        transaction_info = ?trx_info(<<"1">>, #{})
    },
    PaymentID = register_payment(InvoiceID, PaymentParams, false, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(?invoice_w_status(?invoice_paid())) =
        hg_client_invoicing:get(InvoiceID, Client).

-spec payment_success_additional_info(config()) -> test_return().
payment_success_additional_info(C) ->
    Client = hg_ct_helper:cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(empty_cvv, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(Trx))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded())))
    ] = next_changes(InvoiceID, 2, Client),
    %% Check additional info
    AdditionalInfo = hg_ct_fixture:construct_dummy_additional_info(),
    #domain_TransactionInfo{additional_info = AdditionalInfo} = Trx,

    ?payment_ev(PaymentID, ?payment_status_changed(?processed())) =
        next_change(InvoiceID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_w_mobile_commerce(config()) -> _ | no_return().
payment_w_mobile_commerce(C) ->
    payment_w_mobile_commerce(C, success).

-spec payment_suspend_timeout_failure(config()) -> _ | no_return().
payment_suspend_timeout_failure(C) ->
    payment_w_mobile_commerce(C, failure).

payment_w_mobile_commerce(C, Expectation) ->
    Client = cfg(client, C),
    PayCash = 1001,
    InvoiceID = start_invoice(<<"oatmeal">>, make_due_date(10), PayCash, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool({mobile_commerce, Expectation}, ?mob(<<"mts-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    _ = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    case Expectation of
        success ->
            [
                ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
                ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
            ] =
                next_changes(InvoiceID, 2, Client);
        failure ->
            [
                ?payment_ev(
                    PaymentID,
                    ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))
                ),
                ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
                ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
            ] =
                next_changes(InvoiceID, 3, Client)
    end.

-spec payment_w_crypto_currency_success(config()) -> _ | no_return().
payment_w_crypto_currency_success(C) ->
    Client = cfg(client, C),
    PayCash = 2000,
    InvoiceID = start_invoice(<<"cryptoduck">>, make_due_date(10), PayCash, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID,
        owner_id = PartyID,
        shop_id = ShopID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    {CF, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    CFContext = construct_ta_context(PartyID, ShopID, Route),
    ?cash(PayCash, <<"RUB">>) = get_cashflow_volume({provider, settlement}, {merchant, settlement}, CF, CFContext),
    ?cash(36, <<"RUB">>) = get_cashflow_volume({system, settlement}, {provider, settlement}, CF, CFContext),
    ?cash(90, <<"RUB">>) = get_cashflow_volume({merchant, settlement}, {system, settlement}, CF, CFContext).

-spec payment_w_wallet_success(config()) -> _ | no_return().
payment_w_wallet_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"bubbleblob">>, make_due_date(10), 42000, C),
    PaymentParams = make_wallet_payment_params(?pmt_srv(<<"qiwi-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_success_empty_cvv(config()) -> test_return().
payment_success_empty_cvv(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(empty_cvv, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_has_optional_fields(config()) -> test_return().
payment_has_optional_fields(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    InvoicePayment = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ?payment_state(Payment) = InvoicePayment,
    ?payment_route(Route) = InvoicePayment,
    ?payment_cashflow(CashFlow) = InvoicePayment,
    ?payment_last_trx(TrxInfo) = InvoicePayment,
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    #domain_InvoicePayment{owner_id = PartyID, shop_id = ShopID} = Payment,
    false = Route =:= undefined,
    false = CashFlow =:= undefined,
    false = TrxInfo =:= undefined.

-spec payment_last_trx_correct(config()) -> _ | no_return().
payment_last_trx_correct(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = start_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(TrxInfo0))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?payment_last_trx(TrxInfo0) = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Internals
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

cfg(Key, Config) ->
    hg_ct_helper:cfg(Key, Config).

make_due_date(LifetimeSeconds) ->
    hg_invoice_helper:make_due_date(LifetimeSeconds).

start_invoice(Product, Due, Amount, Client) ->
    hg_invoice_helper:start_invoice(Product, Due, Amount, Client).

make_payment_params(PmtSys) ->
    hg_invoice_helper:make_payment_params(PmtSys).

make_payment_params(PaymentTool, Session, FlowType) ->
    hg_invoice_helper:make_payment_params(PaymentTool, Session, FlowType).

register_payment(InvoiceID, RegisterPaymentParams, WithRiskScoring, Client) ->
    hg_invoice_helper:register_payment(InvoiceID, RegisterPaymentParams, WithRiskScoring, Client).

start_payment(InvoiceID, PaymentParams, Client) ->
    hg_invoice_helper:start_payment(InvoiceID, PaymentParams, Client).

process_payment(InvoiceID, PaymentParams, Client) ->
    hg_invoice_helper:process_payment(InvoiceID, PaymentParams, Client).

await_payment_session_started(InvoiceID, PaymentID, Client, Target) ->
    hg_invoice_helper:await_payment_session_started(InvoiceID, PaymentID, Client, Target).

await_payment_process_finish(InvoiceID, PaymentID, Client) ->
    hg_invoice_helper:await_payment_process_finish(InvoiceID, PaymentID, Client).

next_changes(InvoiceID, Amount, Client) ->
    hg_invoice_helper:next_changes(InvoiceID, Amount, Client).

next_change(InvoiceID, Client) ->
    hg_invoice_helper:next_change(InvoiceID, Client).

await_payment_capture(InvoiceID, PaymentID, Client) ->
    hg_invoice_helper:await_payment_capture(InvoiceID, PaymentID, Client).

await_payment_cash_flow(InvoiceID, PaymentID, Client) ->
    hg_invoice_helper:await_payment_cash_flow(InvoiceID, PaymentID, Client).

construct_ta_context(PartyID, ShopID, Route) ->
    hg_invoice_helper:construct_ta_context(PartyID, ShopID, Route).

get_cashflow_volume(Source, Destination, CF, CFContext) ->
    hg_invoice_helper:get_cashflow_volume(Source, Destination, CF, CFContext).

make_wallet_payment_params(PmtSrv) ->
    hg_invoice_helper:make_wallet_payment_params(PmtSrv).

execute_payment(InvoiceID, PaymentParams, Client) ->
    hg_invoice_helper:execute_payment(InvoiceID, PaymentParams, Client).

make_customer_w_rec_tool(PartyID, ShopID, Client, PmtSys) ->
    hg_invoice_helper:make_customer_w_rec_tool(PartyID, ShopID, Client, PmtSys).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% CONFIG
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-define(merchant_to_system_share_1, ?share(45, 1000, operation_amount)).

-spec construct_domain_fixture() -> _.
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
                        ?cat(1),
                        ?cat(2)
                    ])},
            payment_methods =
                {decisions, [
                    #domain_PaymentMethodDecision{
                        if_ = {constant, true},
                        then_ =
                            {value,
                                ?ordset([
                                    ?pmt(mobile, ?mob(<<"mts-ref">>)),
                                    ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                                    ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
                                    ?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                ])}
                    }
                ]},
            cash_limit =
                {decisions, [
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
            holds = #domain_PaymentHoldsServiceTerms{
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                        ])},
                lifetime =
                    {decisions, [
                        #domain_HoldLifetimeDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ = {value, #domain_HoldLifetime{seconds = 10}}
                        }
                    ]}
            },
            refunds = #domain_PaymentRefundsServiceTerms{
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                        ])},
                fees =
                    {value, [
                        ?cfpost(
                            {merchant, settlement},
                            {system, settlement},
                            ?fixed(100, <<"RUB">>)
                        )
                    ]},
                eligibility_time = {value, #base_TimeSpan{minutes = 1}},
                partial_refunds = #domain_PartialRefundsServiceTerms{
                    cash_limit =
                        {decisions, [
                            #domain_CashLimitDecision{
                                if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                                then_ =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(1000, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        ]}
                }
            },
            allocations = #domain_PaymentAllocationServiceTerms{
                allow = {constant, true}
            },
            attempt_limit = {value, #domain_AttemptLimit{attempts = 1}}
        },
        recurrent_paytools = #domain_RecurrentPaytoolsServiceTerms{
            payment_methods =
                {value,
                    ordsets:from_list([
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                    ])}
        }
    },
    [
        hg_ct_fixture:construct_bank_card_category(
            ?bc_cat(1),
            <<"Bank card category">>,
            <<"Corporative">>,
            [<<"*CORPORAT*">>]
        ),

        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),
        hg_ct_fixture:construct_category(?cat(2), <<"Generic Store">>, live),

        hg_ct_fixture:construct_payment_method(?pmt(mobile, ?mob(<<"mts-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_inspector(?insp(1), <<"Rejector">>, ?prx(2), #{<<"risk_score">> => <<"trusted">>}),

        hg_ct_fixture:construct_contract_template(?tmpl(1), ?trms(1)),

        hg_ct_fixture:construct_system_account_set(?sas(1)),
        hg_ct_fixture:construct_external_account_set(?eas(1)),

        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(1),
            <<"Policies">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(1)),
                ?candidate({constant, true}, ?trm(2))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(3),
            <<"Prohibitions">>,
            {candidates, []}
        ),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                default_contract_template = {value, ?tmpl(1)},
                providers =
                    {value,
                        ?ordset([
                            ?prv(1)
                        ])},
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(1),
                    prohibitions = ?ruleset(3)
                },
                inspector =
                    {decisions, [
                        #domain_InspectorDecision{
                            if_ = {condition, {category_is, ?cat(1)}},
                            then_ = {value, ?insp(1)}
                        },
                        #domain_InspectorDecision{
                            if_ = {condition, {category_is, ?cat(2)}},
                            then_ = {value, ?insp(1)}
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
                    {decisions, [
                        #domain_ExternalAccountSetDecision{
                            if_ = {constant, true},
                            then_ = {value, ?eas(1)}
                        }
                    ]},
                payment_institutions = ?ordset([?pinst(1)])
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
                                    ?cat(1),
                                    ?cat(2)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(mobile, ?mob(<<"mts-ref">>)),
                                    ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                                    ?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(1000000000, <<"RUB">>)}
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
                                    ?share(18, 1000, operation_amount)
                                )
                            ]},
                        holds = #domain_PaymentHoldsProvisionTerms{
                            lifetime =
                                {decisions, [
                                    #domain_HoldLifetimeDecision{
                                        if_ =
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {payment_system, #domain_PaymentSystemCondition{
                                                                payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                            }}
                                                    }}}},
                                        then_ = {value, ?hold_lifetime(12)}
                                    }
                                ]}
                        },
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        },
                        chargebacks = #domain_PaymentChargebackProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]}
                        }
                    },
                    recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                        categories = {value, ?ordset([?cat(1), ?cat(2)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                ])},
                        cash_value = {value, ?cash(1000, <<"RUB">>)}
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
        {terminal, #domain_TerminalObject{
            ref = ?trm(2),
            data = #domain_Terminal{
                name = <<"Brominal 2">>,
                description = <<"Brominal 2">>,
                provider_ref = ?prv(1)
            }
        }},

        hg_ct_fixture:construct_mobile_operator(?mob(<<"mts-ref">>), <<"mts mobile operator">>),
        hg_ct_fixture:construct_payment_service(?pmt_srv(<<"qiwi-ref">>), <<"qiwi payment service">>),
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"visa-ref">>), <<"visa payment system">>),
        hg_ct_fixture:construct_crypto_currency(?crypta(<<"bitcoin-ref">>), <<"bitcoin currency">>)
    ].
