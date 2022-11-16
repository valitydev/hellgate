-module(hg_invoice_payment_refund).

-include_lib("hellgate/include/domain.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").
-include("payment_events.hrl").

-opaque t() :: #{
    refund := domain_refund(),
    cash_flow := final_cash_flow(),
    sessions := [session()],
    remaining_payment_amount := cash(),
    retry_attempts := non_neg_integer(),
    route := route(),
    status := status(),
    session_context := hg_session:event_context(),
    transaction_info => trx_info(),
    failure => failure(),
    injected_context => injected_context()
}.

-type params() :: #{
    refund := domain_refund(),
    cash_flow := final_cash_flow(),
    transaction_info => trx_info()
}.
-type process_result() :: {result(), t()}.
-type event_context() :: #{
    timestamp := integer(),
    route := route(),
    remaining_payment_amount := cash(),
    session_context := hg_session:event_context()
}.

-type id() :: dmsl_domain_thrift:'InvoicePaymentRefundID'().

-type status() ::
    pending
    | succeeded
    | failed.

-export_type([id/0]).
-export_type([status/0]).
-export_type([t/0]).
-export_type([params/0]).
-export_type([process_result/0]).
-export_type([event_context/0]).

%% Accessors

-export([id/1]).
-export([refund/1]).
-export([cash_flow/1]).
-export([sessions/1]).
-export([session/1]).
-export([transaction_info/1]).
-export([failure/1]).
-export([revision/1]).
-export([cash/1]).
-export([created_at/1]).
-export([remaining_payment_amount/1]).
-export([retry_attempts/1]).
-export([route/1]).
-export([status/1]).

%% API

-export([create/1]).
-export([is_status_changed/2]).
-export([deduce_activity/1]).
-export([apply_event/3]).
-export([update_state_with/2]).

-export([process/2]).
-export([process_callback/3]).

%% Internal types

-type party() :: dmsl_domain_thrift:'Party'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type shop() :: dmsl_domain_thrift:'Shop'().
-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type domain_refund() :: dmsl_domain_thrift:'InvoicePaymentRefund'().
-type final_cash_flow() :: dmsl_domain_thrift:'FinalCashFlow'().
-type session() :: hg_session:t().
-type trx_info() :: dmsl_domain_thrift:'TransactionInfo'().
-type failure() :: dmsl_domain_thrift:'OperationFailure'().
-type revision() :: dmt_client:version().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type timestamp() :: dmsl_base_thrift:'Timestamp'().
-type route() :: dmsl_domain_thrift:'PaymentRoute'().
-type payment_info() :: dmsl_proxy_provider_thrift:'PaymentInfo'().
-type domain_status() :: dmsl_domain_thrift:'InvoicePaymentRefundStatus'().

-type callback() :: dmsl_proxy_provider_thrift:'Callback'().
-type callback_response() :: dmsl_proxy_provider_thrift:'CallbackResponse'().

-type event() :: dmsl_payproc_thrift:'InvoicePaymentChangePayload'().
-type event_payload() :: dmsl_payproc_thrift:'InvoicePaymentRefundChangePayload'().
-type events() :: [event()].
-type action() :: hg_machine_action:t().
-type result() :: {events(), action()}.
-type machine_result() :: {next | done, result()}.

-type activity() ::
    new
    | session
    | failure
    | accounter
    | finished.

-type injected_context() :: #{
    party := party(),
    invoice := invoice(),
    payment := payment(),
    shop := shop(),
    invoice_id := invoice_id(),
    payment_id := payment_id(),
    repair_scenario => repair_scenario(),
    payment_info => payment_info()
}.

-type options() :: #{
    party => party(),
    invoice => invoice(),
    timestamp => hg_datetime:timestamp(),

    payment => payment(),
    repair_scenario => repair_scenario(),
    payment_info => payment_info()
}.

-type repair_scenario() :: {result, proxy_result()}.
-type proxy_result() :: dmsl_proxy_provider_thrift:'PaymentProxyResult'().

%% Accessors

-spec id(t()) -> id().
id(T) ->
    Refund = refund(T),
    Refund#domain_InvoicePaymentRefund.id.

