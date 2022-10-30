-module(hg_client_invoicing).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("hellgate/include/invoice_events.hrl").

-export([start/1]).
-export([start_link/1]).
-export([stop/1]).

-export([create/2]).
-export([create_with_tpl/2]).
-export([get/2]).
-export([get/3]).
-export([fulfill/3]).
-export([rescind/3]).
-export([repair/5]).
-export([repair_scenario/3]).

-export([create_invoice_adjustment/3]).
-export([get_invoice_adjustment/3]).

-export([start_payment/3]).
-export([register_payment/3]).
-export([get_payment/3]).
-export([cancel_payment/4]).
-export([capture_payment/4]).
-export([capture_payment/5]).
-export([capture_payment/6]).
-export([capture_payment/7]).

-export([refund_payment/4]).
-export([refund_payment_manual/4]).
-export([get_payment_refund/4]).

-export([create_chargeback/4]).
-export([cancel_chargeback/5]).
-export([reject_chargeback/5]).
-export([accept_chargeback/5]).
-export([reopen_chargeback/5]).
-export([get_payment_chargeback/4]).

-export([create_payment_adjustment/4]).
-export([get_payment_adjustment/4]).

-export([compute_terms/3]).

-export([pull_event/2]).
-export([pull_event/3]).
-export([pull_change/4]).

%% GenServer

-behaviour(gen_server).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%%

-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type invoice_state() :: dmsl_payproc_thrift:'Invoice'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type payment_st() :: dmsl_payproc_thrift:'InvoicePayment'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type invoice_params() :: dmsl_payproc_thrift:'InvoiceParams'().
-type invoice_params_tpl() :: dmsl_payproc_thrift:'InvoiceWithTemplateParams'().

-type invoice_adjustment() :: dmsl_domain_thrift:'InvoiceAdjustment'().
-type invoice_adjustment_params() :: dmsl_payproc_thrift:'InvoiceAdjustmentParams'().

-type payment_params() :: dmsl_payproc_thrift:'InvoicePaymentParams'().
-type register_payment_params() :: dmsl_payproc_thrift:'RegisterInvoicePaymentParams'().

-type payment_adjustment() :: dmsl_domain_thrift:'InvoicePaymentAdjustment'().
-type payment_adjustment_id() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentID'().
-type payment_adjustment_params() :: dmsl_payproc_thrift:'InvoicePaymentAdjustmentParams'().

-type refund() :: dmsl_domain_thrift:'InvoicePaymentRefund'().
-type refund_id() :: dmsl_domain_thrift:'InvoicePaymentRefundID'().
-type refund_params() :: dmsl_payproc_thrift:'InvoicePaymentRefundParams'().

-type chargeback() :: dmsl_domain_thrift:'InvoicePaymentChargeback'().
-type chargeback_id() :: dmsl_domain_thrift:'InvoicePaymentChargebackID'().
-type chargeback_params() :: dmsl_payproc_thrift:'InvoicePaymentChargebackParams'().
-type chargeback_cancel_params() :: dmsl_payproc_thrift:'InvoicePaymentChargebackCancelParams'().
-type chargeback_accept_params() :: dmsl_payproc_thrift:'InvoicePaymentChargebackAcceptParams'().
-type chargeback_reject_params() :: dmsl_payproc_thrift:'InvoicePaymentChargebackRejectParams'().
-type chargeback_reopen_params() :: dmsl_payproc_thrift:'InvoicePaymentChargebackReopenParams'().

-type term_set() :: dmsl_domain_thrift:'TermSet'().
-type cash() :: undefined | dmsl_domain_thrift:'Cash'().
-type cart() :: undefined | dmsl_domain_thrift:'InvoiceCart'().
-type allocation_prototype() :: undefined | dmsl_domain_thrift:'AllocationPrototype'().
-type event_range() :: dmsl_payproc_thrift:'EventRange'().
-type party_revision_param() :: dmsl_payproc_thrift:'PartyRevisionParam'().

