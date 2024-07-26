-module(hg_customer_tests_SUITE).

-include("hg_ct_domain.hrl").
-include("hg_ct_json.hrl").

-include_lib("hellgate/include/customer_events.hrl").

-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([all/0]).
-export([groups/0]).

-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([invalid_party/1]).
-export([invalid_shop/1]).
-export([invalid_party_status/1]).
-export([invalid_shop_status/1]).

-export([create_customer/1]).
-export([delete_customer/1]).
-export([start_binding_w_failure/1]).
-export([start_binding_w_suspend/1]).
-export([start_binding_w_suspend_timeout/1]).
-export([start_binding_w_suspend_failure/1]).
-export([start_binding_w_suspend_timeout_default/1]).
-export([start_binding/1]).
-export([start_binding_w_tds/1]).
-export([start_two_bindings/1]).
-export([start_two_bindings_w_tds/1]).
-export([terms_retrieval/1]).

-export([create_customer_not_permitted/1]).
-export([start_binding_not_permitted/1]).

%%

-behaviour(supervisor).

-export([init/1]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

%%

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name() :: hg_ct_helper:group_name().
-type test_case_result() :: _ | no_return().

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    % _ = dbg:tracer(),
    % _ = dbg:p(all, c),
    % _ = dbg:tpl({'hg_dummy_provider', 'handle_function', '_'}, x),
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
        snowflake,
        {cowboy, CowboySpec}
    ]),
    _ = hg_domain:insert(construct_domain_fixture(construct_term_set_w_recurrent_paytools())),
    RootUrl = maps:get(hellgate_root_url, Ret),
    PartyID = hg_utils:unique_id(),
    PartyClient = {party_client:create_client(), party_client:create_context()},
    ShopID = hg_ct_helper:create_party_and_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    _ = unlink(SupPid),
    C1 = [
        {apps, Apps},
        {root_url, RootUrl},
        {party_client, PartyClient},
        {party_id, PartyID},
        {shop_id, ShopID},
        {test_sup, SupPid}
        | C
    ],
    ok = start_proxies([{hg_dummy_provider, 1, C1}, {hg_dummy_inspector, 2, C1}]),
    C1.

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = hg_domain:cleanup(),
    _ = hg_progressor:cleanup(),
    [application:stop(App) || App <- cfg(apps, C)].

-spec all() -> [{group, test_case_name()}].
all() ->
    [
        {group, invalid_customer_params},
        {group, basic_customer_methods},
        {group, not_permitted_methods}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {invalid_customer_params, [sequence], [
            invalid_party,
            invalid_shop,
            invalid_party_status,
            invalid_shop_status
        ]},
        {basic_customer_methods, [sequence], [
            create_customer,
            delete_customer,
            start_binding_w_failure,
            start_binding_w_suspend,
            start_binding_w_suspend_timeout,
            start_binding_w_suspend_failure,
            start_binding_w_suspend_timeout_default,
            start_binding,
            start_binding_w_tds,
            start_two_bindings,
            start_two_bindings_w_tds,
            terms_retrieval
        ]},
        {not_permitted_methods, [sequence], [
            create_customer_not_permitted,
            start_binding_not_permitted
        ]}
    ].

%%

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    RootUrl = cfg(root_url, C),
    TraceID = hg_ct_helper:make_trace_id(Name),
    Client = hg_client_customer:start(hg_ct_helper:create_client(RootUrl, TraceID)),
    [
        {test_case_name, genlib:to_binary(Name)},
        {trace_id, TraceID},
        {client, Client}
        | C
    ].

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, _C) ->
    ok.

%%

-spec invalid_party(config()) -> test_case_result().
-spec invalid_shop(config()) -> test_case_result().
-spec invalid_party_status(config()) -> test_case_result().
-spec invalid_shop_status(config()) -> test_case_result().

