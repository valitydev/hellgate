%%% Invoice machine
%%%
%%% TODO
%%%  - REFACTOR WITH FIRE
%%%     - proper concepts
%%%        - simple lightweight lower-level machines (middlewares (?)) for:
%%%           - handling callbacks idempotently
%%%           - state collapsing (?)
%%%           - simpler flow control (?)
%%%           - event publishing (?)
%%%  - unify somehow with operability assertions from hg_party
%%%  - if someone has access to a party then it has access to an invoice
%%%    belonging to this party

-module(hg_invoice).

-include("payment_events.hrl").
-include("invoice_events.hrl").
-include("domain.hrl").
-include("hg_invoice.hrl").

-include_lib("damsel/include/dmsl_repair_thrift.hrl").

-define(NS, <<"invoice">>).

-export([process_callback/2]).
-export([process_session_change_by_tag/2]).

-export_type([activity/0]).
-export_type([invoice/0]).
-export_type([payment_id/0]).
-export_type([payment_st/0]).
-export_type([party/0]).

%% Public interface

-export([get/1]).
-export([get_payment/2]).
-export([get_payment_opts/1]).
-export([create/5]).
-export([marshal_invoice/1]).
-export([unmarshal_history/1]).
-export([collapse_history/1]).

%% Machine callbacks

-behaviour(hg_machine).

-export([namespace/0]).

-export([init/2]).
-export([process_signal/2]).
-export([process_call/2]).
-export([process_repair/2]).

%% Internal

-export([fail/1]).

-import(hg_invoice_utils, [
    assert_party_operable/1,
    assert_party_unblocked/1,
    assert_shop_operable/1,
    assert_shop_unblocked/1
]).

%% Internal types

