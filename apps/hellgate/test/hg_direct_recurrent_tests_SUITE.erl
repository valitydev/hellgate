-module(hg_direct_recurrent_tests_SUITE).

-include("hg_ct_domain.hrl").
-include("hg_ct_json.hrl").
-include("hg_ct_invoice.hrl").

-include("invoice_events.hrl").
-include("payment_events.hrl").

-include_lib("damsel/include/dmsl_customer_thrift.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([all/0]).
-export([groups/0]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([first_recurrent_payment_success_test/1]).
-export([second_recurrent_payment_success_test/1]).
-export([register_parent_payment_test/1]).
-export([another_party_test/1]).
-export([same_party_different_shops_test/1]).
-export([not_recurring_first_test/1]).
-export([cancelled_first_payment_test/1]).
-export([not_permitted_recurrent_test/1]).
-export([not_exists_invoice_test/1]).
-export([not_exists_payment_test/1]).
-export([customer_id_stored_test/1]).
-export([customer_id_stored_no_parent_test/1]).
-export([regular_payment_saves_to_cubasty_test/1]).
-export([cascade_tokens_filter_success_test/1]).
-export([cascade_recurrent_payment_success_test/1]).
-export([different_customer_id_test/1]).
-export([recurrent_no_customer_bankcard_lookup_test/1]).
-export([make_recurrent_saves_token_without_customer_test/1]).
-export([new_client_old_card_cascade_test/1]).
-export([cascade_exhaustion_test/1]).
-export([cascade_routing_filter_test/1]).

%% Internal types

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name() :: hg_ct_helper:group_name().
-type test_result() :: any() | no_return().

%% Macro helpers

-define(evp(Pattern), fun(EvpPattern) ->
    case EvpPattern of
        Pattern -> true;
        (_) -> false
    end
end).

%% Supervisor callbacks

-behaviour(supervisor).

-export([init/1]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

%% Common tests callbacks

-spec all() -> [{group, test_case_name()}].
all() ->
    [
        {group, basic_operations},
        {group, cascade_tokens},
        {group, domain_affecting_operations}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {basic_operations, [parallel], [
            first_recurrent_payment_success_test,
            second_recurrent_payment_success_test,
            register_parent_payment_test,
            another_party_test,
            same_party_different_shops_test,
            not_recurring_first_test,
            cancelled_first_payment_test,
            not_exists_invoice_test,
            not_exists_payment_test
        ]},
        {domain_affecting_operations, [], [
            not_permitted_recurrent_test
        ]},
        {cascade_tokens, [], [
            customer_id_stored_test,
            customer_id_stored_no_parent_test,
            different_customer_id_test,
            regular_payment_saves_to_cubasty_test,
            cascade_tokens_filter_success_test,
            cascade_recurrent_payment_success_test,
            make_recurrent_saves_token_without_customer_test,
            recurrent_no_customer_bankcard_lookup_test,
            new_client_old_card_cascade_test,
            cascade_exhaustion_test,
            cascade_routing_filter_test
        ]}
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    % _ = dbg:tracer(),
    % _ = dbg:p(all, c),
    % _ = dbg:tpl({woody_client, '_', '_'}, x),
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
        {cowboy, CowboySpec}
    ]),
    _ = hg_domain:upsert(construct_domain_fixture(construct_term_set_w_recurrent_paytools())),
    RootUrl = maps:get(hellgate_root_url, Ret),
    PartyConfigRef = #domain_PartyConfigRef{id = hg_utils:unique_id()},
    AnotherPartyConfigRef = #domain_PartyConfigRef{id = hg_utils:unique_id()},
    PartyClient = {party_client:create_client(), party_client:create_context()},
    _ = hg_ct_helper:create_party(PartyConfigRef, PartyClient),
    _ = hg_ct_helper:create_party(AnotherPartyConfigRef, PartyClient),
    ok = hg_context:save(hg_context:create()),
    Shop1ConfigRef = hg_ct_helper:create_shop(
        PartyConfigRef, ?cat(1), <<"RUB">>, ?trms(1), ?pinst(1), undefined, PartyClient
    ),
    Shop2ConfigRef = hg_ct_helper:create_shop(
        PartyConfigRef, ?cat(1), <<"RUB">>, ?trms(1), ?pinst(1), undefined, PartyClient
    ),
    AnotherPartyShopConfigRef = hg_ct_helper:create_shop(
        AnotherPartyConfigRef, ?cat(1), <<"RUB">>, ?trms(1), ?pinst(1), undefined, PartyClient
    ),
    ok = hg_context:cleanup(),
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    _ = unlink(SupPid),
    C1 = [
        {apps, Apps},
        {root_url, RootUrl},
        {party_config_ref, PartyConfigRef},
        {another_party_config_ref, AnotherPartyConfigRef},
        {shop_config_ref, Shop1ConfigRef},
        {second_shop_config_ref, Shop2ConfigRef},
        {another_party_shop_config_ref, AnotherPartyShopConfigRef},
        {test_sup, SupPid}
        | C
    ],
    ok = start_proxies([{hg_dummy_provider, 1, C1}, {hg_dummy_inspector, 2, C1}]),
    C1.

-spec end_per_suite(config()) -> config().
end_per_suite(C) ->
    _ = hg_domain:cleanup(),
    _ = application:stop(progressor),
    _ = hg_progressor:cleanup(),
    [application:stop(App) || App <- cfg(apps, C)].

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_Name, C) ->
    C.

-spec end_per_group(group_name(), config()) -> ok.
end_per_group(_Name, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    TraceID = hg_ct_helper:make_trace_id(Name),
    ApiClient = hg_ct_helper:create_client(cfg(root_url, C)),
    Client = hg_client_invoicing:start_link(ApiClient),
    [
        {test_case_name, genlib:to_binary(Name)},
        {trace_id, TraceID},
        {client, Client}
        | C
    ].

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(Name, _C) when
    Name =:= cascade_recurrent_payment_success_test;
    Name =:= new_client_old_card_cascade_test;
    Name =:= cascade_exhaustion_test;
    Name =:= cascade_routing_filter_test
->
    restore_domain_after_cascade(),
    ok;
end_per_testcase(_Name, _C) ->
    ok.

%% Tests

-spec first_recurrent_payment_success_test(config()) -> test_result().
first_recurrent_payment_success_test(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, PaymentID} = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec second_recurrent_payment_success_test(config()) -> test_result().
second_recurrent_payment_success_test(C) ->
    Client = cfg(client, C),
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    %% first payment in recurrent session
    Payment1Params = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% second recurrent payment
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(Payment2ID, ?captured()))]
    ) = hg_client_invoicing:get(Invoice2ID, Client).

