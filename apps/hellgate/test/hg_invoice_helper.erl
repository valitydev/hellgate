-module(hg_invoice_helper).

-include("hg_ct_invoice.hrl").
-include("hg_ct_domain.hrl").

-define(DEFAULT_NEXT_CHANGE_TIMEOUT, 12000).

%%
-export([
    start_kv_store/1,
    stop_kv_store/1,
    start_proxies/1
]).

-export([
    make_due_date/1,
    start_invoice/4,
    start_invoice/5,
    start_invoice/6,
    next_changes/3,
    next_change/2,
    next_change/3,
    make_payment_params/1,
    make_payment_params/2,
    make_payment_params/3,
    register_payment/4,
    start_payment/3,
    start_payment_ev/2,
    register_payment_ev_no_risk_scoring/2,
    await_payment_session_started/4,
    await_payment_capture/3,
    await_payment_capture/4,
    await_payment_capture/5,
    await_payment_capture_finish/4,
    await_payment_capture_finish/5,
    await_payment_capture_finish/6,
    await_payment_cash_flow/3,
    await_payment_process_finish/3,
    construct_ta_context/3,
    convert_transaction_account/2,
    get_cashflow_volume/4,
    make_wallet_payment_params/1,
    execute_payment/3,
    process_payment/3,
    get_payment_cost/3,
    make_cash/1,
    make_cash/2,
    make_customer_w_rec_tool/4
]).

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

%% init helpers
-spec start_kv_store(_) -> _.
start_kv_store(SupPid) ->
    ChildSpec = #{
        id => hg_kv_store,
        start => {hg_kv_store, start_link, [[]]},
        restart => permanent,
        shutdown => 2000,
        type => worker,
        modules => [hg_kv_store]
    },
    {ok, _} = supervisor:start_child(SupPid, ChildSpec),
    ok.

-spec stop_kv_store(_) -> _.
stop_kv_store(SupPid) ->
    _ = supervisor:terminate_child(SupPid, hg_kv_store),
    ok.

-spec start_proxies(_) -> _.
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

start_service_handler(Module, C, HandlerOpts) ->
    start_service_handler(Module, Module, C, HandlerOpts).