-define(invalid_invoice_status(Status), #payproc_InvalidInvoiceStatus{status = Status}).
-define(payment_pending(PaymentID), #payproc_InvoicePaymentPending{id = PaymentID}).

-type st() :: #st{}.

-type invoice_change() :: dmsl_payproc_thrift:'InvoiceChange'().
-type invoice_params() :: dmsl_payproc_thrift:'InvoiceParams'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type allocation() :: dmsl_domain_thrift:'Allocation'().
-type party() :: dmsl_domain_thrift:'PartyConfig'().

-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type payment_st() :: hg_invoice_payment:st().

-type activity() ::
    invoice
    | {payment, payment_id()}.

%% API

-spec get(hg_machine:id()) -> {ok, st()} | {error, notfound}.
get(Id) ->
    case hg_machine:get_history(?NS, Id) of
        {ok, History} ->
            {ok, collapse_history(unmarshal_history(History))};
        Error ->
            Error
    end.

-spec get_payment(payment_id(), st()) -> {ok, payment_st()} | {error, notfound}.
get_payment(PaymentID, St) ->
    case try_get_payment_session(PaymentID, St) of
        PaymentSession when PaymentSession /= undefined ->
            {ok, PaymentSession};
        undefined ->
            {error, notfound}
    end.

-spec get_payment_opts(st()) -> hg_invoice_payment:opts().
get_payment_opts(St = #st{invoice = Invoice, party = undefined}) ->
    #{
        party => hg_party:get_party(get_party_id(St)),
        invoice => Invoice,
        timestamp => hg_datetime:format_now()
    };
get_payment_opts(#st{invoice = Invoice, party = Party}) ->
    #{
        party => Party,
        invoice => Invoice,
        timestamp => hg_datetime:format_now()
    }.

-spec get_payment_opts(hg_domain:revision(), st()) ->
    hg_invoice_payment:opts().
get_payment_opts(Revision, St = #st{invoice = Invoice}) ->
    #{
        party => hg_party:checkout(get_party_id(St), Revision),
        invoice => Invoice,
        timestamp => hg_datetime:format_now()
    }.

-spec create(
    hg_machine:id(),
    undefined | hg_machine:id(),
    invoice_params(),
    undefined | allocation(),
    [hg_invoice_mutation:mutation()]
) ->
    invoice().
create(ID, InvoiceTplID, V = #payproc_InvoiceParams{}, _Allocation, Mutations) ->
    OwnerID = V#payproc_InvoiceParams.party_id,
    ShopID = V#payproc_InvoiceParams.shop_id,
    Cost = V#payproc_InvoiceParams.cost,
    hg_invoice_mutation:apply_mutations(Mutations, #domain_Invoice{
        id = ID,
        shop_id = ShopID,
        owner_id = OwnerID,
        created_at = hg_datetime:format_now(),
        status = ?invoice_unpaid(),
        cost = Cost,
        due = V#payproc_InvoiceParams.due,
        details = V#payproc_InvoiceParams.details,
        context = V#payproc_InvoiceParams.context,
        template_id = InvoiceTplID,
        external_id = V#payproc_InvoiceParams.external_id,
        client_info = V#payproc_InvoiceParams.client_info
    }).

%%----------------- invoice asserts
assert_invoice(Checks, #st{} = St) when is_list(Checks) ->
    lists:foldl(fun assert_invoice/2, St, Checks);
assert_invoice(operable, #st{party = Party} = St) when Party =/= undefined ->
    assert_party_shop_operable(
        hg_party:get_shop(get_shop_id(St), Party, hg_party:get_party_revision()),
        Party
    ),
    St;
assert_invoice(unblocked, #st{party = Party} = St) when Party =/= undefined ->
    assert_party_shop_unblocked(
        hg_party:get_shop(get_shop_id(St), Party, hg_party:get_party_revision()),
        Party
    ),
    St;
assert_invoice({status, Status}, #st{invoice = #domain_Invoice{status = {Status, _}}} = St) ->
    St;
assert_invoice({status, _Status}, #st{invoice = #domain_Invoice{status = Invalid}}) ->
    throw(?invalid_invoice_status(Invalid)).

assert_party_shop_operable(Shop, Party) ->
    _ = assert_party_operable(Party),
    _ = assert_shop_operable(Shop),
    ok.

assert_party_shop_unblocked(Shop, Party) ->
    _ = assert_party_unblocked(Party),
    _ = assert_shop_unblocked(Shop),
    ok.

get_payment_state(PaymentSession) ->
    Refunds = hg_invoice_payment:get_refunds(PaymentSession),
    LegacyRefunds =
        lists:map(
            fun(#payproc_InvoicePaymentRefund{refund = R}) ->
                R
            end,
            Refunds
        ),
    #payproc_InvoicePayment{
        payment = hg_invoice_payment:get_payment(PaymentSession),
        adjustments = hg_invoice_payment:get_adjustments(PaymentSession),
        chargebacks = hg_invoice_payment:get_chargebacks(PaymentSession),
        route = hg_invoice_payment:get_route(PaymentSession),
        cash_flow = hg_invoice_payment:get_final_cashflow(PaymentSession),
        legacy_refunds = LegacyRefunds,
        refunds = Refunds,
        sessions = hg_invoice_payment:get_sessions(PaymentSession),
        last_transaction_info = hg_invoice_payment:get_trx(PaymentSession),
        allocation = hg_invoice_payment:get_allocation(PaymentSession)
    }.

%%

-type tag() :: dmsl_base_thrift:'Tag'().
-type session_change() :: hg_session:change().
-type callback() :: {provider, dmsl_proxy_provider_thrift:'Callback'()}.
-type callback_response() :: dmsl_proxy_provider_thrift:'CallbackResponse'().

-spec process_callback(tag(), callback()) ->
    {ok, callback_response()} | {error, invalid_callback | notfound | failed} | no_return().
process_callback(Tag, Callback) ->
    process_with_tag(Tag, fun(MachineID) ->
        case hg_machine:call(?NS, MachineID, {callback, Tag, Callback}) of
            {ok, _} = Ok ->
                Ok;
            {exception, invalid_callback} ->
                {error, invalid_callback};
            {error, _} = Error ->
                Error
        end
    end).

-spec process_session_change_by_tag(tag(), session_change()) ->
    ok | {error, notfound | failed} | no_return().
process_session_change_by_tag(Tag, SessionChange) ->
    process_with_tag(Tag, fun(MachineID) ->
        case hg_machine:call(?NS, MachineID, {session_change, Tag, SessionChange}) of
            ok ->
                ok;
            {exception, invalid_callback} ->
                {error, notfound};
            {error, _} = Error ->
                Error
        end
    end).

process_with_tag(Tag, F) ->
    case hg_machine_tag:get_binding(namespace(), Tag) of
        {ok, _EntityID, MachineID} ->
            F(MachineID);
        {error, _} = Error ->
            Error
    end.

%%

-spec fail(hg_machine:id()) -> ok.
fail(Id) ->
    try hg_machine:call(?NS, Id, fail) of
        {error, failed} ->
            ok;
        {error, Error} ->
            erlang:error({unexpected_error, Error});
        {ok, Result} ->
            erlang:error({unexpected_result, Result})
    catch
        _Class:_Term:_Trace ->
            ok
    end.

%%

-spec namespace() -> hg_machine:ns().
namespace() ->
    ?NS.

-spec init(binary(), hg_machine:machine()) -> hg_machine:result().
init(Invoice, _Machine) ->
    UnmarshalledInvoice = unmarshal_invoice(Invoice),
    % TODO ugly, better to roll state and events simultaneously, hg_party-like
    handle_result(#{
        changes => [?invoice_created(UnmarshalledInvoice)],
        action => set_invoice_timer(hg_machine_action:new(), #st{invoice = UnmarshalledInvoice}),
        state => #st{}
    }).

%%

-spec process_repair(hg_machine:args(), hg_machine:machine()) -> hg_machine:result() | no_return().
process_repair(Args, #{history := History}) ->
    St = collapse_history(unmarshal_history(History)),
    handle_result(handle_repair(Args, St)).

handle_repair({changes, Changes, RepairAction, Params}, St) ->
    Result =
        case Changes of
            [_ | _] ->
                #{changes => Changes};
            [] ->
                #{}
        end,
    Action = construct_repair_action(RepairAction),
    Result#{
        state => St,
        action => Action,
        % Validating that these changes are at least applicable
        validate => should_validate_transitions(Params)
    };
handle_repair({scenario, _}, #st{activity = Activity}) when Activity =:= invoice orelse Activity =:= undefined ->
    throw({exception, invoice_has_no_active_payment});
handle_repair({scenario, Scenario}, St = #st{activity = {payment, PaymentID}}) ->
    PaymentSession = get_payment_session(PaymentID, St),
    Activity = hg_invoice_payment:get_activity(PaymentSession),
    case {Scenario, Activity} of
        {_, idle} ->
            throw({exception, cant_fail_payment_in_idle_state});
        {Scenario, Activity} ->
            try_to_get_repair_state(Scenario, St)
    end.

-spec process_signal(hg_machine:signal(), hg_machine:machine()) -> hg_machine:result().
process_signal(Signal, #{history := History}) ->
    handle_result(handle_signal(Signal, collapse_history(unmarshal_history(History)))).

handle_signal(timeout, St = #st{activity = {payment, PaymentID}}) ->
    % there's a payment pending
    PaymentSession = get_payment_session(PaymentID, St),
    process_payment_signal(timeout, PaymentID, PaymentSession, St);
handle_signal(timeout, St = #st{activity = invoice}) ->
    % invoice is expired
    handle_expiration(St).

construct_repair_action(CA) when CA /= undefined ->
    lists:foldl(
        fun merge_repair_action/2,
        hg_machine_action:new(),
        [{timer, CA#repair_ComplexAction.timer}, {remove, CA#repair_ComplexAction.remove}]
    );
construct_repair_action(undefined) ->
    hg_machine_action:new().

merge_repair_action({timer, {set_timer, #repair_SetTimerAction{timer = Timer}}}, Action) ->
    hg_machine_action:set_timer(Timer, Action);
merge_repair_action({timer, {unset_timer, #repair_UnsetTimerAction{}}}, Action) ->
    hg_machine_action:unset_timer(Action);
merge_repair_action({remove, #repair_RemoveAction{}}, Action) ->
    hg_machine_action:mark_removal(Action);
merge_repair_action({_, undefined}, Action) ->
    Action.

should_validate_transitions(#payproc_InvoiceRepairParams{validate_transitions = V}) when is_boolean(V) ->
    V;
should_validate_transitions(undefined) ->
    true.

handle_expiration(St) ->
    #{
        changes => [?invoice_status_changed(?invoice_cancelled(hg_utils:format_reason(overdue)))],
        state => St
    }.

%%

-type thrift_call() :: hg_machine:thrift_call().
-type callback_call() :: {callback, tag(), callback()}.
-type session_change_call() :: {session_change, tag(), session_change()}.
-type call() :: thrift_call() | callback_call() | session_change_call().
-type call_result() :: #{
    changes => [invoice_change()],
    action => hg_machine_action:t(),
    response => ok | term(),
    state => st()
}.

-spec process_call(call(), hg_machine:machine()) -> {hg_machine:response(), hg_machine:result()}.
process_call(Call, #{history := History}) ->
    St = collapse_history(unmarshal_history(History)),
    try
        handle_result(handle_call(Call, St))
    catch
        throw:Exception ->
            {{exception, Exception}, #{}}
    end.

-spec handle_call(call(), st()) -> call_result().
handle_call({{'Invoicing', 'StartPayment'}, {_InvoiceID, PaymentParams}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice(operable, St),
    start_payment(PaymentParams, St);
handle_call({{'Invoicing', 'RegisterPayment'}, {_InvoiceID, PaymentParams}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice(unblocked, St),
    register_payment(PaymentParams, St);
handle_call({{'Invoicing', 'CapturePayment'}, {_InvoiceID, PaymentID, Params}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice(operable, St),
    #payproc_InvoicePaymentCaptureParams{
        reason = Reason,
        cash = Cash,
        cart = Cart
    } = Params,
    PaymentSession = get_payment_session(PaymentID, St),
    Opts = #{timestamp := OccurredAt} = get_payment_opts(St),
    {ok, {Changes, Action}} = capture_payment(PaymentSession, Reason, Cash, Cart, Opts),
    #{
        response => ok,
        changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
        action => Action,
        state => St
    };
handle_call({{'Invoicing', 'CancelPayment'}, {_InvoiceID, PaymentID, Reason}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice(operable, St),
    PaymentSession = get_payment_session(PaymentID, St),
    {ok, {Changes, Action}} = hg_invoice_payment:cancel(PaymentSession, Reason),
    #{
        response => ok,
        changes => wrap_payment_changes(PaymentID, Changes, hg_datetime:format_now()),
        action => Action,
        state => St
    };
handle_call({{'Invoicing', 'Fulfill'}, {_InvoiceID, Reason}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice([operable, {status, paid}], St),
    #{
        response => ok,
        changes => [?invoice_status_changed(?invoice_fulfilled(hg_utils:format_reason(Reason)))],
        state => St
    };
handle_call({{'Invoicing', 'Rescind'}, {_InvoiceID, Reason}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice([operable, {status, unpaid}], St),
    _ = assert_no_pending_payment(St),
    #{
        response => ok,
        changes => [?invoice_status_changed(?invoice_cancelled(hg_utils:format_reason(Reason)))],
        action => hg_machine_action:unset_timer(),
        state => St
    };
handle_call({{'Invoicing', 'RefundPayment'}, {_InvoiceID, PaymentID, Params}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice(operable, St),
    PaymentSession = get_payment_session(PaymentID, St),
    start_refund(refund, Params, PaymentID, PaymentSession, St);
handle_call({{'Invoicing', 'CreateManualRefund'}, {_InvoiceID, PaymentID, Params}}, St0) ->
    St = St0#st{party = hg_party:get_party(get_party_id(St0))},
    _ = assert_invoice(operable, St),
    PaymentSession = get_payment_session(PaymentID, St),
    start_refund(manual_refund, Params, PaymentID, PaymentSession, St);
handle_call({{'Invoicing', 'CreateChargeback'}, {_InvoiceID, PaymentID, Params}}, St) ->
    PaymentSession = get_payment_session(PaymentID, St),
    PaymentOpts = get_payment_opts(St),
    start_chargeback(Params, PaymentID, PaymentSession, PaymentOpts, St);
handle_call({{'Invoicing', 'CancelChargeback'}, {_InvoiceID, PaymentID, ChargebackID, Params}}, St) ->
    #payproc_InvoicePaymentChargebackCancelParams{occurred_at = OccurredAt} = Params,
    PaymentSession = get_payment_session(PaymentID, St),
    CancelResult = hg_invoice_payment:cancel_chargeback(ChargebackID, PaymentSession, Params),
    wrap_payment_impact(PaymentID, CancelResult, St, OccurredAt);
handle_call({{'Invoicing', 'RejectChargeback'}, {_InvoiceID, PaymentID, ChargebackID, Params}}, St) ->
    #payproc_InvoicePaymentChargebackRejectParams{occurred_at = OccurredAt} = Params,
    PaymentSession = get_payment_session(PaymentID, St),
    RejectResult = hg_invoice_payment:reject_chargeback(ChargebackID, PaymentSession, Params),
    wrap_payment_impact(PaymentID, RejectResult, St, OccurredAt);
handle_call({{'Invoicing', 'AcceptChargeback'}, {_InvoiceID, PaymentID, ChargebackID, Params}}, St) ->
    #payproc_InvoicePaymentChargebackAcceptParams{occurred_at = OccurredAt} = Params,
    PaymentSession = get_payment_session(PaymentID, St),
    AcceptResult = hg_invoice_payment:accept_chargeback(ChargebackID, PaymentSession, Params),
    wrap_payment_impact(PaymentID, AcceptResult, St, OccurredAt);
handle_call({{'Invoicing', 'ReopenChargeback'}, {_InvoiceID, PaymentID, ChargebackID, Params}}, St) ->
    #payproc_InvoicePaymentChargebackReopenParams{occurred_at = OccurredAt} = Params,
    PaymentSession = get_payment_session(PaymentID, St),
    ReopenResult = hg_invoice_payment:reopen_chargeback(ChargebackID, PaymentSession, Params),
    wrap_payment_impact(PaymentID, ReopenResult, St, OccurredAt);
handle_call({{'Invoicing', 'CreatePaymentAdjustment'}, {_InvoiceID, PaymentID, Params}}, St) ->
    PaymentSession = get_payment_session(PaymentID, St),
    Opts = #{timestamp := Timestamp} = get_payment_opts(St),
    wrap_payment_impact(
        PaymentID,
        hg_invoice_payment:create_adjustment(Timestamp, Params, PaymentSession, Opts),
        St
    );
handle_call({callback, _Tag, _Callback} = Call, St) ->
    dispatch_to_session(Call, St);
handle_call({session_change, _Tag, _SessionChange} = Call, St) ->
    dispatch_to_session(Call, St).

-spec dispatch_to_session({callback, tag(), callback()} | {session_change, tag(), session_change()}, st()) ->
    call_result().
dispatch_to_session({callback, Tag, {provider, Payload}}, St = #st{activity = {payment, PaymentID}}) ->
    PaymentSession = get_payment_session(PaymentID, St),
    process_payment_call({callback, Tag, Payload}, PaymentID, PaymentSession, St);
dispatch_to_session({session_change, _Tag, _SessionChange} = Call, St = #st{activity = {payment, PaymentID}}) ->
    PaymentSession = get_payment_session(PaymentID, St),
    process_payment_call(Call, PaymentID, PaymentSession, St);
dispatch_to_session(_Call, _St) ->
    throw(invalid_callback).

assert_no_pending_payment(#st{activity = {payment, PaymentID}}) ->
    throw(?payment_pending(PaymentID));
assert_no_pending_payment(_) ->
    ok.

set_invoice_timer(Action, #st{invoice = Invoice} = St) ->
    set_invoice_timer(Invoice#domain_Invoice.status, Action, St).

set_invoice_timer(?invoice_unpaid(), Action, #st{invoice = #domain_Invoice{due = Due}}) ->
    hg_machine_action:set_deadline(Due, Action);
set_invoice_timer(_Status, Action, _St) ->
    Action.

capture_payment(PaymentSession, Reason, undefined, Cart, Opts) when Cart =/= undefined ->
    Cash = hg_invoice_utils:get_cart_amount(Cart),
    capture_payment(PaymentSession, Reason, Cash, Cart, Opts);
capture_payment(PaymentSession, Reason, Cash, Cart, Opts) ->
    hg_invoice_payment:capture(PaymentSession, Reason, Cash, Cart, Opts).

%%

start_payment(#payproc_InvoicePaymentParams{id = undefined} = PaymentParams, St) ->
    PaymentID = create_payment_id(St),
    do_start_payment(PaymentID, PaymentParams, St);
start_payment(#payproc_InvoicePaymentParams{id = PaymentID} = PaymentParams, St) ->
    case try_get_payment_session(PaymentID, St) of
        undefined ->
            do_start_payment(PaymentID, PaymentParams, St);
        PaymentSession ->
            #{
                response => get_payment_state(PaymentSession),
                state => St
            }
    end.

register_payment(#payproc_RegisterInvoicePaymentParams{id = undefined} = PaymentParams, St) ->
    PaymentID = create_payment_id(St),
    do_register_payment(PaymentID, PaymentParams, St);
register_payment(#payproc_RegisterInvoicePaymentParams{id = PaymentID} = PaymentParams, St) ->
    case try_get_payment_session(PaymentID, St) of
        undefined ->
            do_register_payment(PaymentID, PaymentParams, St);
        PaymentSession ->
            #{
                response => get_payment_state(PaymentSession),
                state => St
            }
    end.

do_register_payment(PaymentID, PaymentParams, St) ->
    _ = assert_invoice({status, unpaid}, St),
    _ = assert_no_pending_payment(St),
    Opts = #{timestamp := OccurredAt} = get_payment_opts(St),
    % TODO make timer reset explicit here
    {PaymentSession, {Changes, Action}} = hg_invoice_registered_payment:init(PaymentID, PaymentParams, Opts),
    #{
        response => get_payment_state(PaymentSession),
        changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
        action => Action,
        state => St
    }.

do_start_payment(PaymentID, PaymentParams, St) ->
    _ = assert_invoice({status, unpaid}, St),
    _ = assert_no_pending_payment(St),
    Opts = #{timestamp := OccurredAt} = get_payment_opts(St),
    % TODO make timer reset explicit here
    {PaymentSession, {Changes, Action}} = hg_invoice_payment:init(PaymentID, PaymentParams, Opts),
    #{
        response => get_payment_state(PaymentSession),
        changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
        action => Action,
        state => St
    }.

process_payment_signal(Signal, PaymentID, PaymentSession, St) ->
    Revision = hg_invoice_payment:get_payment_revision(PaymentSession),
    Opts = get_payment_opts(Revision, St),
    PaymentResult = process_invoice_payment_signal(Signal, PaymentSession, Opts),
    handle_payment_result(PaymentResult, PaymentID, PaymentSession, St, Opts).

process_invoice_payment_signal(Signal, PaymentSession, Opts) ->
    case hg_maybe:apply(fun(PS) -> hg_invoice_payment:get_origin(PS) end, PaymentSession) of
        undefined ->
            hg_invoice_payment:process_signal(Signal, PaymentSession, Opts);
        ?invoice_payment_merchant_reg_origin() ->
            hg_invoice_payment:process_signal(Signal, PaymentSession, Opts);
        ?invoice_payment_provider_reg_origin() ->
            hg_invoice_registered_payment:process_signal(Signal, PaymentSession, Opts)
    end.

process_payment_call(Call, PaymentID, PaymentSession, St) ->
    Revision = hg_invoice_payment:get_payment_revision(PaymentSession),
    Opts = get_payment_opts(Revision, St),
    {Response, PaymentResult0} = hg_invoice_payment:process_call(Call, PaymentSession, Opts),
    PaymentResult1 = handle_payment_result(PaymentResult0, PaymentID, PaymentSession, St, Opts),
    PaymentResult1#{response => Response}.

handle_payment_result({next, {Changes, Action}}, PaymentID, _PaymentSession, St, Opts) ->
    #{timestamp := OccurredAt} = Opts,
    #{
        changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
        action => Action,
        state => St
    };
handle_payment_result({done, {Changes, Action}}, PaymentID, PaymentSession, St, Opts) ->
    Invoice = St#st.invoice,
    InvoiceID = Invoice#domain_Invoice.id,
    #{timestamp := OccurredAt} = Opts,
    PaymentSession1 = collapse_payment_changes(Changes, PaymentSession, #{invoice_id => InvoiceID}),
    Payment = hg_invoice_payment:get_payment(PaymentSession1),
    case get_payment_status(Payment) of
        ?processed() ->
            #{
                changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
                action => Action,
                state => St
            };
        ?captured() ->
            MaybePaid =
                case Invoice of
                    #domain_Invoice{status = ?invoice_paid()} ->
                        [];
                    #domain_Invoice{} ->
                        [?invoice_status_changed(?invoice_paid())]
                end,
            #{
                changes => wrap_payment_changes(PaymentID, Changes, OccurredAt) ++ MaybePaid,
                action => Action,
                state => St
            };
        ?refunded() ->
            #{
                changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
                state => St
            };
        ?charged_back() ->
            #{
                changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
                state => St
            };
        ?failed(_) ->
            #{
                changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
                action => set_invoice_timer(Action, St),
                state => St
            };
        ?cancelled() ->
            #{
                changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
                action => set_invoice_timer(Action, St),
                state => St
            }
    end.

collapse_payment_changes(Changes, PaymentSession, ChangeOpts) ->
    lists:foldl(fun(C, St1) -> merge_payment_change(C, St1, ChangeOpts) end, PaymentSession, Changes).

wrap_payment_changes(PaymentID, Changes, OccurredAt) ->
    [?payment_ev(PaymentID, C, OccurredAt) || C <- Changes].

wrap_payment_impact(PaymentID, {Response, {Changes, Action}}, St) ->
    wrap_payment_impact(PaymentID, {Response, {Changes, Action}}, St, undefined).

wrap_payment_impact(PaymentID, {Response, {Changes, Action}}, St, OccurredAt) ->
    #{
        response => Response,
        changes => wrap_payment_changes(PaymentID, Changes, OccurredAt),
        action => Action,
        state => St
    }.

handle_result(#{} = Result) ->
    St = validate_changes(Result),
    _ = log_changes(maps:get(changes, Result, []), St),
    MachineResult = handle_result_changes(Result, handle_result_action(Result, #{})),
    case maps:get(response, Result, undefined) of
        undefined ->
            MachineResult;
        ok ->
            {ok, MachineResult};
        Response ->
            {{ok, Response}, MachineResult}
    end.

handle_result_changes(#{changes := Changes = [_ | _]}, Acc) ->
    Acc#{events => [marshal_event_payload(Changes)]};
handle_result_changes(#{}, Acc) ->
    Acc.

handle_result_action(#{action := Action}, Acc) ->
    Acc#{action => Action};
handle_result_action(#{}, Acc) ->
    Acc.

validate_changes(#{validate := false, changes := Changes = [_ | _], state := St}) ->
    collapse_changes(Changes, St, #{});
validate_changes(#{changes := Changes = [_ | _], state := St}) ->
    collapse_changes(Changes, St, #{validation => strict});
validate_changes(#{state := St}) ->
    St.

%%

start_refund(RefundType, RefundParams0, PaymentID, PaymentSession, St) ->
    RefundParams = ensure_refund_id_defined(RefundType, RefundParams0, PaymentSession),
    case get_refund(get_refund_id(RefundParams), PaymentSession) of
        undefined ->
            start_new_refund(RefundType, PaymentID, RefundParams, PaymentSession, St);
        Refund ->
            #{
                response => Refund,
                state => St
            }
    end.

get_refund_id(#payproc_InvoicePaymentRefundParams{id = RefundID}) ->
    RefundID.

ensure_refund_id_defined(RefundType, Params, PaymentSession) ->
    RefundID = force_refund_id_format(RefundType, define_refund_id(Params, PaymentSession)),
    Params#payproc_InvoicePaymentRefundParams{id = RefundID}.

define_refund_id(#payproc_InvoicePaymentRefundParams{id = undefined}, PaymentSession) ->
    make_new_refund_id(PaymentSession);
define_refund_id(#payproc_InvoicePaymentRefundParams{id = ID}, _PaymentSession) ->
    ID.

-define(MANUAL_REFUND_ID_PREFIX, "m").

%% If something breaks - this is why
force_refund_id_format(manual_refund, Correct = <<?MANUAL_REFUND_ID_PREFIX, _Rest/binary>>) ->
    Correct;
force_refund_id_format(manual_refund, Incorrect) ->
    <<?MANUAL_REFUND_ID_PREFIX, Incorrect/binary>>;
force_refund_id_format(refund, <<?MANUAL_REFUND_ID_PREFIX, _ID/binary>>) ->
    throw(#base_InvalidRequest{errors = [<<"Invalid id format">>]});
force_refund_id_format(refund, ID) ->
    ID.

parse_refund_id(<<?MANUAL_REFUND_ID_PREFIX, ID/binary>>) ->
    ID;
parse_refund_id(ID) ->
    ID.

make_new_refund_id(PaymentSession) ->
    Refunds = hg_invoice_payment:get_refunds(PaymentSession),
    construct_refund_id(Refunds).

construct_refund_id(Refunds) ->
    % we can't be sure that old ids were constructed in strict increasing order, so we need to find max ID
    MaxID = lists:foldl(fun find_max_refund_id/2, 0, Refunds),
    genlib:to_binary(MaxID + 1).

find_max_refund_id(#payproc_InvoicePaymentRefund{refund = Refund}, Max) ->
    #domain_InvoicePaymentRefund{id = ID} = Refund,
    IntID = genlib:to_int(parse_refund_id(ID)),
    erlang:max(IntID, Max).

get_refund(ID, PaymentSession) ->
    try
        hg_invoice_payment:get_refund(ID, PaymentSession)
    catch
        throw:#payproc_InvoicePaymentRefundNotFound{} ->
            undefined
    end.

start_new_refund(RefundType, PaymentID, Params, PaymentSession, St) when
    RefundType =:= refund; RefundType =:= manual_refund
->
    wrap_payment_impact(
        PaymentID,
        hg_invoice_payment:RefundType(Params, PaymentSession, get_payment_opts(St)),
        St
    ).

%%

start_chargeback(Params, PaymentID, PaymentSession, PaymentOpts, St) ->
    #payproc_InvoicePaymentChargebackParams{id = ID} = Params,

    case get_chargeback_state(ID, PaymentSession) of
        undefined ->
            #payproc_InvoicePaymentChargebackParams{occurred_at = OccurredAt} = Params,
            CreateResult = hg_invoice_payment:create_chargeback(PaymentSession, PaymentOpts, Params),
            wrap_payment_impact(PaymentID, CreateResult, St, OccurredAt);
        ChargebackState ->
            #{
                response => hg_invoice_payment_chargeback:get(ChargebackState),
                state => St
            }
    end.

get_chargeback_state(ID, PaymentState) ->
    try
        hg_invoice_payment:get_chargeback_state(ID, PaymentState)
    catch
        throw:#payproc_InvoicePaymentChargebackNotFound{} ->
            undefined
    end.

%%

create_payment_id(#st{payments = Payments}) ->
    integer_to_binary(length(Payments) + 1).

get_payment_status(#domain_InvoicePayment{status = Status}) ->
    Status.

try_to_get_repair_state({complex, #payproc_InvoiceRepairComplex{scenarios = Scenarios}}, St) ->
    repair_complex(Scenarios, St);
try_to_get_repair_state(Scenario, St) ->
    repair_scenario(Scenario, St).

repair_complex([], St = #st{activity = {payment, PaymentID}}) ->
    PaymentSession = get_payment_session(PaymentID, St),
    Activity = hg_invoice_payment:get_activity(PaymentSession),
    throw({exception, {activity_not_compatible_with_complex_scenario, Activity}});
repair_complex([Scenario | Rest], St) ->
    try
        repair_scenario(Scenario, St)
    catch
        throw:{exception, {activity_not_compatible_with_scenario, _, _}} ->
            repair_complex(Rest, St)
    end.

repair_scenario(Scenario, St = #st{activity = {payment, PaymentID}}) ->
    PaymentSession = get_payment_session(PaymentID, St),
    Activity = hg_invoice_payment:get_activity(PaymentSession),
    NewActivity =
        case Activity of
            {refund, ID} ->
                Refund = hg_invoice_payment:get_refund_state(ID, PaymentSession),
                {refund, hg_invoice_payment_refund:deduce_activity(Refund)};
            _ ->
                Activity
        end,
    RepairSession = hg_invoice_repair:get_repair_state(NewActivity, Scenario, PaymentSession),
    process_payment_signal(timeout, PaymentID, RepairSession, St).

%%

-spec collapse_history([hg_machine:event()]) -> st().
collapse_history(History) ->
    lists:foldl(
        fun({_ID, Dt, Changes}, St0) ->
            collapse_changes(Changes, St0, #{timestamp => Dt})
        end,
        #st{},
        History
    ).

collapse_changes(Changes, St0, Opts) ->
    lists:foldl(fun(C, St) -> merge_change(C, St, Opts) end, St0, Changes).

merge_change(?invoice_created(Invoice), St, _Opts) ->
    St#st{activity = invoice, invoice = Invoice};
merge_change(?invoice_status_changed(Status), St = #st{invoice = I}, _Opts) ->
    St#st{invoice = I#domain_Invoice{status = Status}};
merge_change(?payment_ev(PaymentID, Change), St = #st{invoice = #domain_Invoice{id = InvoiceID}}, Opts) ->
    PaymentSession = try_get_payment_session(PaymentID, St),
    PaymentSession1 = merge_payment_change(Change, PaymentSession, Opts#{invoice_id => InvoiceID}),
    St1 = set_payment_session(PaymentID, PaymentSession1, St),
    case hg_invoice_payment:get_activity(PaymentSession1) of
        A when A =/= idle ->
            % TODO Shouldn't we have here some kind of stack instead?
            St1#st{activity = {payment, PaymentID}};
        idle ->
            check_non_idle_payments(St1)
    end.

merge_payment_change(Change, PaymentSession, Opts) ->
    case hg_maybe:apply(fun(PS) -> hg_invoice_payment:get_origin(PS) end, PaymentSession) of
        undefined ->
            hg_invoice_payment:merge_change(Change, PaymentSession, Opts);
        ?invoice_payment_merchant_reg_origin() ->
            hg_invoice_payment:merge_change(Change, PaymentSession, Opts);
        ?invoice_payment_provider_reg_origin() ->
            hg_invoice_registered_payment:merge_change(Change, PaymentSession, Opts)
    end.

-spec check_non_idle_payments(st()) -> st().
check_non_idle_payments(#st{payments = Payments} = St) ->
    check_non_idle_payments_(Payments, St).

check_non_idle_payments_([], St) ->
    St#st{activity = invoice};
check_non_idle_payments_([{PaymentID, PaymentSession} | Rest], St) ->
    case hg_invoice_payment:get_activity(PaymentSession) of
        A when A =/= idle ->
            St#st{activity = {payment, PaymentID}};
        idle ->
            check_non_idle_payments_(Rest, St)
    end.

get_party_id(#st{invoice = #domain_Invoice{owner_id = PartyID}}) ->
    PartyID.

get_shop_id(#st{invoice = #domain_Invoice{shop_id = ShopID}}) ->
    ShopID.

get_payment_session(PaymentID, St) ->
    case try_get_payment_session(PaymentID, St) of
        PaymentSession when PaymentSession /= undefined ->
            PaymentSession;
        undefined ->
            throw(#payproc_InvoicePaymentNotFound{})
    end.

try_get_payment_session(PaymentID, #st{payments = Payments}) ->
    case lists:keyfind(PaymentID, 1, Payments) of
        {PaymentID, PaymentSession} ->
            PaymentSession;
        false ->
            undefined
    end.

set_payment_session(PaymentID, PaymentSession, St = #st{payments = Payments}) ->
    St#st{payments = lists:keystore(PaymentID, 1, Payments, {PaymentID, PaymentSession})}.

%%

log_changes(Changes, St) ->
    lists:foreach(fun(C) -> log_change(C, St) end, Changes).

log_change(Change, St) ->
    case get_log_params(Change, St) of
        {ok, #{type := Type, params := Params, message := Message}} ->
            _ = logger:log(info, Message, #{Type => Params}),
            ok;
        undefined ->
            ok
    end.

get_log_params(?invoice_created(Invoice), _St) ->
    get_invoice_event_log(invoice_created, unpaid, Invoice);
get_log_params(?invoice_status_changed({StatusName, _}), #st{invoice = Invoice}) ->
    get_invoice_event_log(invoice_status_changed, StatusName, Invoice);
get_log_params(?payment_ev(PaymentID, Change), St = #st{invoice = Invoice}) ->
    PaymentSession = try_get_payment_session(PaymentID, St),
    case hg_invoice_payment:get_log_params(Change, PaymentSession) of
        {ok, Params} ->
            {ok,
                maps:update_with(
                    params,
                    fun(V) ->
                        [{invoice, get_invoice_params(Invoice)} | V]
                    end,
                    Params
                )};
        undefined ->
            undefined
    end.

get_invoice_event_log(EventType, StatusName, Invoice) ->
    {ok, #{
        type => invoice_event,
        params => [{type, EventType}, {status, StatusName} | get_invoice_params(Invoice)],
        message => get_message(EventType)
    }}.

get_invoice_params(Invoice) ->
    #domain_Invoice{
        id = ID,
        owner_id = PartyID,
        cost = ?cash(Amount, Currency),
        shop_id = ShopID
    } = Invoice,
    [{id, ID}, {owner_id, PartyID}, {cost, [{amount, Amount}, {currency, Currency}]}, {shop_id, ShopID}].

get_message(invoice_created) ->
    "Invoice is created";
get_message(invoice_status_changed) ->
    "Invoice status is changed".

%% Marshalling

-spec marshal_event_payload([invoice_change()]) -> hg_machine:event_payload().
marshal_event_payload(Changes) when is_list(Changes) ->
    wrap_event_payload({invoice_changes, Changes}).

-spec marshal_invoice(invoice()) -> binary().
marshal_invoice(Invoice) ->
    Type = {struct, struct, {dmsl_domain_thrift, 'Invoice'}},
    hg_proto_utils:serialize(Type, Invoice).

%% Unmarshalling

-spec unmarshal_history([hg_machine:event()]) -> [hg_machine:event([invoice_change()])].
unmarshal_history(Events) ->
    [unmarshal_event(Event) || Event <- Events].

-spec unmarshal_event(hg_machine:event()) -> hg_machine:event([invoice_change()]).
unmarshal_event({ID, Dt, Payload}) ->
    {ID, Dt, unmarshal_event_payload(Payload)}.

-spec unmarshal_event_payload(hg_machine:event_payload()) -> [invoice_change()].
unmarshal_event_payload(#{format_version := 1, data := {bin, Changes}}) ->
    Type = {struct, union, {dmsl_payproc_thrift, 'EventPayload'}},
    {invoice_changes, Buf} = hg_proto_utils:deserialize(Type, Changes),
    Buf.

-spec unmarshal_invoice(binary()) -> invoice().
unmarshal_invoice(Bin) ->
    Type = {struct, struct, {dmsl_domain_thrift, 'Invoice'}},
    hg_proto_utils:deserialize(Type, Bin).

%% Wrap in thrift binary

wrap_event_payload(Payload) ->
    Type = {struct, union, {dmsl_payproc_thrift, 'EventPayload'}},
    Bin = hg_proto_utils:serialize(Type, Payload),
    #{
        format_version => 1,
        data => {bin, Bin}
    }.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.
create_dummy_refund_with_id(ID) ->
    #payproc_InvoicePaymentRefund{
        refund = #domain_InvoicePaymentRefund{
            id = genlib:to_binary(ID),
            created_at = hg_datetime:format_now(),
            domain_revision = 42,
            status = ?refund_pending(),
            reason = <<"No reason">>,
            cash = ?cash(1000, <<"RUB">>),
            cart = undefined
        },
        sessions = []
    }.

-spec construct_refund_id_test() -> _.
construct_refund_id_test() ->
    % 10 IDs shuffled
    IDs = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- lists:seq(1, 10)])],
    Refunds = lists:map(fun create_dummy_refund_with_id/1, IDs),
    ?assert(<<"11">> =:= construct_refund_id(Refunds)).

-endif.