-spec start(hg_client_api:t()) -> pid().
start(ApiClient) ->
    start(start, ApiClient).

-spec start_link(hg_client_api:t()) -> pid().
start_link(ApiClient) ->
    start(start_link, ApiClient).

start(Mode, ApiClient) ->
    {ok, Pid} = gen_server:Mode(?MODULE, ApiClient, []),
    Pid.

-spec stop(pid()) -> ok.
stop(Client) ->
    _ = exit(Client, shutdown),
    ok.

%%

-spec create(invoice_params(), pid()) -> invoice_state() | woody_error:business_error().
create(InvoiceParams, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Create', [InvoiceParams]})).

-spec create_with_tpl(invoice_params_tpl(), pid()) -> invoice_state() | woody_error:business_error().
create_with_tpl(Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'CreateWithTemplate', [Params]})).

-spec get(invoice_id(), pid()) -> invoice_state() | woody_error:business_error().
get(InvoiceID, Client) ->
    get(InvoiceID, Client, #payproc_EventRange{}).

-spec get(invoice_id(), pid(), event_range()) -> invoice_state() | woody_error:business_error().
get(InvoiceID, Client, EventRange) ->
    map_result_error(gen_server:call(Client, {call, 'Get', [InvoiceID, EventRange]})).

-spec fulfill(invoice_id(), binary(), pid()) -> ok | woody_error:business_error().
fulfill(InvoiceID, Reason, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Fulfill', [InvoiceID, Reason]})).

-spec rescind(invoice_id(), binary(), pid()) -> ok | woody_error:business_error().
rescind(InvoiceID, Reason, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Rescind', [InvoiceID, Reason]})).

-spec repair(invoice_id(), [tuple()], tuple() | undefined, tuple() | undefined, pid()) ->
    ok | woody_error:business_error().
repair(InvoiceID, Changes, Action, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Repair', [InvoiceID, Changes, Action, Params]})).

-spec repair_scenario(invoice_id(), hg_invoice_repair:scenario(), pid()) -> ok | woody_error:business_error().
repair_scenario(InvoiceID, Scenario, Client) ->
    map_result_error(gen_server:call(Client, {call, 'RepairWithScenario', [InvoiceID, Scenario]})).

-spec create_invoice_adjustment(invoice_id(), invoice_adjustment_params(), pid()) ->
    invoice_adjustment() | woody_error:business_error().
create_invoice_adjustment(InvoiceID, Params, Client) ->
    Args = [InvoiceID, Params],
    map_result_error(gen_server:call(Client, {call, 'CreateInvoiceAdjustment', Args})).

-spec get_invoice_adjustment(invoice_id(), invoice_adjustment_params(), pid()) ->
    invoice_adjustment() | woody_error:business_error().
get_invoice_adjustment(InvoiceID, ID, Client) ->
    Args = [InvoiceID, ID],
    map_result_error(gen_server:call(Client, {call, 'GetInvoiceAdjustment', Args})).

-spec start_payment(invoice_id(), payment_params(), pid()) -> payment() | woody_error:business_error().
start_payment(InvoiceID, PaymentParams, Client) ->
    map_result_error(gen_server:call(Client, {call, 'StartPayment', [InvoiceID, PaymentParams]})).

-spec register_payment(invoice_id(), register_payment_params(), pid()) -> payment() | woody_error:business_error().
register_payment(InvoiceID, RegisterPaymentParams, Client) ->
    map_result_error(gen_server:call(Client, {call, 'RegisterPayment', [InvoiceID, RegisterPaymentParams]})).

-spec get_payment(invoice_id(), payment_id(), pid()) -> payment_st() | woody_error:business_error().
get_payment(InvoiceID, PaymentID, Client) ->
    map_result_error(gen_server:call(Client, {call, 'GetPayment', [InvoiceID, PaymentID]})).

-spec cancel_payment(invoice_id(), payment_id(), binary(), pid()) -> ok | woody_error:business_error().
cancel_payment(InvoiceID, PaymentID, Reason, Client) ->
    map_result_error(gen_server:call(Client, {call, 'CancelPayment', [InvoiceID, PaymentID, Reason]})).

-spec capture_payment(invoice_id(), payment_id(), binary(), pid()) -> ok | woody_error:business_error().
capture_payment(InvoiceID, PaymentID, Reason, Client) ->
    capture_payment(InvoiceID, PaymentID, Reason, undefined, Client).

-spec capture_payment(invoice_id(), payment_id(), binary(), cash(), pid()) -> ok | woody_error:business_error().
capture_payment(InvoiceID, PaymentID, Reason, Cash, Client) ->
    capture_payment(InvoiceID, PaymentID, Reason, Cash, undefined, Client).

-spec capture_payment(invoice_id(), payment_id(), binary(), cash(), cart(), pid()) -> ok | woody_error:business_error().
capture_payment(InvoiceID, PaymentID, Reason, Cash, Cart, Client) ->
    capture_payment(InvoiceID, PaymentID, Reason, Cash, Cart, undefined, Client).

-spec capture_payment(invoice_id(), payment_id(), binary(), cash(), cart(), allocation_prototype(), pid()) ->
    ok | woody_error:business_error().
capture_payment(InvoiceID, PaymentID, Reason, Cash, Cart, Allocation, Client) ->
    Call = {
        call,
        'CapturePayment',
        [
            InvoiceID,
            PaymentID,
            #payproc_InvoicePaymentCaptureParams{
                reason = Reason,
                cash = Cash,
                cart = Cart,
                allocation = Allocation
            }
        ]
    },
    map_result_error(gen_server:call(Client, Call)).

-spec create_chargeback(invoice_id(), payment_id(), chargeback_params(), pid()) ->
    chargeback() | woody_error:business_error().
create_chargeback(InvoiceID, PaymentID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'CreateChargeback', [InvoiceID, PaymentID, Params]})).

-spec cancel_chargeback(invoice_id(), payment_id(), chargeback_id(), chargeback_cancel_params(), pid()) ->
    chargeback() | woody_error:business_error().
cancel_chargeback(InvoiceID, PaymentID, ChargebackID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'CancelChargeback', [InvoiceID, PaymentID, ChargebackID, Params]})).