-spec refund(t()) -> domain_refund().
refund(#{refund := V}) ->
    V.

-spec cash_flow(t()) -> final_cash_flow().
cash_flow(#{cash_flow := V}) ->
    V.

-spec sessions(t()) -> [session()].
sessions(#{sessions := V}) ->
    V.

-spec session(t()) -> hg_maybe:maybe(session()).
session(#{sessions := []}) ->
    undefined;
session(#{sessions := [Session | _]}) ->
    Session.

-spec transaction_info(t()) -> hg_maybe:maybe(trx_info()).
transaction_info(T) ->
    maps:get(transaction_info, T, undefined).

-spec failure(t()) -> hg_maybe:maybe(failure()).
failure(T) ->
    maps:get(failure, T, undefined).

-spec status(t()) -> status().
status(#{status := V}) ->
    V.

-spec revision(t()) -> revision().
revision(T) ->
    Refund = refund(T),
    Refund#domain_InvoicePaymentRefund.domain_revision.

-spec cash(t()) -> cash().
cash(T) ->
    Refund = refund(T),
    Refund#domain_InvoicePaymentRefund.cash.

-spec created_at(t()) -> timestamp().
created_at(T) ->
    Refund = refund(T),
    Refund#domain_InvoicePaymentRefund.created_at.

-spec remaining_payment_amount(t()) -> cash().
remaining_payment_amount(#{remaining_payment_amount := V}) ->
    V.

-spec retry_attempts(t()) -> non_neg_integer().
retry_attempts(#{retry_attempts := V}) ->
    V.

-spec route(t()) -> route().
route(#{route := V}) ->
    V.

%% API

-spec create(params()) -> events().
create(Params = #{refund := Refund, cash_flow := Cashflow}) ->
    TransactionInfo = maps:get(transaction_info, Params, undefined),
    ID = Refund#domain_InvoicePaymentRefund.id,
    [?refund_ev(ID, ?refund_created(Refund, Cashflow, TransactionInfo))].

-spec is_status_changed(domain_status(), events()) -> boolean().
is_status_changed(Status, Events) ->
    lists:any(fun(Event) -> is_status_changed_event(Status, Event) end, Events).

is_status_changed_event(Status, ?refund_ev(_, ?refund_status_changed(Status))) -> true;
is_status_changed_event(_, _) -> false.

-spec process(options(), t()) -> machine_result().
process(Options, Refund0) ->
    Refund1 = inject_context(Options, Refund0),
    Activity = deduce_activity(Refund1),
    do_process(Activity, Refund1).

-spec process_callback(callback(), payment_info(), t()) -> {callback_response(), machine_result()}.
process_callback(Payload, PaymentInfo, Refund) ->
    Session0 = hg_session:set_payment_info(PaymentInfo, session(Refund)),
    {Response, {Result, Session1}} = hg_session:process_callback(Payload, Session0),
    {Response, finish_session_processing(Result, Session1, Refund)}.

-spec deduce_activity(t()) -> activity().
deduce_activity(Refund) ->
    {SessionStatus, SessionResult} =
        case session(Refund) of
            undefined ->
                {undefined, undefined};
            Session ->
                {hg_session:status(Session), hg_session:result(Session)}
        end,
    Params = genlib_map:compact(#{
        status => status(Refund),
        sessions => sessions(Refund),
        session_status => SessionStatus,
        session_result => SessionResult,
        failure => failure(Refund)
    }),
    do_deduce_activity(Params).

do_deduce_activity(#{status := pending, failure := _Failure}) ->
    failure;
do_deduce_activity(#{status := pending, sessions := []}) ->
    new;
do_deduce_activity(#{status := pending, session_status := finished, session_result := {succeeded, _}}) ->
    accounter;
do_deduce_activity(#{status := pending, session_status := finished, session_result := {failed, _}}) ->
    failure;
do_deduce_activity(#{status := pending}) ->
    session;
do_deduce_activity(#{status := succeeded}) ->
    finished;
do_deduce_activity(#{status := failed}) ->
    finished.

do_process(new, Refund) ->
    process_refund_cashflow(Refund);
do_process(session, Refund) ->
    process_session(Refund);
do_process(accounter, Refund) ->
    process_accounter(Refund);
do_process(failure, Refund) ->
    process_failure(Refund);
do_process(finished, _Refund) ->
    {done, {[], hg_machine_action:new()}}.

process_refund_cashflow(Refund) ->
    Action = hg_machine_action:set_timeout(0, hg_machine_action:new()),
    Party = inject_party(Refund),
    Shop = inject_shop(Refund),
    hold_refund_limits(Refund),

    #{{merchant, settlement} := SettlementID} = hg_accounting:collect_merchant_account_map(Party, Shop, #{}),
    _ = prepare_refund_cashflow(Refund),
    % NOTE we assume that posting involving merchant settlement account MUST be present in the cashflow
    #{min_available_amount := AvailableAmount} = hg_accounting:get_balance(SettlementID),
    case AvailableAmount of
        % TODO we must pull this rule out of refund terms
        Available when Available >= 0 ->
            Events =
                [hg_session:wrap_event(?refunded(), hg_session:create())] ++
                    get_manual_refund_events(Refund),
            {next, {wrap_events(Events, Refund), Action}};
        _ ->
            Failure =
                {failure,
                    payproc_errors:construct(
                        'RefundFailure',
                        {terms_violated, {insufficient_merchant_funds, #payproc_error_GeneralFailure{}}}
                    )},
            {next, {[wrap_event(?refund_rollback_started(Failure), Refund)], Action}}
    end.

process_session(Refund) ->
    PaymentInfo = payment_info(Refund),
    Scenario = repair_scenario(Refund),
    Session0 = hg_session:set_payment_info(PaymentInfo, session(Refund)),
    Session1 = hg_session:set_repair_scenario(Scenario, Session0),
    {Result, Session2} = hg_session:process(Session1),
    finish_session_processing(Result, Session2, Refund).

-spec finish_session_processing(result(), hg_session:t(), t()) -> machine_result().
finish_session_processing({Events0, Action}, Session, Refund) ->
    Events1 = wrap_events(hg_session:wrap_events(Events0, Session), Refund),
    case {hg_session:status(Session), hg_session:result(Session)} of
        {finished, ?session_succeeded()} ->
            NewAction = hg_machine_action:set_timeout(0, Action),
            {next, {Events1, NewAction}};
        {finished, ?session_failed(Failure)} ->
            case check_retry_possibility(Failure, Refund) of
                {retry, Timeout} ->
                    _ = logger:info("Retry session after transient failure, wait ~p", [Timeout]),
                    {SessionEvents0, SessionAction} = retry_session(Action, Timeout),
                    SessionEvents1 = wrap_events(SessionEvents0, Refund),
                    {next, {Events1 ++ SessionEvents1, SessionAction}};
                fatal ->
                    RollbackStarted = [wrap_event(?refund_rollback_started(Failure), Refund)],
                    {next, {Events1 ++ RollbackStarted, hg_machine_action:set_timeout(0, Action)}}
            end;
        _ ->
            {next, {Events1, Action}}
    end.

process_accounter(Refund) ->
    _ = commit_refund_limits(Refund),
    _PostingPlanLog = commit_refund_cashflow(Refund),
    {done, {[wrap_event(?refund_status_changed(?refund_succeeded()), Refund)], hg_machine_action:new()}}.

process_failure(Refund) ->
    Failure = failure(Refund),
    _ = rollback_refund_limits(Refund),
    _PostingPlanLog = rollback_refund_cashflow(Refund),
    Events = [wrap_event(?refund_status_changed(?refund_failed(Failure)), Refund)],
    {done, {Events, hg_machine_action:new()}}.

hold_refund_limits(Refund) ->
    DomainRefund = refund(Refund),
    TurnoverLimits = get_limits(Refund),
    Route = route(Refund),
    Invoice = inject_invoice(Refund),
    Payment = inject_payment(Refund),
    hg_limiter:hold_refund_limits(TurnoverLimits, Invoice, Payment, DomainRefund, Route).

commit_refund_limits(Refund) ->
    DomainRefund = refund(Refund),
    TurnoverLimits = get_limits(Refund),
    Route = route(Refund),
    Invoice = inject_invoice(Refund),
    Payment = inject_payment(Refund),
    hg_limiter:commit_refund_limits(TurnoverLimits, Invoice, Payment, DomainRefund, Route).

rollback_refund_limits(Refund) ->
    DomainRefund = refund(Refund),
    TurnoverLimits = get_limits(Refund),
    Route = route(Refund),
    Invoice = inject_invoice(Refund),
    Payment = inject_payment(Refund),
    hg_limiter:rollback_refund_limits(TurnoverLimits, Invoice, Payment, DomainRefund, Route).

get_limits(Refund) ->
    Revision = revision(Refund),
    ProviderTerms = get_provider_terms(
        Revision, inject_payment(Refund), inject_invoice(Refund), inject_party(Refund), Refund
    ),
    get_turnover_limits(ProviderTerms).

get_provider_terms(Revision, Payment, Invoice, Party, Refund) ->
    Route = route(Refund),
    #domain_Invoice{shop_id = ShopID} = Invoice,
    Shop = hg_party:get_shop(ShopID, Party),
    VS0 = construct_payment_flow(Payment),
    VS1 = collect_validation_varset(Party, Shop, Payment, VS0),
    hg_routing:get_payment_terms(Route, VS1, Revision).

construct_payment_flow(Payment) ->
    #domain_InvoicePayment{
        flow = Flow,
        created_at = CreatedAt
    } = Payment,
    reconstruct_payment_flow(Flow, CreatedAt).

reconstruct_payment_flow(?invoice_payment_flow_instant(), _CreatedAt) ->
    #{flow => instant};
reconstruct_payment_flow(?invoice_payment_flow_hold(_OnHoldExpiration, HeldUntil), CreatedAt) ->
    Seconds = hg_datetime:parse_ts(HeldUntil) - hg_datetime:parse_ts(CreatedAt),
    #{flow => {hold, ?hold_lifetime(Seconds)}}.

collect_validation_varset(Party, Shop, Payment, VS) ->
    #domain_Party{id = PartyID} = Party,
    #domain_Shop{
        id = ShopID,
        category = Category,
        account = #domain_ShopAccount{currency = Currency}
    } = Shop,
    #domain_InvoicePayment{cost = Cost, payer = Payer} = Payment,
    VS#{
        party_id => PartyID,
        shop_id => ShopID,
        category => Category,
        currency => Currency,
        cost => Cost,
        payment_tool => get_payer_payment_tool(Payer)
    }.

get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource);
get_payer_payment_tool(?customer_payer(_CustomerID, _, _, PaymentTool, _)) ->
    PaymentTool;
get_payer_payment_tool(?recurrent_payer(PaymentTool, _, _)) ->
    PaymentTool.

get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

get_turnover_limits(ProviderTerms) ->
    TurnoverLimitSelector = ProviderTerms#domain_PaymentsProvisionTerms.turnover_limits,
    hg_limiter:get_turnover_limits(TurnoverLimitSelector).

prepare_refund_cashflow(Refund) ->
    hg_accounting:hold(construct_refund_plan_id(Refund), make_batch(Refund)).

commit_refund_cashflow(Refund) ->
    hg_accounting:commit(construct_refund_plan_id(Refund), [make_batch(Refund)]).

rollback_refund_cashflow(Refund) ->
    hg_accounting:rollback(construct_refund_plan_id(Refund), [make_batch(Refund)]).

make_batch(Refund) ->
    {1, cash_flow(Refund)}.

construct_refund_plan_id(Refund) ->
    hg_utils:construct_complex_id([
        inject_invoice_id(Refund),
        inject_payment_id(Refund),
        {refund_session, id(Refund)}
    ]).

get_manual_refund_events(#{transaction_info := TransactionInfo}) ->
    [
        ?session_ev(?refunded(), ?trx_bound(TransactionInfo)),
        ?session_ev(?refunded(), ?session_finished(?session_succeeded()))
    ];
get_manual_refund_events(_) ->
    [].

retry_session(Action, Timeout) ->
    NewEvents = [hg_session:wrap_event(?refunded(), hg_session:create())],
    NewAction = hg_machine_action:set_timer({timeout, Timeout}, Action),
    {NewEvents, NewAction}.

-spec check_retry_possibility(failure(), t()) ->
    {retry, non_neg_integer()} | fatal.
check_retry_possibility(Failure, Refund) ->
    case check_failure_type(Failure) of
        transient ->
            RetryStrategy = get_actual_retry_strategy(Refund),
            case hg_retry:next_step(RetryStrategy) of
                {wait, Timeout, _NewStrategy} ->
                    {retry, Timeout};
                finish ->
                    _ = logger:debug("Retries strategy is exceed"),
                    fatal
            end;
        fatal ->
            _ = logger:debug("Failure ~p is not transient", [Failure]),
            fatal
    end.

check_failure_type({failure, Failure}) ->
    payproc_errors:match('RefundFailure', Failure, fun do_check_failure_type/1).

do_check_failure_type({authorization_failed, {temporarily_unavailable, _}}) ->
    transient;
do_check_failure_type(_Failure) ->
    fatal.

get_actual_retry_strategy(Refund) ->
    hg_retry:skip_steps(get_initial_retry_strategy(), retry_attempts(Refund)).

get_initial_retry_strategy() ->
    PolicyConfig = genlib_app:env(hellgate, payment_retry_policy, #{}),
    hg_retry:new_strategy(maps:get(refunded, PolicyConfig, no_retry)).

inject_context(Options, Refund) ->
    Invoice = maps:get(invoice, Options),
    Payment = maps:get(payment, Options),
    #domain_Invoice{id = InvoiceID, shop_id = ShopID} = Invoice,
    #domain_InvoicePayment{id = PaymentID} = Payment,
    Party = maps:get(party, Options),
    Shop = hg_party:get_shop(ShopID, Party),
    Context = genlib_map:compact(#{
        party => Party,
        invoice => Invoice,
        payment => Payment,
        shop => Shop,
        invoice_id => InvoiceID,
        payment_id => PaymentID,
        repair_scenario => maps:get(repair_scenario, Options, undefined),
        payment_info => maps:get(payment_info, Options, undefined)
    }),
    Refund#{injected_context => Context}.

inject_party(#{injected_context := #{party := V}}) -> V.
inject_invoice(#{injected_context := #{invoice := V}}) -> V.
inject_payment(#{injected_context := #{payment := V}}) -> V.
inject_shop(#{injected_context := #{shop := V}}) -> V.
inject_invoice_id(#{injected_context := #{invoice_id := V}}) -> V.
inject_payment_id(#{injected_context := #{payment_id := V}}) -> V.
repair_scenario(#{injected_context := Context}) -> maps:get(repair_scenario, Context, undefined).
payment_info(#{injected_context := Context}) -> maps:get(payment_info, Context, undefined).

%% Event utils

-spec wrap_events([event_payload()], t()) -> events().
wrap_events(Events, T) ->
    [wrap_event(Ev, T) || Ev <- Events].

-spec wrap_event(event_payload(), t()) -> event().
wrap_event(Event, T) ->
    ?refund_ev(id(T), Event).

-spec update_state_with(events(), t()) -> t().
update_state_with(Events, T) ->
    lists:foldl(
        fun(Ev, State) -> apply_event(Ev, State, undefined) end,
        T,
        Events
    ).

-spec apply_event(event(), t() | undefined, event_context() | undefined) -> t().
apply_event(?refund_ev(_ID, ?refund_created(Refund, Cashflow, TransactionInfo)), undefined, Context) ->
    genlib_map:compact(#{
        refund => Refund,
        cash_flow => Cashflow,
        sessions => [],
        transaction_info => TransactionInfo,
        status => pending,
        remaining_payment_amount => maps:get(remaining_payment_amount, Context),
        retry_attempts => 0,
        route => maps:get(route, Context),
        session_context => maps:get(session_context, Context)
    });
apply_event(?refund_ev(_ID, Event), Refund, Context) ->
    apply_event_(Event, Refund, Context).

apply_event_(?refund_status_changed(Status = {StatusTag, _}), Refund, _Context) ->
    DomainRefund = refund(Refund),
    Refund#{status := StatusTag, refund := DomainRefund#domain_InvoicePaymentRefund{status = Status}};
apply_event_(?refund_rollback_started(Failure), Refund, _Context) ->
    Refund#{failure => Failure};
apply_event_(?session_ev(?refunded(), Event = ?session_started()), Refund = #{session_context := Context}, _) ->
    Session = hg_session:apply_event(Event, undefined, Context),
    add_refund_session(Session, Refund);
apply_event_(?session_ev(?refunded(), Event), Refund = #{session_context := Context}, _) ->
    Session = hg_session:apply_event(Event, session(Refund), Context),
    update_refund_session(Session, Refund).

add_refund_session(Session, Refund0) ->
    OldSessions = sessions(Refund0),
    Refund1 = save_retry_attempt(Refund0),
    Refund1#{sessions => [Session | OldSessions]}.

update_refund_session(Session, Refund) ->
    %% Replace recent session with updated one
    OldSessions = sessions(Refund),
    Refund#{sessions => [Session | tl(OldSessions)]}.

save_retry_attempt(Refund) ->
    Attempts = retry_attempts(Refund),
    Refund#{retry_attempts := Attempts + 1}.