start_service_handler(Name, Module, C, HandlerOpts) ->
    IP = "127.0.0.1",
    Port = get_random_port(),
    Opts = maps:merge(HandlerOpts, #{hellgate_root_url => hg_ct_helper:cfg(root_url, C)}),
    ChildSpec = hg_test_proxy:get_child_spec(Name, Module, IP, Port, Opts),
    {ok, _} = supervisor:start_child(hg_ct_helper:cfg(test_sup, C), ChildSpec),
    hg_test_proxy:get_url(Module, IP, Port).

setup_proxies(Proxies) ->
    _ = hg_domain:upsert(Proxies),
    ok.

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

get_random_port() ->
    rand:uniform(32768) + 32767.

%% Test helpers
-spec make_due_date(pos_integer()) -> pos_integer().
make_due_date(LifetimeSeconds) ->
    genlib_time:unow() + LifetimeSeconds.

-spec make_cash(_) -> _.
make_cash(Amount) ->
    make_cash(Amount, <<"RUB">>).

-spec make_cash(_, _) -> _.
make_cash(Amount, Currency) ->
    hg_ct_helper:make_cash(Amount, Currency).

make_invoice_params(PartyID, ShopID, Product, Due, Cost) ->
    hg_ct_helper:make_invoice_params(PartyID, ShopID, Product, Due, Cost).

-spec start_invoice(_, _, _, _) -> _.
start_invoice(Product, Due, Amount, C) ->
    start_invoice(cfg(shop_id, C), Product, Due, Amount, C).

-spec start_invoice(_, _, _, _, _) -> _.
start_invoice(ShopID, Product, Due, Amount, C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    start_invoice(PartyID, ShopID, Product, Due, Amount, Client).

-spec start_invoice(_, _, _, _, _, _) -> _.
start_invoice(PartyID, ShopID, Product, Due, Amount, Client) ->
    InvoiceParams = make_invoice_params(PartyID, ShopID, Product, Due, make_cash(Amount)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),
    InvoiceID.

create_invoice(InvoiceParams, Client) ->
    ?invoice_state(?invoice(InvoiceID)) = hg_client_invoicing:create(InvoiceParams, Client),
    InvoiceID.

-spec next_change(_, _) -> _.
next_change(InvoiceID, Client) ->
    %% timeout should be at least as large as hold expiration in construct_domain_fixture/0
    next_change(InvoiceID, ?DEFAULT_NEXT_CHANGE_TIMEOUT, Client).

-spec next_change(_, _, _) -> _.
next_change(InvoiceID, Timeout, Client) ->
    hg_client_invoicing:pull_change(InvoiceID, fun filter_change/1, Timeout, Client).

filter_change(?payment_ev(_, C)) ->
    filter_change(C);
filter_change(?chargeback_ev(_, C)) ->
    filter_change(C);
filter_change(?refund_ev(_, C)) ->
    filter_change(C);
filter_change(?session_ev(_, ?proxy_st_changed(_))) ->
    false;
filter_change(?session_ev(_, ?session_suspended(_, _))) ->
    false;
filter_change(?session_ev(_, ?session_activated())) ->
    false;
filter_change(_) ->
    true.

-spec next_changes(_, _, _) -> _.
next_changes(InvoiceID, Amount, Client) ->
    next_changes(InvoiceID, Amount, ?DEFAULT_NEXT_CHANGE_TIMEOUT, Client).

next_changes(InvoiceID, Amount, Timeout, Client) ->
    TimeoutTime = erlang:monotonic_time(millisecond) + Timeout,
    next_changes_(InvoiceID, Amount, TimeoutTime, Client).

next_changes_(InvoiceID, Amount, Timeout, Client) ->
    Result = lists:foldl(
        fun(_N, Acc) ->
            case erlang:monotonic_time(millisecond) of
                Time when Time < Timeout ->
                    [next_change(InvoiceID, Client) | Acc];
                _ ->
                    [{error, timeout} | Acc]
            end
        end,
        [],
        lists:seq(1, Amount)
    ),
    lists:reverse(Result).

-spec make_payment_params(_) -> _.
make_payment_params(PmtSys) ->
    make_payment_params(PmtSys, instant).

-spec make_payment_params(_, _) -> _.
make_payment_params(PmtSys, FlowType) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    make_payment_params(PaymentTool, Session, FlowType).

-spec make_payment_params(_, _, _) -> _.
make_payment_params(PaymentTool, Session, FlowType) ->
    Flow =
        case FlowType of
            instant ->
                {instant, #payproc_InvoicePaymentParamsFlowInstant{}};
            {hold, OnHoldExpiration} ->
                {hold, #payproc_InvoicePaymentParamsFlowHold{on_hold_expiration = OnHoldExpiration}}
        end,
    #payproc_InvoicePaymentParams{
        payer =
            {payment_resource, #payproc_PaymentResourcePayerParams{
                resource = #domain_DisposablePaymentResource{
                    payment_tool = PaymentTool,
                    payment_session_id = Session,
                    client_info = #domain_ClientInfo{}
                },
                contact_info = ?contact_info()
            }},
        flow = Flow
    }.

-spec register_payment(_, _, _, _) -> _.
register_payment(InvoiceID, RegisterPaymentParams, WithRiskScoring, Client) ->
    ?payment_state(?payment(PaymentID)) =
        hg_client_invoicing:register_payment(InvoiceID, RegisterPaymentParams, Client),
    _ =
        case WithRiskScoring of
            true ->
                start_payment_ev(InvoiceID, Client);
            false ->
                register_payment_ev_no_risk_scoring(InvoiceID, Client)
        end,
    ?payment_ev(PaymentID, ?cash_flow_changed(_)) =
        next_change(InvoiceID, Client),
    PaymentID.

-spec start_payment(_, _, _) -> _.
start_payment(InvoiceID, PaymentParams, Client) ->
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    _ = start_payment_ev(InvoiceID, Client),
    ?payment_ev(PaymentID, ?cash_flow_changed(_)) =
        next_change(InvoiceID, Client),
    PaymentID.

-spec start_payment_ev(_, _) -> _.
start_payment_ev(InvoiceID, Client) ->
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))),
        ?payment_ev(PaymentID, ?shop_limit_initiated()),
        ?payment_ev(PaymentID, ?shop_limit_applied()),
        ?payment_ev(PaymentID, ?risk_score_changed(_RiskScore)),
        ?payment_ev(PaymentID, ?route_changed(Route))
    ] = next_changes(InvoiceID, 5, Client),
    Route.