-spec reject_chargeback(invoice_id(), payment_id(), chargeback_id(), chargeback_reject_params(), pid()) ->
    chargeback() | woody_error:business_error().
reject_chargeback(InvoiceID, PaymentID, ChargebackID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'RejectChargeback', [InvoiceID, PaymentID, ChargebackID, Params]})).

-spec accept_chargeback(invoice_id(), payment_id(), chargeback_id(), chargeback_accept_params(), pid()) ->
    chargeback() | woody_error:business_error().
accept_chargeback(InvoiceID, PaymentID, ChargebackID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'AcceptChargeback', [InvoiceID, PaymentID, ChargebackID, Params]})).

-spec reopen_chargeback(invoice_id(), payment_id(), chargeback_id(), chargeback_reopen_params(), pid()) ->
    chargeback() | woody_error:business_error().
reopen_chargeback(InvoiceID, PaymentID, ChargebackID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'ReopenChargeback', [InvoiceID, PaymentID, ChargebackID, Params]})).

-spec get_payment_chargeback(invoice_id(), payment_id(), chargeback_id(), pid()) ->
    refund() | woody_error:business_error().
get_payment_chargeback(InvoiceID, PaymentID, ChargebackID, Client) ->
    map_result_error(gen_server:call(Client, {call, 'GetPaymentChargeback', [InvoiceID, PaymentID, ChargebackID]})).