-define(recurrent_token, <<"recurrent_token">>).

-spec register_parent_payment_test(config()) -> test_result().
register_parent_payment_test(C) ->
    Client = cfg(client, C),
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    %% first payment in recurrent session
    Route = ?route(?prv(1), ?trm(1)),
    {PaymentTool, Session} = make_unique_payment_tool(?pmt_sys(<<"visa-ref">>)),
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
        transaction_info = ?trx_info(<<"1">>, #{}),
        recurrent_token = ?recurrent_token
    },
    Payment1ID = register_payment(Invoice1ID, PaymentParams, false, Client),
    Payment1ID = await_payment_session_started(Invoice1ID, Payment1ID, Client, ?processed()),

    [
        ?payment_ev(PaymentID, ?rec_token_acquired(?recurrent_token)),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(_)))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = hg_invoice_helper:next_changes(Invoice1ID, 4, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),

    %% second recurrent payment
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(Payment2ID, ?captured()))]
    ) = hg_client_invoicing:get(Invoice2ID, Client).

-spec another_party_test(config()) -> test_result().
another_party_test(C) ->
    Client = cfg(client, C),
    AnotherPartyConfigRef = cfg(another_party_config_ref, C),
    AnotherPartyShopConfigRef = cfg(another_party_shop_config_ref, C),
    Invoice1ID = start_invoice_for_party(
        AnotherPartyConfigRef, AnotherPartyShopConfigRef, <<"rubberduck">>, make_due_date(10), 42000, C
    ),
    %% first payment in recurrent session
    Payment1Params = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% second recurrent payment
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    ExpectedError = #payproc_InvalidRecurrentParentPayment{details = <<"Parent payment refer to another party">>},
    {error, ExpectedError} = start_payment(Invoice2ID, Payment2Params, Client).

-spec same_party_different_shops_test(config()) -> test_result().
same_party_different_shops_test(C) ->
    Client = cfg(client, C),
    %% First payment in shop1
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1Params = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Second recurrent payment in shop2 (same party, different shop) - should succeed
    SecondShopConfigRef = cfg(second_shop_config_ref, C),
    Invoice2ID = start_invoice(SecondShopConfigRef, <<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(Payment2ID, ?captured()))]
    ) = hg_client_invoicing:get(Invoice2ID, Client).

-spec not_recurring_first_test(config()) -> test_result().
not_recurring_first_test(C) ->
    Client = cfg(client, C),
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    %% first payment in recurrent session
    Payment1Params = make_payment_params(false, undefined, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% second recurrent payment
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    ExpectedError = #payproc_InvalidRecurrentParentPayment{details = <<"Parent payment has no recurrent token">>},
    {error, ExpectedError} = start_payment(Invoice2ID, Payment2Params, Client).

-spec cancelled_first_payment_test(config()) -> test_result().
cancelled_first_payment_test(C) ->
    Client = cfg(client, C),
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    %% first payment in recurrent session
    Payment1Params = make_payment_params({hold, cancel}, true, undefined, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_cancel(Invoice1ID, Payment1ID, undefined, Client),
    %% second recurrent payment
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(Payment2ID, ?captured()))]
    ) = hg_client_invoicing:get(Invoice2ID, Client).

-spec not_permitted_recurrent_test(config()) -> test_result().
not_permitted_recurrent_test(C) ->
    _ = hg_domain:upsert(construct_domain_fixture(construct_simple_term_set())),
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ExpectedError = #payproc_OperationNotPermitted{},
    {error, ExpectedError} = start_payment(InvoiceID, PaymentParams, Client).

