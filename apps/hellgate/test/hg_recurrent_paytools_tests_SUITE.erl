-module(hg_recurrent_paytools_tests_SUITE).

-include_lib("stdlib/include/assert.hrl").

-include("hg_ct_domain.hrl").
-include("hg_ct_json.hrl").

-include_lib("hellgate/include/customer_events.hrl").
-include_lib("hellgate/include/recurrent_payment_tools.hrl").

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
-export([invalid_payment_method/1]).

-export([get_recurrent_paytool/1]).
-export([recurrent_paytool_not_found/1]).
-export([recurrent_paytool_abandoned/1]).
-export([recurrent_paytool_acquirement_failed/1]).
-export([recurrent_paytool_acquired/1]).
-export([recurrent_paytool_cost/1]).
-export([recurrent_paytool_w_tds_acquired/1]).

-export([recurrent_paytool_creation_not_permitted/1]).

%%

-behaviour(supervisor).

-export([init/1]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

%%

-define(MINIMAL_PAYMENT_COST_CURRENCY, <<"RUB">>).
-define(MINIMAL_PAYMENT_COST_AMOUNT, 1000).

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
    [application:stop(App) || App <- cfg(apps, C)],
    _ = hg_progressor:cleanup().

-spec all() -> [test_case_name()].
all() ->
    [
        {group, invalid_recurrent_paytool_params},
        recurrent_paytool_not_found,
        get_recurrent_paytool,
        recurrent_paytool_acquirement_failed,
        recurrent_paytool_acquired,
        recurrent_paytool_cost,
        recurrent_paytool_w_tds_acquired,
        recurrent_paytool_abandoned,
        recurrent_paytool_creation_not_permitted
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {invalid_recurrent_paytool_params, [sequence], [
            invalid_party,
            invalid_shop,
            invalid_party_status,
            invalid_shop_status,
            invalid_payment_method
        ]}
    ].

%%

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) ->
    RootUrl = cfg(root_url, C),
    TraceID = hg_ct_helper:make_trace_id(Name),
    Client = hg_client_recurrent_paytool:start(hg_ct_helper:create_client(RootUrl, TraceID)),
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