-spec refund_payment(invoice_id(), payment_id(), refund_params(), pid()) -> refund() | woody_error:business_error().
refund_payment(InvoiceID, PaymentID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'RefundPayment', [InvoiceID, PaymentID, Params]})).

-spec refund_payment_manual(invoice_id(), payment_id(), refund_params(), pid()) ->
    refund() | woody_error:business_error().
refund_payment_manual(InvoiceID, PaymentID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'CreateManualRefund', [InvoiceID, PaymentID, Params]})).

-spec get_payment_refund(invoice_id(), payment_id(), refund_id(), pid()) -> refund() | woody_error:business_error().
get_payment_refund(InvoiceID, PaymentID, RefundID, Client) ->
    map_result_error(gen_server:call(Client, {call, 'GetPaymentRefund', [InvoiceID, PaymentID, RefundID]})).

-spec create_payment_adjustment(invoice_id(), payment_id(), payment_adjustment_params(), pid()) ->
    payment_adjustment() | woody_error:business_error().
create_payment_adjustment(InvoiceID, PaymentID, ID, Client) ->
    Args = [InvoiceID, PaymentID, ID],
    map_result_error(gen_server:call(Client, {call, 'CreatePaymentAdjustment', Args})).

-spec get_payment_adjustment(invoice_id(), payment_id(), payment_adjustment_id(), pid()) ->
    payment_adjustment() | woody_error:business_error().
get_payment_adjustment(InvoiceID, PaymentID, Params, Client) ->
    Args = [InvoiceID, PaymentID, Params],
    map_result_error(gen_server:call(Client, {call, 'GetPaymentAdjustment', Args})).

-spec compute_terms(invoice_id(), party_revision_param(), pid()) -> term_set().
compute_terms(InvoiceID, PartyRevision, Client) ->
    map_result_error(gen_server:call(Client, {call, 'ComputeTerms', [InvoiceID, PartyRevision]})).

-define(DEFAULT_NEXT_EVENT_TIMEOUT, 5000).

-spec pull_event(invoice_id(), pid()) ->
    tuple() | timeout | woody_error:business_error().
pull_event(InvoiceID, Client) ->
    pull_event(InvoiceID, ?DEFAULT_NEXT_EVENT_TIMEOUT, Client).

-spec pull_event(invoice_id(), timeout(), pid()) ->
    tuple() | timeout | woody_error:business_error().
pull_event(InvoiceID, Timeout, Client) ->
    gen_server:call(Client, {pull_event, InvoiceID, Timeout}, infinity).

-spec pull_change(invoice_id(), fun((_Elem) -> boolean() | {'true', _Value}), timeout(), pid()) ->
    tuple() | timeout | woody_error:business_error().
pull_change(InvoiceID, FilterMapFun, Timeout, Client) ->
    gen_server:call(Client, {pull_change, InvoiceID, FilterMapFun, Timeout}, infinity).

filter_changes(Changes, FilterMapFun) ->
    lists:filtermap(FilterMapFun, Changes).

map_result_error({ok, Result}) ->
    Result;
map_result_error({exception, _} = Exception) ->
    Exception;
map_result_error({error, Error}) ->
    error(Error).

%%

-type event() :: dmsl_payproc_thrift:'Event'().
-type changes() :: [
    dmsl_payproc_thrift:'InvoiceChange'()
    | dmsl_payproc_thrift:'PartyChange'()
    | dmsl_payproc_thrift:'InvoiceTemplateChange'()
    | dmsl_payproc_thrift:'CustomerChange'()
].

-record(state, {
    pollers :: #{invoice_id() => hg_client_event_poller:st(event())},
    client :: hg_client_api:t(),
    changes = #{} :: #{{callref(), invoice_id()} => [changes()]}
}).

-type state() :: #state{}.
-type callref() :: {pid(), Tag :: reference()}.