-spec not_exists_invoice_test(config()) -> test_result().
not_exists_invoice_test(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(<<"not_exists">>, <<"not_exists">>),
    PaymentParams = make_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    ExpectedError = #payproc_InvalidRecurrentParentPayment{details = <<"Parent invoice not found">>},
    {error, ExpectedError} = start_payment(InvoiceID, PaymentParams, Client).

-spec not_exists_payment_test(config()) -> test_result().
not_exists_payment_test(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(InvoiceID, <<"not_exists">>),
    PaymentParams = make_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    ExpectedError = #payproc_InvalidRecurrentParentPayment{details = <<"Parent payment not found">>},
    {error, ExpectedError} = start_payment(InvoiceID, PaymentParams, Client).

%% Internal functions

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

start_proxies(Proxies) ->
    setup_proxies(
        lists:map(
            fun
                Mapper({Module, ProxyID, Context}) ->
                    Mapper({Module, ProxyID, #{}, Context});
                Mapper({Module, ProxyID, ProxyOpts, Context}) ->
                    construct_proxy(ProxyID, start_service_handler(Module, Context, #{}), ProxyOpts)
            end,
            Proxies
        )
    ).

register_payment(InvoiceID, RegisterPaymentParams, WithRiskScoring, Client) ->
    hg_invoice_helper:register_payment(InvoiceID, RegisterPaymentParams, WithRiskScoring, Client).

await_payment_session_started(InvoiceID, PaymentID, Client, Target) ->
    hg_invoice_helper:await_payment_session_started(InvoiceID, PaymentID, Client, Target).

setup_proxies(Proxies) ->
    _ = hg_domain:upsert(Proxies),
    ok.

start_service_handler(Module, C, HandlerOpts) ->
    start_service_handler(Module, Module, C, HandlerOpts).

start_service_handler(Name, Module, C, HandlerOpts) ->
    IP = "127.0.0.1",
    Port = get_random_port(),
    Opts = maps:merge(HandlerOpts, #{hellgate_root_url => cfg(root_url, C)}),
    ChildSpec = hg_test_proxy:get_child_spec(Name, Module, IP, Port, Opts),
    {ok, _} = supervisor:start_child(cfg(test_sup, C), ChildSpec),
    hg_test_proxy:get_url(Module, IP, Port).

get_random_port() ->
    rand:uniform(32768) + 32767.

construct_proxy(ID, Url, Options) ->
    {proxy, #domain_ProxyObject{
        ref = ?prx(ID),
        data = #domain_ProxyDefinition{
            name = Url,
            description = Url,
            url = Url,
            options = Options
        }
    }}.

%% Tests: cascade tokens

-spec customer_id_stored_test(config()) -> test_result().
customer_id_stored_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    #customer_Customer{id = CustomerID} = hg_customer_client:create_customer(PartyConfigRef),
    %% Parent payment with customer_id set
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1BaseParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    Payment1Params = Payment1BaseParams#payproc_InvoicePaymentParams{customer_id = CustomerID},
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Child recurrent payment inherits customer_id from parent — not passed explicitly
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{customer_id = StoredCustomerID}
    } = hg_client_invoicing:get_payment(Invoice2ID, Payment2ID, Client),
    ?assertEqual(CustomerID, StoredCustomerID).

-spec customer_id_stored_no_parent_test(config()) -> test_result().
customer_id_stored_no_parent_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    #customer_Customer{id = CustomerID} = hg_customer_client:create_customer(PartyConfigRef),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    BaseParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentParams = BaseParams#payproc_InvoicePaymentParams{customer_id = CustomerID},
    {ok, PaymentID} = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{customer_id = StoredCustomerID}
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ?assertEqual(CustomerID, StoredCustomerID).

-spec different_customer_id_test(config()) -> test_result().
different_customer_id_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    %% Create two different customers
    #customer_Customer{id = CustomerA} = hg_customer_client:create_customer(PartyConfigRef),
    #customer_Customer{id = CustomerB} = hg_customer_client:create_customer(PartyConfigRef),
    %% Parent payment with CustomerA
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1BaseParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    Payment1Params = Payment1BaseParams#payproc_InvoicePaymentParams{customer_id = CustomerA},
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Child recurrent payment with different CustomerB should be rejected
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    BaseParams = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    Payment2Params = BaseParams#payproc_InvoicePaymentParams{customer_id = CustomerB},
    {error, #payproc_InvalidRecurrentParentPayment{details = <<"Customer ID mismatch with parent">>}} =
        start_payment(Invoice2ID, Payment2Params, Client).

-spec regular_payment_saves_to_cubasty_test(config()) -> test_result().
regular_payment_saves_to_cubasty_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    #customer_Customer{id = CustomerID} = hg_customer_client:create_customer(PartyConfigRef),
    %% Non-recurrent payment with customer_id — payment linked, no tokens saved
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    BaseParams = make_payment_params(false, undefined, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = BaseParams#payproc_InvoicePaymentParams{customer_id = CustomerID},
    {ok, PaymentID} = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    %% Payment is linked to customer in cubasty
    {ok, State} = hg_customer_client:get_by_parent_payment(InvoiceID, PaymentID),
    ?assertEqual(CustomerID, State#customer_CustomerState.customer#customer_Customer.id),
    %% But no recurrent tokens saved (make_recurrent=false)
    [] = hg_customer_client:get_recurrent_tokens(InvoiceID, PaymentID).

-spec cascade_tokens_filter_success_test(config()) -> test_result().
cascade_tokens_filter_success_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    #customer_Customer{id = CustomerID} = hg_customer_client:create_customer(PartyConfigRef),
    %% First payment with customer_id + make_recurrent=true
    %% Hellgate auto-saves bank card, recurrent token, and payment to cubasty
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1BaseParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    Payment1Params = Payment1BaseParams#payproc_InvoicePaymentParams{customer_id = CustomerID},
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Second recurrent payment: hellgate queries cubasty via GetByParentPayment,
    %% finds cascade tokens saved by first payment
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(Payment2ID, ?captured()))]
    ) = hg_client_invoicing:get(Invoice2ID, Client).

-spec cascade_recurrent_payment_success_test(config()) -> test_result().
cascade_recurrent_payment_success_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    %% Step 1: Create customer, then parent payment with customer_id on ?prv(1)/?trm(1)
    %% Hellgate auto-saves bank card, recurrent token, and payment link to cubasty
    #customer_Customer{id = CustomerID} = hg_customer_client:create_customer(PartyConfigRef),
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1BaseParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    Payment1Params = Payment1BaseParams#payproc_InvoicePaymentParams{customer_id = CustomerID},
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Verify parent payment route is ?prv(1)/?trm(1) and tokens are saved in cubasty
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [Payment1St]
    ) = hg_client_invoicing:get(Invoice1ID, Client),
    #domain_PaymentRoute{provider = ?prv(1), terminal = ?trm(1)} =
        Payment1St#payproc_InvoicePayment.route,
    [#customer_RecurrentToken{provider_ref = ?prv(1), terminal_ref = ?trm(1)}] =
        hg_customer_client:get_recurrent_tokens(Invoice1ID, Payment1ID),
    %% Step 2: Make ?prv(1) always fail, add ?prv(2)/?trm(2) as cascade fallback
    _ = hg_domain:upsert(construct_cascade_fixture()),
    %% Step 3: Add cascade token for ?prv(2)/?trm(2) to existing bank card
    #payproc_InvoicePayment{payment = #domain_InvoicePayment{payer = Payer1}} =
        hg_client_invoicing:get_payment(Invoice1ID, Payment1ID, Client),
    BCT1 = get_bank_card_token_from_payer(Payer1),
    _ = hg_customer_client:save_recurrent_token_by_card(
        PartyConfigRef,
        BCT1,
        {#domain_PaymentRoute{provider = ?prv(2), terminal = ?trm(2)}, <<"cascade-token-prv2">>}
    ),
    %% Step 4: Routing picks from candidates filtered by tokens; ?prv(1) fails, cascades to ?prv(2)
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [Payment2St]
    ) = hg_client_invoicing:get(Invoice2ID, Client),
    ?payment_state(?payment_w_status(Payment2ID, ?captured())) = Payment2St,
    #domain_PaymentRoute{provider = ?prv(2), terminal = ?trm(2)} =
        Payment2St#payproc_InvoicePayment.route.

-spec make_recurrent_saves_token_without_customer_test(config()) -> test_result().
make_recurrent_saves_token_without_customer_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    %% Payment with make_recurrent=true but NO customer_id
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, PaymentID} = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    %% Verify: no customer_id on the payment
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{customer_id = undefined, payer = Payer}
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    %% Verify: recurrent token was saved to BankCard via bank_card_token lookup
    BCT = get_bank_card_token_from_payer(Payer),
    Tokens = hg_customer_client:get_recurrent_tokens_by_card(PartyConfigRef, BCT),
    ?assertMatch([#customer_RecurrentToken{provider_ref = ?prv(1), terminal_ref = ?trm(1)} | _], Tokens).

-spec recurrent_no_customer_bankcard_lookup_test(config()) -> test_result().
recurrent_no_customer_bankcard_lookup_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    %% Step 1: Parent payment with make_recurrent=true, NO customer_id
    %% Token gets auto-saved to BankCard
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1Params = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Step 2: Child recurrent payment, also NO customer_id
    %% System should find BankCard by bank_card_token and load cascade tokens
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    %% Verify: payment succeeded, no customer_id
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{customer_id = undefined}
    } = hg_client_invoicing:get_payment(Invoice2ID, Payment2ID, Client),
    %% Verify: BankCard now has token(s) accumulated
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{payer = Payer}
    } = hg_client_invoicing:get_payment(Invoice1ID, Payment1ID, Client),
    BCT = get_bank_card_token_from_payer(Payer),
    Tokens = hg_customer_client:get_recurrent_tokens_by_card(PartyConfigRef, BCT),
    ?assert(length(Tokens) >= 1).

-spec new_client_old_card_cascade_test(config()) -> test_result().
new_client_old_card_cascade_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    %% Step 1: First payment with make_recurrent=true, no customer
    %% This saves recurrent token to BankCard for ?prv(1)/?trm(1)
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1Params = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Get bank card token from first payment
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{payer = Payer1}
    } = hg_client_invoicing:get_payment(Invoice1ID, Payment1ID, Client),
    BCT = get_bank_card_token_from_payer(Payer1),
    %% Step 2: Manually add a second recurrent token for ?prv(2)/?trm(2) to the same BankCard
    #customer_BankCard{} = hg_customer_client:find_or_create_bank_card(PartyConfigRef, BCT),
    _ = hg_customer_client:save_recurrent_token_by_card(
        PartyConfigRef,
        BCT,
        {#domain_PaymentRoute{provider = ?prv(2), terminal = ?trm(2)}, <<"cascade-token-prv2">>}
    ),
    %% Step 3: Make ?prv(1) fail, add ?prv(2)/?trm(2) to routing
    _ = hg_domain:upsert(construct_cascade_fixture()),
    %% Step 4: "New client" recurrent payment — routing selects from token-filtered candidates
    %% prv(1) fails, cascades to prv(2)
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    %% Verify: cascade succeeded via ?prv(2)/?trm(2)
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [Payment2St]
    ) = hg_client_invoicing:get(Invoice2ID, Client),
    ?payment_state(?payment_w_status(Payment2ID, ?captured())) = Payment2St,
    #domain_PaymentRoute{provider = ?prv(2), terminal = ?trm(2)} =
        Payment2St#payproc_InvoicePayment.route.

-spec cascade_exhaustion_test(config()) -> test_result().
cascade_exhaustion_test(C) ->
    Client = cfg(client, C),
    %% Step 1: Parent payment, no customer
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1Params = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Step 2: Make ALL providers fail
    _ = hg_domain:upsert(construct_all_fail_fixture()),
    %% Step 3: Recurrent payment should exhaust cascade and fail
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    %% Await payment failure
    Pattern = [
        ?evp(?payment_ev(Payment2ID, ?payment_status_changed(?failed(_))))
    ],
    {ok, _Events} = await_events(Invoice2ID, Pattern, Client),
    ?invoice_state(
        _,
        [?payment_state(?payment_w_status(Payment2ID, ?failed(_)))]
    ) = hg_client_invoicing:get(Invoice2ID, Client).

%% Tokens don't bypass routing: BankCard has tokens for prv(1), prv(2), prv(3),
%% but routing only includes prv(1) and prv(3). prv(2)'s token must not be used.
-spec cascade_routing_filter_test(config()) -> test_result().
cascade_routing_filter_test(C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    %% Step 1: Parent payment — saves token for prv(1)/trm(1)
    Invoice1ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Payment1Params = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    {ok, Payment1ID} = start_payment(Invoice1ID, Payment1Params, Client),
    Payment1ID = await_payment_capture(Invoice1ID, Payment1ID, Client),
    %% Get BCT from parent
    #payproc_InvoicePayment{payment = #domain_InvoicePayment{payer = Payer1}} =
        hg_client_invoicing:get_payment(Invoice1ID, Payment1ID, Client),
    BCT = get_bank_card_token_from_payer(Payer1),
    %% Step 2: Add tokens for prv(2) AND prv(3) — BankCard now has tokens for all three
    _ = hg_customer_client:save_recurrent_token_by_card(
        PartyConfigRef,
        BCT,
        {#domain_PaymentRoute{provider = ?prv(2), terminal = ?trm(2)}, <<"token-prv2">>}
    ),
    _ = hg_customer_client:save_recurrent_token_by_card(
        PartyConfigRef,
        BCT,
        {#domain_PaymentRoute{provider = ?prv(3), terminal = ?trm(3)}, <<"token-prv3">>}
    ),
    %% Step 3: Routing only has prv(1) and prv(3) — prv(2) is NOT in routing rules.
    %% prv(1) fails, so cascade should go to prv(3), skipping prv(2) despite its token.
    _ = hg_domain:upsert(construct_routing_filter_fixture()),
    %% Step 4: Recurrent payment
    Invoice2ID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    RecurrentParent = ?recurrent_parent(Invoice1ID, Payment1ID),
    Payment2Params = make_recurrent_payment_params(true, RecurrentParent, ?pmt_sys(<<"visa-ref">>)),
    {ok, Payment2ID} = start_payment(Invoice2ID, Payment2Params, Client),
    Payment2ID = await_payment_capture(Invoice2ID, Payment2ID, Client),
    %% Verify: routed to prv(3)/trm(3) — prv(2) was excluded by routing despite having a token
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [Payment2St]
    ) = hg_client_invoicing:get(Invoice2ID, Client),
    ?payment_state(?payment_w_status(Payment2ID, ?captured())) = Payment2St,
    #domain_PaymentRoute{provider = ?prv(3), terminal = ?trm(3)} =
        Payment2St#payproc_InvoicePayment.route.

make_payment_params(PmtSys) ->
    make_payment_params(true, undefined, PmtSys).

make_payment_params(MakeRecurrent, RecurrentParent, PmtSys) ->
    make_payment_params(instant, MakeRecurrent, RecurrentParent, PmtSys).

make_payment_params(FlowType, MakeRecurrent, RecurrentParent, PmtSys) ->
    {PaymentTool, Session} = make_unique_payment_tool(PmtSys),
    make_payment_params(PaymentTool, Session, FlowType, MakeRecurrent, RecurrentParent).

make_payment_params(PaymentTool, Session, FlowType, MakeRecurrent, RecurrentParent) ->
    make_payment_params(#domain_ClientInfo{}, PaymentTool, Session, FlowType, MakeRecurrent, RecurrentParent).

make_payment_params(ClientInfo, PaymentTool, Session, FlowType, MakeRecurrent, RecurrentParent) ->
    Flow =
        case FlowType of
            instant ->
                {instant, #payproc_InvoicePaymentParamsFlowInstant{}};
            {hold, OnHoldExpiration} ->
                {hold, #payproc_InvoicePaymentParamsFlowHold{on_hold_expiration = OnHoldExpiration}}
        end,
    Payer = make_payer_params(PaymentTool, Session, ClientInfo, RecurrentParent),
    #payproc_InvoicePaymentParams{
        payer = Payer,
        flow = Flow,
        make_recurrent = MakeRecurrent
    }.

make_payer_params(PaymentTool, Session, ClientInfo, undefined = _RecurrentParent) ->
    {payment_resource, #payproc_PaymentResourcePayerParams{
        resource = #domain_DisposablePaymentResource{
            payment_tool = PaymentTool,
            payment_session_id = Session,
            client_info = ClientInfo
        },
        contact_info = #domain_ContactInfo{}
    }};
make_payer_params(_PaymentTool, _Session, _ClientInfo, RecurrentParent) ->
    {recurrent, #payproc_RecurrentPayerParams{
        recurrent_parent = RecurrentParent,
        contact_info = #domain_ContactInfo{}
    }}.

make_recurrent_payment_params(MakeRecurrent, RecurrentParent, PmtSys) ->
    make_recurrent_payment_params(instant, MakeRecurrent, RecurrentParent, PmtSys).

make_recurrent_payment_params(FlowType, MakeRecurrent, RecurrentParent, PmtSys) ->
    {PaymentTool, _Session} = make_unique_payment_tool(PmtSys),
    make_payment_params(undefined, PaymentTool, undefined, FlowType, MakeRecurrent, RecurrentParent).

make_unique_payment_tool(PmtSys) ->
    {{bank_card, BCard}, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    UniqueToken = <<(BCard#domain_BankCard.token)/binary, "/", Suffix/binary>>,
    {{bank_card, BCard#domain_BankCard{token = UniqueToken}}, Session}.

make_due_date(LifetimeSeconds) ->
    genlib_time:unow() + LifetimeSeconds.

start_invoice(Product, Due, Amount, C) ->
    start_invoice(cfg(shop_config_ref, C), Product, Due, Amount, C).

start_invoice(ShopConfigRef, Product, Due, Amount, C) ->
    Client = cfg(client, C),
    PartyConfigRef = cfg(party_config_ref, C),
    Cash = hg_ct_helper:make_cash(Amount, <<"RUB">>),
    InvoiceParams = hg_ct_helper:make_invoice_params(PartyConfigRef, ShopConfigRef, Product, Due, Cash),
    InvoiceID = create_invoice(InvoiceParams, Client),
    _Events = await_events(InvoiceID, [?evp(?invoice_created(?invoice_w_status(?invoice_unpaid())))], Client),
    InvoiceID.

start_invoice_for_party(PartyConfigRef, ShopConfigRef, Product, Due, Amount, C) ->
    Client = cfg(client, C),
    Cash = hg_ct_helper:make_cash(Amount, <<"RUB">>),
    InvoiceParams = hg_ct_helper:make_invoice_params(PartyConfigRef, ShopConfigRef, Product, Due, Cash),
    InvoiceID = create_invoice(InvoiceParams, Client),
    _Events = await_events(InvoiceID, [?evp(?invoice_created(?invoice_w_status(?invoice_unpaid())))], Client),
    InvoiceID.

start_payment(InvoiceID, PaymentParams, Client) ->
    case hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client) of
        ?payment_state(?payment(PaymentID)) ->
            {ok, PaymentID};
        {exception, Exception} ->
            {error, Exception}
    end.

create_invoice(InvoiceParams, Client) ->
    ?invoice_state(?invoice(InvoiceID)) = hg_client_invoicing:create(InvoiceParams, Client),
    InvoiceID.

get_payment_cost(InvoiceID, PaymentID, Client) ->
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{cost = Cost}
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    Cost.

await_payment_capture(InvoiceID, PaymentID, Client) ->
    await_payment_capture(InvoiceID, PaymentID, ?timeout_reason(), Client).

await_payment_capture(InvoiceID, PaymentID, Reason, Client) ->
    Cost = get_payment_cost(InvoiceID, PaymentID, Client),
    Pattern = [
        ?evp(?payment_ev(PaymentID, ?payment_status_changed(?captured(Reason, Cost))))
    ],
    {ok, _Events} = await_events(InvoiceID, Pattern, Client),
    PaymentID.

await_payment_cancel(InvoiceID, PaymentID, Reason, Client) ->
    Pattern = [
        ?evp(?payment_ev(PaymentID, ?payment_status_changed(?cancelled_with_reason(Reason))))
    ],
    {ok, _Events} = await_events(InvoiceID, Pattern, Client),
    PaymentID.

%% Event helpers

await_events(InvoiceID, Filters, Client) ->
    await_events(InvoiceID, Filters, 12000, Client).

await_events(InvoiceID, Filters, Timeout, Client) ->
    do_await_events(InvoiceID, Filters, Timeout, Client, [], []).

do_await_events(_InvoiceID, [], _Timeout, _Client, _NotProcessedEvents, MatchedEvents) ->
    {ok, lists:reverse(MatchedEvents)};
do_await_events(_InvoiceID, Filters, _Timeout, _Client, timeout, MatchedEvents) ->
    {error, {timeout, Filters, MatchedEvents}};
do_await_events(InvoiceID, Filters, Timeout, Client, [], MatchedEvents) ->
    NewEvents = next_event(InvoiceID, Timeout, Client),
    do_await_events(InvoiceID, Filters, Timeout, Client, NewEvents, MatchedEvents);
do_await_events(InvoiceID, [FilterFn | FTail] = Filters, Timeout, Client, [Ev | EvTail], MatchedEvents) ->
    case FilterFn(Ev) of
        true ->
            do_await_events(InvoiceID, FTail, Timeout, Client, EvTail, [Ev | MatchedEvents]);
        false ->
            do_await_events(InvoiceID, Filters, Timeout, Client, EvTail, MatchedEvents)
    end.

next_event(InvoiceID, Timeout, Client) ->
    case hg_client_invoicing:pull_event(InvoiceID, Timeout, Client) of
        {ok, ?invoice_ev(Changes)} ->
            Changes;
        Result ->
            Result
    end.

%% Domain helper

-spec construct_term_set_w_recurrent_paytools() -> term().
construct_term_set_w_recurrent_paytools() ->
    TermSet = construct_simple_term_set(),
    TermSet#domain_TermSet{
        recurrent_paytools = #domain_RecurrentPaytoolsServiceTerms{
            payment_methods =
                {value,
                    ordsets:from_list([
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                    ])}
        }
    }.

-spec construct_simple_term_set() -> term().
construct_simple_term_set() ->
    #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies =
                {value,
                    ordsets:from_list([
                        ?cur(<<"RUB">>)
                    ])},
            categories =
                {value,
                    ordsets:from_list([
                        ?cat(1)
                    ])},
            payment_methods =
                {value,
                    ordsets:from_list([
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                    ])},
            cash_limit =
                {decisions, [
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value, #domain_CashRange{
                                lower = {inclusive, ?cash(1000, <<"RUB">>)},
                                upper = {exclusive, ?cash(420000000, <<"RUB">>)}
                            }}
                    }
                ]},
            fees =
                {value, [
                    ?cfpost(
                        {merchant, settlement},
                        {system, settlement},
                        ?share(45, 1000, operation_amount)
                    )
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
            }
        }
    }.