-spec register_payment_ev_no_risk_scoring(_, _) -> _.
register_payment_ev_no_risk_scoring(InvoiceID, Client) ->
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))),
        ?payment_ev(PaymentID, ?shop_limit_initiated()),
        ?payment_ev(PaymentID, ?shop_limit_applied()),
        ?payment_ev(PaymentID, ?route_changed(Route))
    ] = next_changes(InvoiceID, 4, Client),
    Route.

-spec await_payment_session_started(_, _, _, _) -> _.
await_payment_session_started(InvoiceID, PaymentID, Client, Target) ->
    ?payment_ev(PaymentID, ?session_ev(Target, ?session_started())) =
        next_change(InvoiceID, Client),
    PaymentID.

-spec await_payment_capture(_, _, _) -> _.
await_payment_capture(InvoiceID, PaymentID, Client) ->
    await_payment_capture(InvoiceID, PaymentID, ?timeout_reason(), Client).

-spec await_payment_capture(_, _, _, _) -> _.
await_payment_capture(InvoiceID, PaymentID, Reason, Client) ->
    await_payment_capture(InvoiceID, PaymentID, Reason, undefined, Client).

-spec await_payment_capture(_, _, _, _, _) -> _.
await_payment_capture(InvoiceID, PaymentID, Reason, TrxID, Client) ->
    Cost = get_payment_cost(InvoiceID, PaymentID, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cost, _, _)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost), ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),
    TrxID =/= undefined andalso
        (?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost, _Cart, _), ?trx_bound(?trx_info(TrxID)))) =
            next_change(InvoiceID, Client)),
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client).

-spec get_payment_cost(_, _, _) -> _.
get_payment_cost(InvoiceID, PaymentID, Client) ->
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{cost = Cost}
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    Cost.

-spec await_payment_capture_finish(_, _, _, _) -> _.
await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client) ->
    Cost = get_payment_cost(InvoiceID, PaymentID, Client),
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, Client).

-spec await_payment_capture_finish(_, _, _, _, _) -> _.
await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, Client) ->
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, undefined, Client).

-spec await_payment_capture_finish(_, _, _, _, _, _) -> _.
await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, Cart, Client) ->
    [
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost, Cart, _), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?captured(Reason, Cost, Cart, _))),
        ?invoice_status_changed(?invoice_paid())
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID.

-spec await_payment_cash_flow(_, _, _) -> _.
await_payment_cash_flow(InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?shop_limit_initiated()),
        ?payment_ev(PaymentID, ?shop_limit_applied()),
        ?payment_ev(PaymentID, ?risk_score_changed(_)),
        ?payment_ev(PaymentID, ?route_changed(Route)),
        ?payment_ev(PaymentID, ?cash_flow_changed(CashFlow))
    ] = next_changes(InvoiceID, 5, Client),
    {CashFlow, Route}.

-spec construct_ta_context(_, _, _) -> _.
construct_ta_context(Party, Shop, Route) ->
    #{
        party => Party,
        shop => Shop,
        route => Route
    }.

