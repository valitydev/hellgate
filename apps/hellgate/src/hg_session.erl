-module(hg_session).

-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").
-include("payment_events.hrl").

-type t() :: #{
    target := target(),
    status := session_status(),
    trx := hg_maybe:maybe(trx_info()),
    tags := [tag()],
    timeout_behaviour := timeout_behaviour(),
    context := tag_context(),
    route := route(),
    payment_info := payment_info(),
    result => session_result(),
    proxy_state => proxy_state(),
    timings => timings(),
    repair_scenario => repair_scenario()
}.

-type event_context() :: #{
    timestamp := integer(),
    route => route(),
    invoice_id => binary(),
    payment_id => binary()
}.

-type process_result() :: {result(), t()}.
-type tag_context() :: #{
    invoice_id := binary(),
    payment_id := binary()
}.

-type repair_scenario() :: {result, proxy_result()}.

-export_type([t/0]).
-export_type([event_context/0]).
-export_type([process_result/0]).

%% Accessors

-export([target/1]).
-export([status/1]).
-export([trx_info/1]).
-export([tags/1]).
-export([tag_context/1]).
-export([route/1]).
-export([payment_info/1]).
-export([result/1]).
-export([timeout_behaviour/1]).
-export([proxy_state/1]).
-export([timings/1]).
-export([repair_scenario/1]).

%% API

-export([set_repair_scenario/2]).
-export([set_payment_info/2]).
-export([set_trx_info/2]).

-export([create/1]).
-export([deduce_activity/1]).
-export([apply_event/3]).

-export([process/1]).
-export([process_callback/2]).

%% Internal types

-type target() :: dmsl_domain_thrift:'TargetInvoicePaymentStatus'().
-type session_status() :: active | suspended | finished.
-type trx_info() :: dmsl_domain_thrift:'TransactionInfo'().
-type tag() :: dmsl_proxy_provider_thrift:'CallbackTag'().
-type timeout_behaviour() :: dmsl_timeout_behaviour_thrift:'TimeoutBehaviour'().
-type session_result() :: dmsl_payproc_thrift:'SessionResult'().
-type proxy_state() :: dmsl_proxy_provider_thrift:'ProxyState'().
-type proxy_result() :: dmsl_proxy_provider_thrift:'PaymentProxyResult'().
-type route() :: dmsl_domain_thrift:'PaymentRoute'().
-type payment_info() :: dmsl_proxy_provider_thrift:'PaymentInfo'().
-type timings() :: hg_timings:t().

-type event() :: dmsl_payproc_thrift:'InvoicePaymentChangePayload'().
-type event_payload() :: dmsl_payproc_thrift:'SessionChangePayload'().
-type events() :: [event()].
-type action() :: hg_machine_action:t().
-type result() :: {events(), action()}.

-type callback() :: dmsl_proxy_provider_thrift:'Callback'().
-type callback_response() :: dmsl_proxy_provider_thrift:'CallbackResponse'().

-type activity() ::
    repair
    | active
    | suspended
    | finished.

%% Accessors