-define(trx_info(ID), #domain_TransactionInfo{id = ID}).

%% invalid_recurrent_paytool_params group

-spec invalid_party(config()) -> test_case_result().
-spec invalid_shop(config()) -> test_case_result().
-spec invalid_party_status(config()) -> test_case_result().
-spec invalid_shop_status(config()) -> test_case_result().
-spec invalid_payment_method(config()) -> test_case_result().

invalid_party(C) ->
    RootUrl = cfg(root_url, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = hg_utils:unique_id(),
    ShopID = hg_utils:unique_id(),
    Client = hg_client_recurrent_paytool:start(hg_ct_helper:create_client(RootUrl, cfg(trace_id, C))),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    {exception, #payproc_PartyNotFound{}} = hg_client_recurrent_paytool:create(Params, Client).

invalid_shop(C) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = hg_utils:unique_id(),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    {exception, #payproc_ShopNotFound{}} = hg_client_recurrent_paytool:create(Params, Client).

invalid_party_status(C) ->
    Client = cfg(client, C),
    {PartyClient, Context} = cfg(party_client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    ok = party_client_thrift:block(PartyID, <<>>, PartyClient, Context),
    {exception, ?invalid_party_status({blocking, _})} = hg_client_recurrent_paytool:create(Params, Client),
    ok = party_client_thrift:unblock(PartyID, <<>>, PartyClient, Context),
    ok = party_client_thrift:suspend(PartyID, PartyClient, Context),
    {exception, ?invalid_party_status({suspension, _})} = hg_client_recurrent_paytool:create(Params, Client),
    ok = party_client_thrift:activate(PartyID, PartyClient, Context).

invalid_shop_status(C) ->
    Client = cfg(client, C),
    {PartyClient, Context} = cfg(party_client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    ok = party_client_thrift:block_shop(PartyID, ShopID, <<>>, PartyClient, Context),
    {exception, ?invalid_shop_status({blocking, _})} = hg_client_recurrent_paytool:create(Params, Client),
    ok = party_client_thrift:unblock_shop(PartyID, ShopID, <<>>, PartyClient, Context),
    ok = party_client_thrift:suspend_shop(PartyID, ShopID, PartyClient, Context),
    {exception, ?invalid_shop_status({suspension, _})} = hg_client_recurrent_paytool:create(Params, Client),
    ok = party_client_thrift:activate_shop(PartyID, ShopID, PartyClient, Context).

invalid_payment_method(C) ->
    Fun = fun(BCard) -> BCard#domain_BankCard{payment_system = ?pmt_sys(<<"mastercard-ref">>)} end,
    invalid_payment_method(C, Fun).

invalid_payment_method(C, BCardFun) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    BCard = #domain_BankCard{
        token = <<"TOKEN">>,
        bin = <<"666666">>,
        last_digits = <<"666">>
    },
    PaymentResource = make_disposable_payment_resource({bank_card, BCardFun(BCard)}, <<"SESSION0">>),
    Params = #payproc_RecurrentPaymentToolParams{
        id = PaytoolID,
        party_id = PartyID,
        shop_id = ShopID,
        payment_resource = PaymentResource
    },
    {exception, #payproc_InvalidPaymentMethod{}} = hg_client_recurrent_paytool:create(Params, Client).

%% recurrent_paytool_flow group

-spec recurrent_paytool_not_found(config()) -> test_case_result().
-spec get_recurrent_paytool(config()) -> test_case_result().
-spec recurrent_paytool_acquirement_failed(config()) -> test_case_result().
-spec recurrent_paytool_acquired(config()) -> test_case_result().
-spec recurrent_paytool_cost(config()) -> test_case_result().
-spec recurrent_paytool_w_tds_acquired(config()) -> test_case_result().
-spec recurrent_paytool_abandoned(config()) -> test_case_result().

recurrent_paytool_not_found(C) ->
    PaytoolID = hg_utils:unique_id(),
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    _RecurrentPaytool = hg_client_recurrent_paytool:create(Params, cfg(client, C)),
    {exception, #payproc_RecurrentPaymentToolNotFound{}} =
        hg_client_recurrent_paytool:get(hg_utils:unique_id(), Client).

get_recurrent_paytool(C) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    RecurrentPaytool = hg_client_recurrent_paytool:create(Params, cfg(client, C)),
    #payproc_RecurrentPaymentTool{id = RecurrentPaytoolID} = RecurrentPaytool,
    RecurrentPaytool = hg_client_recurrent_paytool:get(RecurrentPaytoolID, Client).

recurrent_paytool_acquirement_failed(C) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_bad_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    RecurrentPaytool = hg_client_recurrent_paytool:create(Params, cfg(client, C)),
    #payproc_RecurrentPaymentTool{id = RecurrentPaytoolID} = RecurrentPaytool,
    [
        ?recurrent_payment_tool_has_created(_),
        ?recurrent_payment_tool_risk_score_changed(_),
        ?recurrent_payment_tool_route_changed(_),
        ?session_ev(?session_started())
    ] = next_event(RecurrentPaytoolID, Client),
    ok = await_failure(RecurrentPaytoolID, Client).

recurrent_paytool_acquired(C) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    RecurrentPaytool = hg_client_recurrent_paytool:create(Params, Client),
    #payproc_RecurrentPaymentTool{id = RecurrentPaytoolID} = RecurrentPaytool,
    ok = await_acquirement(RecurrentPaytoolID, Client).

recurrent_paytool_cost(C) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    RecurrentPaytool = hg_client_recurrent_paytool:create(Params, cfg(client, C)),
    #payproc_RecurrentPaymentTool{
        id = RecurrentPaytoolID,
        minimal_payment_cost = #domain_Cash{
            amount = ?MINIMAL_PAYMENT_COST_AMOUNT,
            currency = #domain_CurrencyRef{symbolic_code = ?MINIMAL_PAYMENT_COST_CURRENCY}
        }
    } = RecurrentPaytool,
    RecurrentPaytool2 = RecurrentPaytool#payproc_RecurrentPaymentTool{route = undefined},
    [
        ?recurrent_payment_tool_has_created(RecurrentPaytool2),
        ?recurrent_payment_tool_risk_score_changed(_),
        ?recurrent_payment_tool_route_changed(_),
        ?session_ev(?session_started())
    ] = next_event(RecurrentPaytoolID, Client),
    ok = await_acquirement_finish(RecurrentPaytoolID, Client).

recurrent_paytool_w_tds_acquired(C) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_tds_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    RecurrentPaytool = hg_client_recurrent_paytool:create(Params, cfg(client, C)),
    #payproc_RecurrentPaymentTool{id = RecurrentPaytoolID} = RecurrentPaytool,
    [
        ?recurrent_payment_tool_has_created(_),
        ?recurrent_payment_tool_risk_score_changed(_),
        ?recurrent_payment_tool_route_changed(_),
        ?session_ev(?session_started())
    ] = next_event(RecurrentPaytoolID, Client),
    [
        ?session_ev(?interaction_changed(UserInteraction, ?interaction_requested))
    ] = next_event(RecurrentPaytoolID, Client),
    _ = assert_success_interaction(UserInteraction),
    [
        ?session_ev(?interaction_changed(UserInteraction, ?interaction_completed))
    ] = next_event(RecurrentPaytoolID, Client),
    [
        ?session_ev(?trx_bound(?trx_info(_))),
        ?session_ev(?session_finished(?session_succeeded())),
        ?recurrent_payment_tool_has_acquired(_)
    ] = next_event(RecurrentPaytoolID, Client).

recurrent_paytool_abandoned(C) ->
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    #payproc_RecurrentPaymentTool{id = RecurrentPaytoolID} =
        hg_client_recurrent_paytool:create(Params, cfg(client, C)),
    {exception, #payproc_InvalidRecurrentPaymentToolStatus{status = {created, _}}} =
        hg_client_recurrent_paytool:abandon(RecurrentPaytoolID, Client),
    ok = await_acquirement(RecurrentPaytoolID, Client),
    #payproc_RecurrentPaymentTool{id = RecurrentPaytoolID, status = {abandoned, _}} =
        hg_client_recurrent_paytool:abandon(RecurrentPaytoolID, Client),
    [
        ?recurrent_payment_tool_has_abandoned()
    ] = next_event(RecurrentPaytoolID, Client).

%%

-spec recurrent_paytool_creation_not_permitted(config()) -> test_case_result().

recurrent_paytool_creation_not_permitted(C) ->
    _ = hg_domain:upsert(construct_domain_fixture(construct_simple_term_set())),
    Client = cfg(client, C),
    PaytoolID = hg_utils:unique_id(),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    Params = make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, ?pmt_sys(<<"visa-ref">>)),
    {exception, #payproc_OperationNotPermitted{}} = hg_client_recurrent_paytool:create(Params, Client).

%%

make_bad_recurrent_paytool_params(PaytoolID, PartyID, ShopID, PmtSys) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(forbidden, PmtSys),
    PaymentResource = make_disposable_payment_resource(PaymentTool, Session),
    #payproc_RecurrentPaymentToolParams{
        id = PaytoolID,
        party_id = PartyID,
        shop_id = ShopID,
        payment_resource = PaymentResource
    }.

make_recurrent_paytool_params(PaytoolID, PartyID, ShopID, PmtSys) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    PaymentResource = make_disposable_payment_resource(PaymentTool, Session),
    #payproc_RecurrentPaymentToolParams{
        id = PaytoolID,
        party_id = PartyID,
        shop_id = ShopID,
        payment_resource = PaymentResource
    }.

make_tds_recurrent_paytool_params(PaytoolID, PartyID, ShopID, PmtSys) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(preauth_3ds, PmtSys),
    PaymentResource = make_disposable_payment_resource(PaymentTool, Session),
    #payproc_RecurrentPaymentToolParams{
        id = PaytoolID,
        party_id = PartyID,
        shop_id = ShopID,
        payment_resource = PaymentResource
    }.

make_disposable_payment_resource(PaymentTool, Session) ->
    #domain_DisposablePaymentResource{
        payment_tool = PaymentTool,
        payment_session_id = Session,
        client_info = #domain_ClientInfo{}
    }.

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

-spec start_service_handler(module(), list(), map()) -> binary().
start_service_handler(Module, C, HandlerOpts) ->
    start_service_handler(Module, Module, C, HandlerOpts).

-spec start_service_handler(atom(), module(), list(), map()) -> binary().
start_service_handler(Name, Module, C, HandlerOpts) ->
    IP = "127.0.0.1",
    Port = get_random_port(),
    Opts = maps:merge(HandlerOpts, #{hellgate_root_url => cfg(root_url, C)}),
    ChildSpec = hg_test_proxy:get_child_spec(Name, Module, IP, Port, Opts),
    {ok, _} = supervisor:start_child(cfg(test_sup, C), ChildSpec),
    hg_test_proxy:get_url(Module, IP, Port).

-spec get_random_port() -> inet:port_number().
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

await_acquirement(RecurrentPaytoolID, Client) ->
    [
        ?recurrent_payment_tool_has_created(_),
        ?recurrent_payment_tool_risk_score_changed(_),
        ?recurrent_payment_tool_route_changed(_),
        ?session_ev(?session_started())
    ] = next_event(RecurrentPaytoolID, Client),
    await_acquirement_finish(RecurrentPaytoolID, Client).

await_acquirement_finish(RecurrentPaytoolID, Client) ->
    [
        ?session_ev(?trx_bound(?trx_info(_))),
        ?session_ev(?session_finished(?session_succeeded())),
        ?recurrent_payment_tool_has_acquired(_)
    ] = next_event(RecurrentPaytoolID, Client),
    ok.

await_failure(RecurrentPaytoolID, Client) ->
    [
        ?session_ev(?session_finished(?session_failed(_))),
        ?recurrent_payment_tool_has_failed(_)
    ] = next_event(RecurrentPaytoolID, Client),
    ok.

next_event(RecurrentPaytoolID, Client) ->
    next_event(RecurrentPaytoolID, 5000, Client).

next_event(RecurrentPaytoolID, Timeout, Client) ->
    {ok, Changes} = hg_client_recurrent_paytool:pull_event(RecurrentPaytoolID, Timeout, Client),
    case filter_changes(Changes) of
        L when length(L) > 0 ->
            L;
        [] ->
            next_event(RecurrentPaytoolID, Timeout, Client)
    end.

filter_changes(Changes) ->
    lists:filtermap(fun filter_change/1, Changes).

filter_change(?session_ev(?proxy_st_changed(_))) ->
    false;
filter_change(?session_ev(?session_suspended())) ->
    false;
filter_change(?session_ev(?session_activated())) ->
    false;
filter_change(_) ->
    true.

%%

assert_success_interaction(Req) ->
    {ok, 200, _RespHeaders, _ClientRef} = post_request(Req).

post_request(?redirect(URL, Form)) ->
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
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                        ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
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
                name = <<"Prohibitions: all is allow">>,
                decisions = {candidates, []}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"Prohibitions: all is allow">>,
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
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
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
                        cash_value =
                            {decisions, [
                                #domain_CashValueDecision{
                                    if_ = {condition, {currency_is, ?cur(?MINIMAL_PAYMENT_COST_CURRENCY)}},
                                    then_ = {value, ?cash(?MINIMAL_PAYMENT_COST_AMOUNT, ?MINIMAL_PAYMENT_COST_CURRENCY)}
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
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"visa-ref">>), <<"visa payment system">>),
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"mastercard-ref">>), <<"mastercard payment system">>)
    ].
