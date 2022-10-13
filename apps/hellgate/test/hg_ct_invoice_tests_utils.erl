-module(hg_ct_invoice_tests_utils).

-include("hg_ct_domain.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("hellgate/include/invoice_events.hrl").
-include_lib("hellgate/include/payment_events.hrl").

-export([start_proxies/1]).

-export([make_payment_params/1]).
-export([make_payment_params/2]).
-export([make_payment_params/3]).
-export([make_wallet_payment_params/1]).

-export([start_and_check_invoice/4]).
-export([start_and_check_invoice/5]).
-export([start_and_check_invoice/6]).
-export([create_invoice/2]).
-export([next_event/2]).
-export([next_event/3]).

-export([get_payment_cost/3]).
-export([process_payment/3]).
-export([process_payment/4]).
-export([start_payment/3]).
-export([execute_payment/3]).
-export([start_payment_ev/2]).
-export([await_payment_capture/3]).
-export([await_payment_capture/4]).
-export([await_payment_capture/5]).
-export([await_payment_capture_finish/5]).
-export([await_payment_capture_finish/6]).
-export([await_payment_capture_finish/7]).
-export([await_payment_session_started/4]).
-export([await_payment_process_finish/3]).
-export([await_payment_process_finish/4]).
-export([await_sessions_restarts/5]).
-export([await_payment_cash_flow/3]).
-export([await_payment_cash_flow/5]).

-export([construct_ta_context/3]).
-export([get_cashflow_volume/4]).
-export([convert_transaction_account/2]).

-define(invoice(ID), #domain_Invoice{id = ID}).
-define(payment(ID), #domain_InvoicePayment{id = ID}).
-define(invoice_state(Invoice), #payproc_Invoice{invoice = Invoice}).
-define(invoice_w_status(Status), #domain_Invoice{status = Status}).
-define(payment_w_status(Status), #domain_InvoicePayment{status = Status}).
-define(payment_state(Payment), #payproc_InvoicePayment{payment = Payment}).
-define(trx_info(ID), #domain_TransactionInfo{id = ID}).

-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type party_id() :: dmsl_domain_thrift:'PartyID'().
-type shop_id() :: dmsl_domain_thrift:'ShopID'().
-type route() :: dmsl_domain_thrift:'PaymentRoute'().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type amount() :: dmsl_domain_thrift:'Amount'().
-type cart() :: dmsl_domain_thrift:'InvoiceCart'().
-type cash_flow() :: dmsl_domain_thrift:'FinalCashFlow'().
-type cash_flow_account() :: dmsl_domain_thrift:'CashFlowAccount'().
-type transaction_account() :: dmsl_domain_thrift:'TransactionAccount'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type payment_session_id() :: dmsl_domain_thrift:'PaymentSessionID'().
-type invoice_payment_params_flow() :: instant | {hold, dmsl_domain_thrift:'OnHoldExpiration'()}.
-type invoice_payment_params() :: dmsl_payproc_thrift:'InvoicePaymentParams'().
-type invoice_params() :: dmsl_payproc_thrift:'InvoiceParams'().
-type target_status() :: dmsl_domain_thrift:'TargetInvoicePaymentStatus'().
-type risk_score() :: dmsl_domain_thrift:'RiskScore'().
-type timestamp() :: integer().

-spec start_proxies(list()) -> ok.
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

start_service_handler(Module, C, HandlerOpts) ->
    start_service_handler(Module, Module, C, HandlerOpts).

start_service_handler(Name, Module, C, HandlerOpts) ->
    IP = "127.0.0.1",
    Port = get_random_port(),
    Opts = maps:merge(HandlerOpts, #{hellgate_root_url => hg_ct_helper:cfg(root_url, C)}),
    ChildSpec = hg_test_proxy:get_child_spec(Name, Module, IP, Port, Opts),
    {ok, _} = supervisor:start_child(hg_ct_helper:cfg(test_sup, C), ChildSpec),
    hg_test_proxy:get_url(Module, IP, Port).

get_random_port() ->
    rand:uniform(32768) + 32767.

-spec make_payment_params(hg_dummy_provider:payment_system()) -> invoice_payment_params().
make_payment_params(PmtSys) ->
    make_payment_params(PmtSys, instant).

-spec make_payment_params(hg_dummy_provider:payment_system(), invoice_payment_params_flow()) ->
    invoice_payment_params().
make_payment_params(PmtSys, FlowType) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    make_payment_params(PaymentTool, Session, FlowType).

-spec make_payment_params(payment_tool(), payment_session_id(), invoice_payment_params_flow()) ->
    invoice_payment_params().
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
                contact_info = #domain_ContactInfo{}
            }},
        flow = Flow
    }.

-spec make_wallet_payment_params(hg_dummy_provider:payment_system()) -> invoice_payment_params().
make_wallet_payment_params(PmtSrv) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(digital_wallet, PmtSrv),
    make_payment_params(PaymentTool, Session, instant).

-spec start_and_check_invoice(binary(), timestamp(), amount(), ct_suite:ct_config()) -> invoice_id().
start_and_check_invoice(Product, Due, Amount, C) ->
    start_and_check_invoice(hg_ct_helper:cfg(shop_id, C), Product, Due, Amount, C).

-spec start_and_check_invoice(shop_id(), binary(), timestamp(), amount(), ct_suite:ct_config()) -> invoice_id().
start_and_check_invoice(ShopID, Product, Due, Amount, C) ->
    Client = hg_ct_helper:cfg(client, C),
    PartyID = hg_ct_helper:cfg(party_id, C),
    start_and_check_invoice(PartyID, ShopID, Product, Due, Amount, Client).

-spec start_and_check_invoice(party_id(), shop_id(), binary(), timestamp(), amount(), pid()) -> invoice_id().
start_and_check_invoice(PartyID, ShopID, Product, Due, Amount, Client) ->
    InvoiceParams =
        hg_ct_helper:make_invoice_params(PartyID, ShopID, Product, Due, hg_ct_helper:make_cash(Amount, <<"RUB">>)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    [?invoice_created(?invoice_w_status(?invoice_unpaid()))] = next_event(InvoiceID, Client),
    InvoiceID.

-spec create_invoice(invoice_params(), pid()) -> invoice_id().
create_invoice(InvoiceParams, Client) ->
    ?invoice_state(?invoice(InvoiceID)) = hg_client_invoicing:create(InvoiceParams, Client),
    InvoiceID.

-spec next_event(invoice_id(), pid()) -> term().
next_event(InvoiceID, Client) ->
    %% timeout should be at least as large as hold expiration in construct_domain_fixture/0
    next_event(InvoiceID, 12000, Client).

-spec next_event(invoice_id(), non_neg_integer(), pid()) -> term().
next_event(InvoiceID, Timeout, Client) ->
    case hg_client_invoicing:pull_event(InvoiceID, Timeout, Client) of
        {ok, ?invoice_ev(Changes)} ->
            case filter_changes(Changes) of
                L when length(L) > 0 ->
                    L;
                [] ->
                    next_event(InvoiceID, Timeout, Client)
            end;
        Result ->
            Result
    end.

-spec get_payment_cost(invoice_id(), payment_id(), pid()) -> cash().
get_payment_cost(InvoiceID, PaymentID, Client) ->
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{cost = Cost}
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    Cost.

-spec process_payment(invoice_id(), invoice_payment_params(), pid()) -> _.
process_payment(InvoiceID, PaymentParams, Client) ->
    process_payment(InvoiceID, PaymentParams, Client, 0).

-spec process_payment(invoice_id(), invoice_payment_params(), pid(), non_neg_integer()) -> _.
process_payment(InvoiceID, PaymentParams, Client, Restarts) ->
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client, Restarts).

-spec start_payment(invoice_id(), invoice_payment_params(), pid()) -> payment_id().
start_payment(InvoiceID, PaymentParams, Client) ->
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    _ = start_payment_ev(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?cash_flow_changed(_))
    ] = next_event(InvoiceID, Client),
    PaymentID.

-spec execute_payment(invoice_id(), invoice_payment_params(), pid()) -> payment_id().
execute_payment(InvoiceID, Params, Client) ->
    PaymentID = process_payment(InvoiceID, Params, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    PaymentID.

-spec start_payment_ev(invoice_id(), pid()) -> route().
start_payment_ev(InvoiceID, Client) ->
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending())))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?risk_score_changed(_))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?route_changed(Route))
    ] = next_event(InvoiceID, Client),
    Route.