-spec init(hg_client_api:t()) -> {ok, state()}.
init(ApiClient) ->
    {ok, #state{pollers = #{}, client = ApiClient}}.

-spec handle_call(term(), callref(), state()) -> {reply, term(), state()} | {noreply, state()}.
handle_call({call, Function, Args}, _From, St = #state{client = Client}) ->
    {Result, ClientNext} = hg_client_api:call(invoicing, Function, Args, Client),
    {reply, Result, St#state{client = ClientNext}};
handle_call({pull_event, InvoiceID, Timeout}, _From, St) ->
    {Result, StNext} = handle_pull_event(InvoiceID, Timeout, St),
    {reply, Result, StNext};
handle_call({pull_change, InvoiceID, FilterMapFun, Timeout}, From, St) ->
    {Result, StNext} = handle_pull_change(InvoiceID, FilterMapFun, Timeout, From, St),
    {reply, Result, StNext};
handle_call(Call, _From, State) ->
    _ = logger:warning("unexpected call received: ~tp", [Call]),
    {noreply, State}.

-spec handle_cast(_, state()) -> {noreply, state()}.
handle_cast(Cast, State) ->
    _ = logger:warning("unexpected cast received: ~tp", [Cast]),
    {noreply, State}.

-spec handle_info(_, state()) -> {noreply, state()}.
handle_info(Info, State) ->
    _ = logger:warning("unexpected info received: ~tp", [Info]),
    {noreply, State}.

-spec terminate(Reason, state()) -> ok when Reason :: normal | shutdown | {shutdown, term()} | term().
terminate(_Reason, _State) ->
    ok.

-spec code_change(Vsn | {down, Vsn}, state(), term()) -> {error, noimpl} when Vsn :: term().
code_change(_OldVsn, _State, _Extra) ->
    {error, noimpl}.

%%

handle_pull_event(InvoiceID, Timeout, St = #state{client = Client}) ->
    Poller = get_poller(InvoiceID, St),
    {Result, ClientNext, PollerNext} = hg_client_event_poller:poll(1, Timeout, Client, Poller),
    StNext = set_poller(InvoiceID, PollerNext, St#state{client = ClientNext}),
    case Result of
        [] ->
            {timeout, StNext};
        [#payproc_Event{payload = Payload}] ->
            {{ok, Payload}, StNext};
        Error ->
            {Error, StNext}
    end.

handle_pull_change(InvoiceID, FilterMapFun, Timeout, From, St = #state{changes = ChangesMap}) ->
    case ChangesMap of
        #{InvoiceID := [ResultChange | RemainingChanges]} ->
            ChangesMapNext = ChangesMap#{InvoiceID => RemainingChanges},
            StNext = St#state{changes = ChangesMapNext},
            {ResultChange, StNext};
        _ ->
            case handle_pull_event(InvoiceID, Timeout, St) of
                {{ok, ?invoice_ev(Changes)}, StNext0} ->
                    case filter_changes(Changes, FilterMapFun) of
                        L when length(L) > 0 ->
                            {ResultChange, RemainingChanges} = lists:split(1, L),
                            ChangesMapNext = ChangesMap#{InvoiceID => RemainingChanges},
                            StNext1 = StNext0#state{changes = ChangesMapNext},
                            {ResultChange, StNext1};
                        [] ->
                            handle_pull_change(InvoiceID, FilterMapFun, Timeout, From, St)
                    end;
                {Result, StNext0} ->
                    {Result, StNext0}
            end
    end.

get_poller(InvoiceID, #state{pollers = Pollers}) ->
    maps:get(InvoiceID, Pollers, construct_poller(InvoiceID)).

set_poller(InvoiceID, Poller, St = #state{pollers = Pollers}) ->
    St#state{pollers = maps:put(InvoiceID, Poller, Pollers)}.

construct_poller(InvoiceID) ->
    hg_client_event_poller:new(
        {invoicing, 'GetEvents', [InvoiceID]},
        fun(Event) -> Event#payproc_Event.id end
    ).