-spec target(t()) -> target().
target(#{target := V}) ->
    V.

-spec status(t()) -> session_status().
status(#{status := V}) ->
    V.

-spec trx_info(t()) -> hg_maybe:maybe(trx_info()).
trx_info(#{trx := V}) ->
    V.

-spec tags(t()) -> [tag()].
tags(#{tags := V}) ->
    V.

-spec tag_context(t()) -> tag_context().
tag_context(#{context := V}) ->
    V.

-spec route(t()) -> route().
route(#{route := V}) ->
    V.

-spec payment_info(t()) -> payment_info().
payment_info(#{payment_info := V}) ->
    V.

-spec result(t()) -> hg_maybe:maybe(session_result()).
result(T) ->
    maps:get(result, T, undefined).

-spec timeout_behaviour(t()) -> timeout_behaviour().
timeout_behaviour(#{timeout_behaviour := V}) ->
    V.

-spec proxy_state(t()) -> hg_maybe:maybe(proxy_state()).
proxy_state(T) ->
    maps:get(proxy_state, T, undefined).

-spec timings(t()) -> hg_maybe:maybe(timings()).
timings(T) ->
    maps:get(timings, T, undefined).

-spec repair_scenario(t()) -> hg_maybe:maybe(repair_scenario()).
repair_scenario(T) ->
    maps:get(repair_scenario, T, undefined).

%% API

-spec set_repair_scenario(repair_scenario(), t()) -> t().
set_repair_scenario(Scenario, Session) ->
    Session#{repair_scenario => Scenario}.

-spec set_payment_info(payment_info(), t()) -> t().
set_payment_info(PaymentInfo, Session) ->
    Session#{payment_info => PaymentInfo}.

-spec set_trx_info(hg_maybe:maybe(trx_info()), t()) -> t().
set_trx_info(Trx, Session) ->
    Session#{trx := Trx}.

-spec create(target()) -> events().
create(Target) ->
    [?session_ev(Target, ?session_started())].

-spec process(t()) -> process_result().
process(Session) ->
    Activity = deduce_activity(Session),
    do_process(Activity, Session).

-spec process_callback(callback(), t()) -> {callback_response(), process_result()}.
process_callback(Payload, Session) ->
    {ok, CallbackResult} = process_session_callback(Payload, Session),
    {Response, Result} = handle_callback_result(CallbackResult, Session),
    {Response, apply_result(Result, Session)}.

-spec deduce_activity(t()) -> activity().
deduce_activity(#{repair_scenario := Scenario}) when Scenario =/= undefined ->
    repair;
deduce_activity(#{status := active}) ->
    active;
deduce_activity(#{status := suspended}) ->
    suspended;
deduce_activity(#{status := finished}) ->
    finished.

do_process(repair, Session) ->
    repair(Session);
do_process(active, Session) ->
    process_active_session(Session);
do_process(suspended, Session) ->
    process_callback_timeout(Session);
do_process(finished, Session) ->
    {[], Session}.

repair(Session = #{repair_scenario := {result, ProxyResult}}) ->
    Result = handle_proxy_result(ProxyResult, Session),
    apply_result(Result, Session).

process_active_session(Session) ->
    {ok, ProxyResult} = process_session(Session),
    Result = handle_proxy_result(ProxyResult, Session),
    apply_result(Result, Session).

process_callback_timeout(Session) ->
    case timeout_behaviour(Session) of
        {callback, Payload} ->
            {ok, CallbackResult} = process_session_callback(Payload, Session),
            {_Response, Result} = handle_callback_result(CallbackResult, Session),
            apply_result(Result, Session);
        {operation_failure, OperationFailure} ->
            SessionEvents = [?session_finished(?session_failed(OperationFailure))],
            Result = {wrap_session_events(SessionEvents, Session), hg_machine_action:new()},
            apply_result(Result, Session)
    end.

%% Internal

process_session(Session) ->
    ProxyContext = construct_proxy_context(Session),
    Route = route(Session),
    try
        hg_proxy_provider:process_payment(ProxyContext, Route)
    catch
        error:{woody_error, {_Source, result_unexpected, _Details}} = Reason:StackTrace ->
            % It looks like an unexpected error here is equivalent to a failed operation
            % in terms of conversion
            _ = maybe_notify_fault_detector(target(Session), error, Session),
            erlang:raise(error, Reason, StackTrace)
    end.

process_session_callback(Payload, Session) ->
    ProxyContext = construct_proxy_context(Session),
    Route = route(Session),
    try
        hg_proxy_provider:handle_payment_callback(Payload, ProxyContext, Route)
    catch
        error:{woody_error, {_Source, result_unexpected, _Details}} = Reason:StackTrace ->
            % It looks like an unexpected error here is equivalent to a failed operation
            % in terms of conversion
            _ = maybe_notify_fault_detector(target(Session), error, Session),
            erlang:raise(error, Reason, StackTrace)
    end.

construct_proxy_context(Session) ->
    #proxy_provider_PaymentContext{
        session = construct_session(Session),
        payment_info = payment_info(Session),
        options = hg_proxy_provider:collect_proxy_options(route(Session))
    }.

construct_session(Session) ->
    #proxy_provider_Session{
        target = target(Session),
        state = proxy_state(Session)
    }.

maybe_notify_fault_detector({processed, _}, Status, Session) ->
    #domain_PaymentRoute{provider = ProviderRef} = route(Session),
    ProviderID = ProviderRef#domain_ProviderRef.id,
    #{payment_id := PaymentID, invoice_id := InvoiceID} = tag_context(Session),
    ServiceType = provider_conversion,
    OperationID = hg_fault_detector_client:build_operation_id(ServiceType, [InvoiceID, PaymentID]),
    ServiceID = hg_fault_detector_client:build_service_id(ServiceType, ProviderID),
    hg_fault_detector_client:register_transaction(Status, ServiceID, OperationID);
maybe_notify_fault_detector(_TargetType, _Status, _St) ->
    ok.

handle_proxy_result(
    #proxy_provider_PaymentProxyResult{intent = {_Type, Intent}, trx = Trx, next_state = ProxyState},
    Session
) ->
    Events1 = wrap_session_events(hg_proxy_provider:bind_transaction(Trx, Session), Session),
    Events2 = update_proxy_state(ProxyState, Session),
    {Events3, Action} = handle_proxy_intent(Intent, hg_machine_action:new(), Session),
    {lists:flatten([Events1, Events2, Events3]), Action}.

handle_callback_result(
    #proxy_provider_PaymentCallbackResult{result = ProxyResult, response = Response},
    Session
) ->
    {Response, handle_proxy_callback_result(ProxyResult, Session)}.

handle_proxy_callback_result(
    #proxy_provider_PaymentCallbackProxyResult{intent = {_Type, Intent}, trx = Trx, next_state = ProxyState},
    Session
) ->
    Events0 = [wrap_session_event(?session_activated(), Session)],
    Events1 = wrap_session_events(hg_proxy_provider:bind_transaction(Trx, Session), Session),
    Events2 = update_proxy_state(ProxyState, Session),
    {Events3, Action} = handle_proxy_intent(Intent, hg_machine_action:unset_timer(hg_machine_action:new()), Session),
    {lists:flatten([Events0, Events1, Events2, Events3]), Action};
handle_proxy_callback_result(
    #proxy_provider_PaymentCallbackProxyResult{intent = undefined, trx = Trx, next_state = ProxyState},
    Session
) ->
    Events1 = hg_proxy_provider:bind_transaction(Trx, Session),
    Events2 = update_proxy_state(ProxyState, Session),
    {wrap_session_events(Events1 ++ Events2, Session), hg_machine_action:new()}.

apply_result(Result = {Events, _Action}, T) ->
    {Result, update_state_with(Events, T)}.

update_proxy_state(undefined, _Session) ->
    [];
update_proxy_state(ProxyState, Session) ->
    case proxy_state(Session) of
        ProxyState ->
            % proxy state did not change, no need to publish an event
            [];
        _WasState ->
            [wrap_session_event(?proxy_st_changed(ProxyState), Session)]
    end.

handle_proxy_intent(#proxy_provider_FinishIntent{status = {success, Success}}, Action, Session) ->
    Events0 = [wrap_session_event(?session_finished(?session_succeeded()), Session)],
    Events1 =
        case Success of
            #proxy_provider_Success{token = undefined} ->
                Events0;
            #proxy_provider_Success{token = Token} ->
                [?rec_token_acquired(Token) | Events0]
        end,
    {Events1, Action};
handle_proxy_intent(#proxy_provider_FinishIntent{status = {failure, Failure}}, Action, Session) ->
    Events = [wrap_session_event(?session_finished(?session_failed({failure, Failure})), Session)],
    {Events, Action};
handle_proxy_intent(
    #proxy_provider_SleepIntent{timer = Timer, user_interaction = UserInteraction},
    Action0,
    Session
) ->
    Action1 = hg_machine_action:set_timer(Timer, Action0),
    Events = wrap_session_events(try_request_interaction(UserInteraction), Session),
    {Events, Action1};
handle_proxy_intent(
    #proxy_provider_SuspendIntent{
        tag = Tag,
        timeout = Timer,
        user_interaction = UserInteraction,
        timeout_behaviour = TimeoutBehaviour
    },
    Action0,
    Session
) ->
    #{payment_id := PaymentID, invoice_id := InvoiceID} = tag_context(Session),
    ok = hg_machine_tag:create_binding(hg_invoice:namespace(), Tag, PaymentID, InvoiceID),
    Action1 = hg_machine_action:set_timer(Timer, Action0),
    Events = [?session_suspended(Tag, TimeoutBehaviour) | try_request_interaction(UserInteraction)],
    {wrap_session_events(Events, Session), Action1}.

try_request_interaction(undefined) ->
    [];
try_request_interaction(UserInteraction) ->
    [?interaction_requested(UserInteraction)].

%% Event utils

-spec wrap_session_events([event_payload()], t()) -> events().
wrap_session_events(SessionEvents, Session) ->
    [wrap_session_event(Ev, Session) || Ev <- SessionEvents].

-spec wrap_session_event(event_payload(), t()) -> event().
wrap_session_event(SessionEvent, Session) ->
    ?session_ev(target(Session), SessionEvent).

-spec update_state_with(events(), t()) -> t().
update_state_with(Events, T) ->
    Context = #{timestamp => erlang:system_time(millisecond)},
    lists:foldl(
        fun(Ev, State) -> apply_event(Ev, State, Context) end,
        T,
        Events
    ).

-spec apply_event(event(), t() | undefined, event_context()) -> t().
apply_event(?session_ev(Target, ?session_started()), undefined, Context) ->
    Session0 = create_session(Target, Context),
    mark_timing_event(started, Context, Session0);
apply_event(?session_ev(_Target, Event), Session, Context) ->
    apply_event_(Event, Session, Context);
%% Ignore ?rec_token_acquired event cause it's easiest way to handle this
%% TODO maybe add this token to session state and remove it from payment state?
apply_event(?rec_token_acquired(_Token), Session, _Context) ->
    Session.

apply_event_(?session_finished(Result), Session, Context) ->
    Session2 = Session#{status => finished, result => Result},
    accrue_timing(finished, started, Context, Session2);
apply_event_(?session_activated(), Session, Context) ->
    Session2 = Session#{status => active},
    accrue_timing(suspended, suspended, Context, Session2);
apply_event_(?session_suspended(Tag, TimeoutBehaviour), Session, Context) ->
    Session2 = set_tag(Tag, Session),
    Session3 = set_timeout_behaviour(TimeoutBehaviour, Session2),
    Session4 = mark_timing_event(suspended, Context, Session3),
    Session4#{status => suspended};
apply_event_(?trx_bound(Trx), Session, _Context) ->
    Session#{trx => Trx};
apply_event_(?proxy_st_changed(ProxyState), Session, _Context) ->
    Session#{proxy_state => ProxyState};
apply_event_(?interaction_requested(_), Session, _Context) ->
    Session.

create_session(Target, #{route := Route, invoice_id := InvoiceID, payment_id := PaymentID}) ->
    #{
        target => Target,
        status => active,
        trx => undefined,
        tags => [],
        timeout_behaviour => {operation_failure, ?operation_timeout()},
        context => #{
            invoice_id => InvoiceID,
            payment_id => PaymentID
        },
        route => Route
    }.

set_timeout_behaviour(undefined, Session) ->
    Session#{timeout_behaviour => {operation_failure, ?operation_timeout()}};
set_timeout_behaviour(TimeoutBehaviour, Session) ->
    Session#{timeout_behaviour => TimeoutBehaviour}.

set_tag(undefined, Session) ->
    Session;
set_tag(Tag, Session) ->
    Session#{tags := [Tag | tags(Session)]}.

set_session_timings(Timings, Session) ->
    Session#{timings => Timings}.

get_session_timings(Session) ->
    maps:get(timings, Session, hg_timings:new()).

accrue_timing(Name, Event, #{timestamp := Timestamp}, Session) ->
    Timings = get_session_timings(Session),
    set_session_timings(hg_timings:accrue(Name, Event, Timestamp, Timings), Session).

mark_timing_event(Event, #{timestamp := Timestamp}, Session) ->
    Timings = get_session_timings(Session),
    set_session_timings(hg_timings:mark(Event, Timestamp, Timings), Session).
