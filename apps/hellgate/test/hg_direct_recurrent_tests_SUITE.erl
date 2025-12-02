-module(hg_direct_recurrent_tests_SUITE).

-include("hg_ct_domain.hrl").
-include("hg_ct_json.hrl").
-include("hg_ct_invoice.hrl").

-include("invoice_events.hrl").
-include("payment_events.hrl").

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
-export([not_recurring_first_test/1]).
-export([cancelled_first_payment_test/1]).
-export([not_permitted_recurrent_test/1]).
-export([not_exists_invoice_test/1]).
-export([not_exists_payment_test/1]).

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
            not_recurring_first_test,
            cancelled_first_payment_test,
            not_exists_invoice_test,
            not_exists_payment_test
        ]},
        {domain_affecting_operations, [], [
            not_permitted_recurrent_test
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
    _ = hg_domain:insert(construct_domain_fixture(construct_term_set_w_recurrent_paytools())),
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
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
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

make_payment_params(PmtSys) ->
    make_payment_params(true, undefined, PmtSys).

make_payment_params(MakeRecurrent, RecurrentParent, PmtSys) ->
    make_payment_params(instant, MakeRecurrent, RecurrentParent, PmtSys).

make_payment_params(FlowType, MakeRecurrent, RecurrentParent, PmtSys) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
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
    {PaymentTool, _Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    make_payment_params(undefined, PaymentTool, undefined, FlowType, MakeRecurrent, RecurrentParent).

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