-spec get_cashflow_volume(_, _, _, _) -> _.
get_cashflow_volume(Source, Destination, CF, CFContext) ->
    TAS = convert_transaction_account(Source, CFContext),
    TAD = convert_transaction_account(Destination, CFContext),
    [Volume] = [
        V
     || #domain_FinalCashFlowPosting{
            source = #domain_FinalCashFlowAccount{
                account_type = ST,
                transaction_account = SA
            },
            destination = #domain_FinalCashFlowAccount{
                account_type = DT,
                transaction_account = DA
            },
            volume = V
        } <- CF,
        ST == Source,
        DT == Destination,
        SA == TAS,
        DA == TAD
    ],
    Volume.

-spec convert_transaction_account(_, _) -> _.
convert_transaction_account({merchant, Type}, #{party := Party, shop := Shop}) ->
    {merchant, #domain_MerchantTransactionAccount{
        type = Type,
        owner = #domain_MerchantTransactionAccountOwner{
            party_id = Party,
            shop_id = Shop
        }
    }};
convert_transaction_account({provider, Type}, #{route := Route}) ->
    #domain_PaymentRoute{
        provider = ProviderRef,
        terminal = TerminalRef
    } = Route,
    {provider, #domain_ProviderTransactionAccount{
        type = Type,
        owner = #domain_ProviderTransactionAccountOwner{
            provider_ref = ProviderRef,
            terminal_ref = TerminalRef
        }
    }};
convert_transaction_account({system, Type}, _Context) ->
    {system, #domain_SystemTransactionAccount{
        type = Type
    }};
convert_transaction_account({external, Type}, _Context) ->
    {external, #domain_ExternalTransactionAccount{
        type = Type
    }}.

-spec make_wallet_payment_params(_) -> _.
make_wallet_payment_params(PmtSrv) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(digital_wallet, PmtSrv),
    make_payment_params(PaymentTool, Session, instant).

-spec execute_payment(_, _, _) -> _.
execute_payment(InvoiceID, Params, Client) ->
    PaymentID = process_payment(InvoiceID, Params, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    PaymentID.

-spec process_payment(_, _, _) -> _.
process_payment(InvoiceID, PaymentParams, Client) ->
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client).

-spec await_payment_process_finish(_, _, _) -> _.
await_payment_process_finish(InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(_)))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID.

-spec make_customer_w_rec_tool(_, _, _, _) -> _.
make_customer_w_rec_tool(PartyID, ShopID, Client, PmtSys) ->
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, <<"InvoicingTests">>),
    #payproc_Customer{id = CustomerID} =
        hg_client_customer:create(CustomerParams, Client),
    #payproc_CustomerBinding{id = BindingID} =
        hg_client_customer:start_binding(
            CustomerID,
            hg_ct_helper:make_customer_binding_params(hg_dummy_provider:make_payment_tool(no_preauth, PmtSys)),
            Client
        ),
    ok = wait_for_binding_success(CustomerID, BindingID, Client),
    CustomerID.

wait_for_binding_success(CustomerID, BindingID, Client) ->
    wait_for_binding_success(CustomerID, BindingID, 20000, Client).

wait_for_binding_success(CustomerID, BindingID, TimeLeft, Client) when TimeLeft > 0 ->
    Target = ?customer_binding_changed(BindingID, ?customer_binding_status_changed(?customer_binding_succeeded())),
    Started = genlib_time:ticks(),
    Event = hg_client_customer:pull_event(CustomerID, Client),
    R =
        case Event of
            {ok, ?customer_event(Changes)} ->
                lists:member(Target, Changes);
            _ ->
                false
        end,
    case R of
        true ->
            ok;
        false ->
            timer:sleep(200),
            Now = genlib_time:ticks(),
            TimeLeftNext = TimeLeft - (Now - Started) div 1000,
            wait_for_binding_success(CustomerID, BindingID, TimeLeftNext, Client)
    end;
wait_for_binding_success(_, _, _, _) ->
    timeout.