-spec construct_domain_fixture(term()) -> [hg_domain:object()].
construct_domain_fixture(TermSet) ->
    [
        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),

        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_inspector(?insp(1), <<"Rejector">>, ?prx(2), #{<<"risk_score">> => <<"low">>}),

        hg_ct_fixture:construct_system_account_set(?sas(1)),
        hg_ct_fixture:construct_external_account_set(?eas(1)),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(1)
                },
                inspector =
                    {decisions, [
                        #domain_InspectorDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ = {value, ?insp(1)}
                        }
                    ]},
                residences = [],
                realm = test
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(1),
            data = #domain_RoutingRuleset{
                name = <<"No prohibition: all terminals are allowed">>,
                decisions = {candidates, []}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"Prohibition: terminal is denied">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(1))
                    ]}
            }
        }},
        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set = {value, ?eas(1)},
                payment_institutions = ?ordset([?pinst(1)])
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                parent_terms = undefined,
                term_set = TermSet
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                realm = test,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies = {value, ?ordset([?cur(<<"RUB">>)])},
                        categories = {value, ?ordset([?cat(1)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
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
                        }
                    },
                    recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                        categories = {value, ?ordset([?cat(1)])},
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

        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"visa-ref">>), <<"visa payment system">>),
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"mastercard-ref">>), <<"mastercard payment system">>)
    ].