-spec await_payment_capture(invoice_id(), payment_id(), pid()) -> payment_id().
await_payment_capture(InvoiceID, PaymentID, Client) ->
    await_payment_capture(InvoiceID, PaymentID, ?timeout_reason(), Client).

-spec await_payment_capture(invoice_id(), payment_id(), binary(), pid()) -> payment_id().
await_payment_capture(InvoiceID, PaymentID, Reason, Client) ->
    await_payment_capture(InvoiceID, PaymentID, Reason, Client, 0).

-spec await_payment_capture(invoice_id(), payment_id(), binary(), pid(), non_neg_integer()) -> payment_id().
await_payment_capture(InvoiceID, PaymentID, Reason, Client, Restarts) ->
    Cost = get_payment_cost(InvoiceID, PaymentID, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cost, _, _)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost), ?session_started()))
    ] = next_event(InvoiceID, Client),
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client, Restarts).

-spec await_payment_capture_finish(invoice_id(), payment_id(), binary(), pid(), non_neg_integer()) -> payment_id().
await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client, Restarts) ->
    Cost = get_payment_cost(InvoiceID, PaymentID, Client),
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client, Restarts, Cost).

-spec await_payment_capture_finish(invoice_id(), payment_id(), binary(), pid(), non_neg_integer(), cash()) ->
    payment_id().