invalid_party(C) ->
    RootUrl = cfg(root_url, C),
    PartyID = hg_utils:unique_id(),
    ShopID = hg_utils:unique_id(),
    Client = hg_client_customer:start(hg_ct_helper:create_client(RootUrl, cfg(trace_id, C))),
    Params = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    {exception, #payproc_PartyNotFound{}} = hg_client_customer:create(Params, Client).

invalid_shop(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = hg_utils:unique_id(),
    Params = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    {exception, #payproc_ShopNotFound{}} = hg_client_customer:create(Params, Client).

invalid_party_status(C) ->
    Client = cfg(client, C),
    {PartyClient, Context} = cfg(party_client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    ok = party_client_thrift:block(PartyID, <<>>, PartyClient, Context),
    {exception, ?invalid_party_status({blocking, _})} = hg_client_customer:create(Params, Client),
    ok = party_client_thrift:unblock(PartyID, <<>>, PartyClient, Context),
    ok = party_client_thrift:suspend(PartyID, PartyClient, Context),
    {exception, ?invalid_party_status({suspension, _})} = hg_client_customer:create(Params, Client),
    ok = party_client_thrift:activate(PartyID, PartyClient, Context).

invalid_shop_status(C) ->
    Client = cfg(client, C),
    {PartyClient, Context} = cfg(party_client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    ok = party_client_thrift:block_shop(PartyID, ShopID, <<>>, PartyClient, Context),
    {exception, ?invalid_shop_status({blocking, _})} = hg_client_customer:create(Params, Client),
    ok = party_client_thrift:unblock_shop(PartyID, ShopID, <<>>, PartyClient, Context),
    ok = party_client_thrift:suspend_shop(PartyID, ShopID, PartyClient, Context),
    {exception, ?invalid_shop_status({suspension, _})} = hg_client_customer:create(Params, Client),
    ok = party_client_thrift:activate_shop(PartyID, ShopID, PartyClient, Context).

%%

-spec create_customer(config()) -> test_case_result().
-spec delete_customer(config()) -> test_case_result().
-spec start_binding_w_failure(config()) -> test_case_result().
-spec start_binding_w_suspend(config()) -> test_case_result().
-spec start_binding_w_suspend_timeout(config()) -> test_case_result().
-spec start_binding_w_suspend_failure(config()) -> test_case_result().
-spec start_binding_w_suspend_timeout_default(config()) -> test_case_result().
-spec start_binding(config()) -> test_case_result().
-spec start_binding_w_tds(config()) -> test_case_result().
-spec start_two_bindings(config()) -> test_case_result().
-spec start_two_bindings_w_tds(config()) -> test_case_result().
-spec terms_retrieval(config()) -> test_case_result().

create_customer(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    Customer = hg_client_customer:get(CustomerID, Client).

delete_customer(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    ok = hg_client_customer:delete(CustomerID, Client),
    {exception, #'payproc_CustomerNotFound'{}} = hg_client_customer:get(CustomerID, Client).

start_binding_w_failure(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    CustomerBindingID = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool(forbidden, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding = hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client),
    Customer1 = hg_client_customer:get(CustomerID, Client),
    #payproc_Customer{id = CustomerID, bindings = Bindings} = Customer1,
    Bindings = [CustomerBinding],
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(
            _,
            ?customer_binding_started(
                #payproc_CustomerBinding{rec_payment_tool_id = RecPaymentToolID},
                _
            )
        )
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(_, ?customer_binding_status_changed(?customer_binding_failed(_)))
    ] = next_event(CustomerID, Client).

start_binding_w_suspend(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    CustomerBindingID = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool({preauth_3ds_sleep, 180}, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding = hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client),
    Customer1 = hg_client_customer:get(CustomerID, Client),
    #payproc_Customer{id = CustomerID, bindings = Bindings} = Customer1,
    Bindings = [CustomerBinding],
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(
            _,
            ?customer_binding_started(#payproc_CustomerBinding{rec_payment_tool_id = RecPaymentToolID}, _)
        )
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(ID, ?customer_binding_interaction_changed(UserInteraction, {requested, _}))
    ] = next_event(CustomerID, Client),
    _ = assert_success_interaction(UserInteraction),
    SuccessChanges = [
        ?customer_binding_changed(ID, ?customer_binding_status_changed(?customer_binding_succeeded())),
        ?customer_status_changed(?customer_ready())
    ],
    _ = await_for_changes(SuccessChanges, CustomerID, Client).

start_binding_w_suspend_timeout(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    CustomerBindingID = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool(no_preauth_timeout, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding = hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client),
    Customer1 = hg_client_customer:get(CustomerID, Client),
    #payproc_Customer{id = CustomerID, bindings = Bindings} = Customer1,
    Bindings = [CustomerBinding],
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(
            ID,
            ?customer_binding_started(#payproc_CustomerBinding{rec_payment_tool_id = RecPaymentToolID}, _)
        )
    ] = next_event(CustomerID, Client),
    SuccessChanges = [
        ?customer_binding_changed(ID, ?customer_binding_status_changed(?customer_binding_succeeded())),
        ?customer_status_changed(?customer_ready())
    ],
    _ = await_for_changes(SuccessChanges, CustomerID, Client).

start_binding_w_suspend_timeout_default(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    CustomerBindingID = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool(no_preauth_suspend_default, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding = hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client),
    Customer1 = hg_client_customer:get(CustomerID, Client),
    #payproc_Customer{id = CustomerID, bindings = Bindings} = Customer1,
    Bindings = [CustomerBinding],
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(
            ID,
            ?customer_binding_started(#payproc_CustomerBinding{rec_payment_tool_id = RecPaymentToolID}, _)
        )
    ] = next_event(CustomerID, Client),
    OperationFailure = {operation_timeout, #domain_OperationTimeout{}},
    DefaultFailure = [
        ?customer_binding_changed(ID, ?customer_binding_status_changed(?customer_binding_failed(OperationFailure)))
    ],
    _ = await_for_changes(DefaultFailure, CustomerID, Client).

start_binding_w_suspend_failure(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    CustomerBindingID = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool(no_preauth_timeout_failure, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding = hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client),
    Customer1 = hg_client_customer:get(CustomerID, Client),
    #payproc_Customer{id = CustomerID, bindings = Bindings} = Customer1,
    Bindings = [CustomerBinding],
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(
            ID,
            ?customer_binding_started(#payproc_CustomerBinding{rec_payment_tool_id = RecPaymentToolID}, _)
        )
    ] = next_event(CustomerID, Client),
    OperationFailure =
        {failure, #domain_Failure{
            code = <<"preauthorization_failed">>,
            sub = ?'_'
        }},
    SuccessChanges = [
        ?customer_binding_changed(ID, ?customer_binding_status_changed(?customer_binding_failed(OperationFailure)))
    ],
    _ = await_for_changes(SuccessChanges, CustomerID, Client).

start_binding(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    CustomerBindingID = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding = hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client),
    Customer1 = hg_client_customer:get(CustomerID, Client),
    #payproc_Customer{id = CustomerID, bindings = Bindings} = Customer1,
    Bindings = [CustomerBinding],
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(_, ?customer_binding_started(CustomerBinding, _))
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(_, ?customer_binding_status_changed(?customer_binding_succeeded())),
        ?customer_status_changed(?customer_ready())
    ] = next_event(CustomerID, Client).

start_binding_w_tds(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    Customer = hg_client_customer:create(CustomerParams, Client),
    #payproc_Customer{id = CustomerID} = Customer,
    CustomerBindingID = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool({preauth_3ds, 30}, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding = hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client),
    Customer1 = hg_client_customer:get(CustomerID, Client),
    #payproc_Customer{id = CustomerID, bindings = Bindings} = Customer1,
    Bindings = [CustomerBinding],
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(_, ?customer_binding_started(CustomerBinding, _))
    ] = next_event(CustomerID, Client),
    [
        ?customer_binding_changed(_, ?customer_binding_interaction_changed(UserInteraction, {requested, _}))
    ] = next_event(CustomerID, Client),
    _ = assert_success_interaction(UserInteraction),
    [
        ?customer_binding_changed(_, ?customer_binding_interaction_changed(UserInteraction, {completed, _})),
        ?customer_binding_changed(_, ?customer_binding_status_changed(?customer_binding_succeeded())),
        ?customer_status_changed(?customer_ready())
    ] = next_event(CustomerID, Client).

start_two_bindings(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    #payproc_Customer{id = CustomerID} = hg_client_customer:create(CustomerParams, Client),
    CustomerBindingID1 = hg_utils:unique_id(),
    CustomerBindingID2 = hg_utils:unique_id(),
    RecPaymentToolID = hg_utils:unique_id(),
    CustomerBindingParams1 =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID1,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBindingParams2 =
        hg_ct_helper:make_customer_binding_params(
            CustomerBindingID2,
            RecPaymentToolID,
            hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>))
        ),
    CustomerBinding1 =
        #payproc_CustomerBinding{id = CustomerBindingID1} =
        hg_client_customer:start_binding(CustomerID, CustomerBindingParams1, Client),
    CustomerBinding2 =
        #payproc_CustomerBinding{id = CustomerBindingID2} =
        hg_client_customer:start_binding(CustomerID, CustomerBindingParams2, Client),
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    StartChanges = [
        ?customer_binding_changed(CustomerBindingID1, ?customer_binding_started(CustomerBinding1, ?'_')),
        ?customer_binding_changed(CustomerBindingID2, ?customer_binding_started(CustomerBinding2, ?'_')),
        ?customer_binding_changed(CustomerBindingID2, ?customer_binding_status_changed(?customer_binding_succeeded())),
        ?customer_binding_changed(CustomerBindingID1, ?customer_binding_status_changed(?customer_binding_succeeded())),
        ?customer_status_changed(?customer_ready())
    ],
    _ = await_for_changes(StartChanges, CustomerID, Client, 30000).

start_two_bindings_w_tds(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    #payproc_Customer{id = CustomerID} = hg_client_customer:create(CustomerParams, Client),
    CustomerBindingID1 = hg_utils:unique_id(),
    CustomerBindingID2 = hg_utils:unique_id(),
    RecPaymentToolID1 = hg_utils:unique_id(),
    RecPaymentToolID2 = hg_utils:unique_id(),
    PaymentTool = hg_dummy_provider:make_payment_tool({preauth_3ds, 30}, ?pmt_sys(<<"visa-ref">>)),
    CustomerBindingParams1 = hg_ct_helper:make_customer_binding_params(
        CustomerBindingID1,
        RecPaymentToolID1,
        PaymentTool
    ),
    CustomerBindingParams2 = hg_ct_helper:make_customer_binding_params(
        CustomerBindingID2,
        RecPaymentToolID2,
        PaymentTool
    ),
    CustomerBinding1 =
        #payproc_CustomerBinding{id = CustomerBindingID1} =
        hg_client_customer:start_binding(CustomerID, CustomerBindingParams1, Client),
    CustomerBinding2 =
        #payproc_CustomerBinding{id = CustomerBindingID2} =
        hg_client_customer:start_binding(CustomerID, CustomerBindingParams2, Client),
    [
        ?customer_created(_, _, _, _, _, _)
    ] = next_event(CustomerID, Client),
    StartChanges = [
        ?customer_binding_changed(CustomerBindingID1, ?customer_binding_started(CustomerBinding1, ?'_')),
        ?customer_binding_changed(
            CustomerBindingID1,
            ?customer_binding_interaction_changed(?'_', {requested, ?'_'})
        ),
        ?customer_binding_changed(CustomerBindingID2, ?customer_binding_started(CustomerBinding2, ?'_')),
        ?customer_binding_changed(
            CustomerBindingID2,
            ?customer_binding_interaction_changed(?'_', {requested, ?'_'})
        )
    ],
    [
        ?customer_binding_changed(CustomerBindingID1, ?customer_binding_started(CustomerBinding1, _)),
        ?customer_binding_changed(CustomerBindingID1, ?customer_binding_interaction_changed(UserInteraction1, _)),
        ?customer_binding_changed(CustomerBindingID2, ?customer_binding_started(CustomerBinding2, _)),
        ?customer_binding_changed(CustomerBindingID2, ?customer_binding_interaction_changed(UserInteraction2, _))
    ] = await_for_changes(StartChanges, CustomerID, Client),
    _ = assert_success_interaction(UserInteraction1),
    [
        ?customer_binding_changed(
            CustomerBindingID1,
            ?customer_binding_interaction_changed(UserInteraction1, {completed, _})
        ),
        ?customer_binding_changed(CustomerBindingID1, ?customer_binding_status_changed(?customer_binding_succeeded())),
        ?customer_status_changed(?customer_ready())
    ] = next_event(CustomerID, Client),
    _ = assert_success_interaction(UserInteraction2),
    [
        ?customer_binding_changed(
            CustomerBindingID2,
            ?customer_binding_interaction_changed(UserInteraction2, {completed, _})
        ),
        ?customer_binding_changed(CustomerBindingID2, ?customer_binding_status_changed(?customer_binding_succeeded()))
    ] = next_event(CustomerID, Client).

terms_retrieval(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    #payproc_Customer{id = CustomerID} = hg_client_customer:create(CustomerParams, Client),

    Revision = hg_domain:head(),
    _ = hg_domain:update(construct_payment_methods_terms()),

    Timestamp = hg_datetime:format_now(),
    TermSet = hg_client_customer:compute_terms(CustomerID, {timestamp, Timestamp}, Client),

    _ = hg_domain:reset(Revision),

    #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            payment_methods = {value, [?pmt(bank_card, ?bank_card(<<"visa-ref">>))]}
        }
    } = TermSet.

%%

-spec create_customer_not_permitted(config()) -> test_case_result().
-spec start_binding_not_permitted(config()) -> test_case_result().

create_customer_not_permitted(C) ->
    _ = hg_domain:upsert(construct_domain_fixture(construct_simple_term_set())),
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    {exception, #payproc_OperationNotPermitted{}} = hg_client_customer:create(CustomerParams, Client).

start_binding_not_permitted(C) ->
    _ = hg_domain:upsert(construct_domain_fixture(construct_term_set_w_recurrent_paytools())),
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, cfg(test_case_name, C)),
    #payproc_Customer{id = CustomerID} = hg_client_customer:create(CustomerParams, Client),
    _ = hg_domain:upsert(construct_domain_fixture(construct_simple_term_set())),
    CustomerBindingParams =
        hg_ct_helper:make_customer_binding_params(
            hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>))
        ),
    {exception, #payproc_OperationNotPermitted{}} =
        hg_client_customer:start_binding(CustomerID, CustomerBindingParams, Client).

%%

-define(INTERVAL, 100).
-define(DEFAULT_TIMEOUT, 10000).

await_for_changes(ChangeMatchPatterns, CustomerID, Client) ->
    await_for_changes(ChangeMatchPatterns, CustomerID, Client, ?DEFAULT_TIMEOUT).

await_for_changes(ChangeMatchPatterns, CustomerID, Client, Timeout) ->
    MatchSpecs = [ets:match_spec_compile([{MP, [], ['$_']}]) || MP <- ChangeMatchPatterns],
    MatchSpecs1 = lists:zip3(lists:seq(1, length(MatchSpecs)), ChangeMatchPatterns, MatchSpecs),
    Matched = await_for_changes(MatchSpecs1, CustomerID, Client, [], Timeout),
    {_, Result} = lists:unzip(lists:keysort(1, Matched)),
    Result.

await_for_changes(MatchSpecs, CustomerID, Client, Acc, TimeLeftWas) when TimeLeftWas > 0 ->
    Started = genlib_time:ticks(),
    Changes = next_event(CustomerID, Client, TimeLeftWas),
    case run_match_specs(MatchSpecs, Changes) of
        {Matched, []} ->
            Acc ++ Matched;
        {Matched, MatchSpecsLeft} ->
            ok = timer:sleep(?INTERVAL),
            TimeLeft = TimeLeftWas - (genlib_time:ticks() - Started) div 1000,
            await_for_changes(MatchSpecsLeft, CustomerID, Client, Acc ++ Matched, TimeLeft)
    end;
await_for_changes(MatchSpecs, CustomerID, _Client, Acc, _TimeLeft) ->
    error({event_limit_exceeded, {CustomerID, MatchSpecs, Acc}}).

run_match_specs(MatchSpecs0, Changes) when is_list(Changes) ->
    lists:foldl(
        fun(Change, {Acc, MatchSpecs}) ->
            case run_match_specs_(MatchSpecs, Change) of
                [{N, _, _} | _] ->
                    {[{N, Change} | Acc], lists:keydelete(N, 1, MatchSpecs)};
                [] ->
                    {Acc, MatchSpecs}
            end
        end,
        {[], MatchSpecs0},
        Changes
    );
run_match_specs(MatchSpecs, timeout) ->
    {[], MatchSpecs}.

run_match_specs_(MatchSpecs, Change) ->
    lists:dropwhile(
        fun({_N, _Pat, MS}) ->
            length(ets:match_spec_run([Change], MS)) == 0
        end,
        MatchSpecs
    ).

%%

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
    {ok, _} = supervisor:start_child(cfg(test_sup, C), ChildSpec#{id => Name}),
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

%%

next_event(CustomerID, Client) ->
    next_event(CustomerID, Client, 30000).

next_event(CustomerID, Client, Timeout) ->
    case hg_client_customer:pull_event(CustomerID, Timeout, Client) of
        {ok, ?customer_event(Changes)} ->
            Changes;
        Result ->
            Result
    end.

%%

assert_success_interaction(?redirect(URL, Form)) ->
    {ok, 200, _RespHeaders, _ClientRef} = post_request(URL, Form).

post_request(URL, Form) ->
    Method = post,
    Headers = [],
    Body = {form, maps:to_list(Form)},
    hackney:request(Method, URL, Headers, Body).

%%

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
                ]}
        }
    }.

construct_payment_methods_terms() ->
    TermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            payment_methods =
                {value,
                    ordsets:from_list([
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                    ])}
        }
    },
    {term_set_hierarchy, #domain_TermSetHierarchyObject{
        ref = ?trms(1),
        data = #domain_TermSetHierarchy{
            parent_terms = undefined,
            term_sets = [
                #domain_TimedTermSet{
                    action_time = #base_TimestampInterval{},
                    terms = TermSet
                }
            ]
        }
    }}.

-spec construct_domain_fixture(term()) -> [hg_domain:object()].
construct_domain_fixture(TermSet) ->
    [
        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),

        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa-ref">>))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_inspector(?insp(1), <<"Rejector">>, ?prx(2), #{<<"risk_score">> => <<"low">>}),

        hg_ct_fixture:construct_contract_template(?tmpl(1), ?trms(1)),

        hg_ct_fixture:construct_system_account_set(?sas(1)),
        hg_ct_fixture:construct_external_account_set(?eas(1)),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                default_contract_template = {value, ?tmpl(1)},
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
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = TermSet
                    }
                ]
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                abs_account = <<"1234567890">>,
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
                            ]}
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
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"visa-ref">>), <<"visa payment system">>)
    ].