construct_cascade_fixture() ->
    Revision = hg_domain:head(),
    #domain_Provider{accounts = Accounts, terms = Terms} =
        hg_domain:get(Revision, {provider, ?prv(1)}),
    #domain_TermSetHierarchy{term_set = TermSet} =
        hg_domain:get(Revision, {term_set_hierarchy, ?trms(1)}),
    #domain_TermSet{payments = PaymentsTerms} = TermSet,
    [
        %% Make ?prv(1) always fail (parent route will fail on child payment)
        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider (now failing)">>,
                description = <<"Was good, now fails">>,
                realm = test,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
                        <<"override">> => <<"brovider_blocker">>
                    }
                },
                accounts = Accounts,
                terms = Terms
            }
        }},
        %% Succeeding provider for cascade fallback
        {provider, #domain_ProviderObject{
            ref = ?prv(2),
            data = #domain_Provider{
                name = <<"Cascade Fallback">>,
                description = <<"Succeeds on cascade">>,
                realm = test,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                accounts = Accounts,
                terms = Terms
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(2),
            data = #domain_Terminal{
                name = <<"Cascade Fallback Terminal">>,
                description = <<"Cascade Fallback Terminal">>,
                provider_ref = ?prv(2)
            }
        }},
        %% Routing with both candidates
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"Cascade routing">>,
                decisions =
                    {candidates, [
                        ?candidate(<<"Brovider">>, {constant, true}, ?trm(1), 1000),
                        ?candidate(<<"Cascade Fallback">>, {constant, true}, ?trm(2), 1000)
                    ]}
            }
        }},
        %% Allow cascade: increase attempt limit to 2
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_set = TermSet#domain_TermSet{
                    payments = PaymentsTerms#domain_PaymentsServiceTerms{
                        attempt_limit = {value, #domain_AttemptLimit{attempts = 2}}
                    }
                }
            }
        }}
    ].