await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client, Restarts, Cost) ->
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client, Restarts, Cost, undefined).

-spec await_payment_capture_finish(
    invoice_id(), payment_id(), binary(), pid(), non_neg_integer(), cash(), cart() | undefined
) ->
    payment_id().
await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client, Restarts, Cost, Cart) ->
    PaymentID = await_sessions_restarts(PaymentID, ?captured(Reason, Cost, Cart), InvoiceID, Client, Restarts),
    [
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost, Cart, _), ?session_finished(?session_succeeded())))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?payment_status_changed(?captured(Reason, Cost, Cart, _))),
        ?invoice_status_changed(?invoice_paid())
    ] = next_event(InvoiceID, Client),
    PaymentID.

-spec await_payment_session_started(invoice_id(), payment_id(), pid(), target_status()) -> payment_id().
await_payment_session_started(InvoiceID, PaymentID, Client, Target) ->
    [
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_started()))
    ] = next_event(InvoiceID, Client),
    PaymentID.

-spec await_payment_process_finish(invoice_id(), payment_id(), pid()) -> payment_id().
await_payment_process_finish(InvoiceID, PaymentID, Client) ->
    await_payment_process_finish(InvoiceID, PaymentID, Client, 0).

-spec await_payment_process_finish(invoice_id(), payment_id(), pid(), non_neg_integer()) -> payment_id().
await_payment_process_finish(InvoiceID, PaymentID, Client, Restarts) ->
    PaymentID = await_sessions_restarts(PaymentID, ?processed(), InvoiceID, Client, Restarts),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(_)))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded())))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_event(InvoiceID, Client),
    PaymentID.

-spec await_sessions_restarts(payment_id(), target_status(), invoice_id(), pid(), non_neg_integer()) -> payment_id().
await_sessions_restarts(PaymentID, _Target, _InvoiceID, _Client, 0) ->
    PaymentID;
await_sessions_restarts(PaymentID, ?refunded() = Target, InvoiceID, Client, Restarts) when Restarts > 0 ->
    [
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(Target, ?session_finished(?session_failed(_))))),
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(Target, ?session_started())))
    ] = next_event(InvoiceID, Client),
    await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts - 1);
await_sessions_restarts(
    PaymentID,
    ?captured(Reason, Cost, Cart, _) = Target,
    InvoiceID,
    Client,
    Restarts
) when Restarts > 0 ->
    [
        ?payment_ev(
            PaymentID,
            ?session_ev(
                ?captured(Reason, Cost, Cart, _),
                ?session_finished(?session_failed(_))
            )
        ),
        ?payment_ev(
            PaymentID,
            ?session_ev(?captured(Reason, Cost, Cart, _), ?session_started())
        )
    ] = next_event(InvoiceID, Client),
    await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts - 1);
await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts) when Restarts > 0 ->
    [
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_finished(?session_failed(_)))),
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_started()))
    ] = next_event(InvoiceID, Client),
    await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts - 1).

-spec await_payment_cash_flow(invoice_id(), payment_id(), pid()) -> {cash_flow(), route()}.
await_payment_cash_flow(InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?risk_score_changed(_))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?route_changed(Route))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?cash_flow_changed(CashFlow))
    ] = next_event(InvoiceID, Client),
    {CashFlow, Route}.

-spec await_payment_cash_flow(risk_score(), route(), invoice_id(), payment_id(), pid()) -> cash_flow().
await_payment_cash_flow(RS, Route, InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?risk_score_changed(RS))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?route_changed(Route))
    ] = next_event(InvoiceID, Client),
    [
        ?payment_ev(PaymentID, ?cash_flow_changed(CashFlow))
    ] = next_event(InvoiceID, Client),
    CashFlow.

-spec construct_ta_context(party_id(), shop_id(), route()) -> map().
construct_ta_context(PartyID, ShopID, Route) ->
    #{
        party => PartyID,
        shop => ShopID,
        route => Route
    }.

-spec get_cashflow_volume(cash_flow_account(), cash_flow_account(), cash_flow(), map()) -> cash().
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

-spec convert_transaction_account(cash_flow_account(), map()) -> transaction_account().
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

%% internal

filter_changes(Changes) ->
    lists:filtermap(fun filter_change/1, Changes).

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