construct_all_fail_fixture() ->
    Revision = hg_domain:head(),
    #domain_Provider{accounts = Accounts, terms = Terms} =
        hg_domain:get(Revision, {provider, ?prv(1)}),
    #domain_TermSetHierarchy{term_set = TermSet} =
        hg_domain:get(Revision, {term_set_hierarchy, ?trms(1)}),
    #domain_TermSet{payments = PaymentsTerms} = TermSet,
    FailProxy = #{
        <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
        <<"override">> => <<"all_fail">>
    },
    [
        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider (failing)">>,
                description = <<"Always fails">>,
                realm = test,
                proxy = #domain_Proxy{ref = ?prx(1), additional = FailProxy},
                accounts = Accounts,
                terms = Terms
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_set = TermSet#domain_TermSet{
                    payments = PaymentsTerms#domain_PaymentsServiceTerms{
                        attempt_limit = {value, #domain_AttemptLimit{attempts = 2}}
                    }
                }
            }
        }}
    ].

construct_routing_filter_fixture() ->
    Revision = hg_domain:head(),
    #domain_Provider{accounts = Accounts, terms = Terms} =
        hg_domain:get(Revision, {provider, ?prv(1)}),
    #domain_TermSetHierarchy{term_set = TermSet} =
        hg_domain:get(Revision, {term_set_hierarchy, ?trms(1)}),
    #domain_TermSet{payments = PaymentsTerms} = TermSet,
    FailProxy = #{
        <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
        <<"override">> => <<"routing_filter">>
    },
    [
        %% prv(1): fails
        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Failing provider">>,
                description = <<"Always fails">>,
                realm = test,
                proxy = #domain_Proxy{ref = ?prx(1), additional = FailProxy},
                accounts = Accounts,
                terms = Terms
            }
        }},
        %% prv(3): succeeds
        {provider, #domain_ProviderObject{
            ref = ?prv(3),
            data = #domain_Provider{
                name = <<"Fallback provider">>,
                description = <<"Succeeds">>,
                realm = test,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                accounts = Accounts,
                terms = Terms
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(3),
            data = #domain_Terminal{
                name = <<"Fallback terminal">>,
                description = <<"Fallback terminal">>,
                provider_ref = ?prv(3)
            }
        }},
        %% Routing: only prv(1) and prv(3) — prv(2) is NOT routable
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"Filter routing">>,
                decisions =
                    {candidates, [
                        ?candidate(<<"Failing">>, {constant, true}, ?trm(1), 1000),
                        ?candidate(<<"Fallback">>, {constant, true}, ?trm(3), 1000)
                    ]}
            }
        }},
        %% Allow cascade: attempt limit 2
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_set = TermSet#domain_TermSet{
                    payments = PaymentsTerms#domain_PaymentsServiceTerms{
                        attempt_limit = {value, #domain_AttemptLimit{attempts = 2}}
                    }
                }
            }
        }}
    ].

%% Restore only objects modified by cascade/fail fixtures, without touching proxy URLs.
%% construct_domain_fixture includes hg_ct_fixture:construct_proxy which sets url = <<>>,
%% but real proxy URLs were set by start_proxies in init_per_suite.
restore_domain_after_cascade() ->
    TermSet = construct_term_set_w_recurrent_paytools(),
    Fixture = construct_domain_fixture(TermSet),
    SafeObjects = [Obj || {Type, _} = Obj <- Fixture, Type =/= proxy],
    _ = hg_domain:upsert(SafeObjects),
    ok.

get_bank_card_token_from_payer(
    ?payment_resource_payer(
        #domain_DisposablePaymentResource{
            payment_tool = {bank_card, #domain_BankCard{token = Token}}
        },
        _
    )
) ->
    Token;
get_bank_card_token_from_payer(?recurrent_payer({bank_card, #domain_BankCard{token = Token}}, _, _)) ->
    Token.
