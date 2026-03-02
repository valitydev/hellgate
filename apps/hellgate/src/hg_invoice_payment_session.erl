%%% Payment session management module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Contains all session-related functions.

-module(hg_invoice_payment_session).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").

-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").

%% Types
-type st() :: hg_invoice_payment:st().
-type target() :: hg_invoice_payment:target().
-type session_target_type() :: hg_invoice_payment:session_target_type().
-type session() :: hg_invoice_payment:session().
-type activity() :: hg_invoice_payment:activity().
-type callback() :: hg_session:callback().
-type callback_response() :: hg_session:callback_response().
-type machine_result() :: hg_invoice_payment:machine_result().
-type result() :: hg_invoice_payment:result().
-type events() :: hg_invoice_payment:events().
-type failure() :: hg_invoice_payment:failure().
-type retry_strategy() :: hg_retry:strategy().
-type action() :: hg_machine_action:action().
-type change_opts() :: hg_invoice_payment:change_opts().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type cart() :: dmsl_domain_thrift:'InvoiceCart'().
-type allocation() :: hg_allocation:allocation() | undefined.

%% Session management functions
-export([process_session/1]).
-export([process_session/2]).
-export([handle_callback/4]).
-export([finish_session_processing/4]).
-export([add_session/3]).
-export([create_session_event_context/3]).
-export([get_activity_session/1]).
-export([get_activity_session/2]).
-export([get_session/2]).
-export([update_session/3]).
-export([retry_session/3]).
-export([check_retry_possibility/3]).
-export([get_initial_retry_strategy/1]).
-export([get_actual_retry_strategy/2]).
-export([check_failure_type/2]).
-export([get_error_class/1]).
-export([do_check_failure_type/1]).
-export([start_session/1]).
-export([start_capture/4]).
-export([start_partial_capture/5]).

%%% Session processing

-spec process_session(st()) -> machine_result().
process_session(St) ->
    Session = get_activity_session(St),
    process_session(Session, St).

-spec process_session(session() | undefined, st()) -> machine_result().
process_session(undefined, St0) ->
    Target = hg_invoice_payment:get_target(St0),
    TargetType = hg_invoice_payment:get_target_type(Target),
    Action = hg_machine_action:new(),
    case
        hg_invoice_payment_validation:validate_processing_deadline(
            hg_invoice_payment:get_payment(St0), TargetType
        )
    of
        ok ->
            Events = start_session(Target),
            Result = {Events, hg_machine_action:set_timeout(0, Action)},
            {next, Result};
        Failure ->
            hg_invoice_payment:process_failure(
                hg_invoice_payment:get_activity(St0), [], Action, Failure, St0
            )
    end;
process_session(Session0, #st{repair_scenario = Scenario} = St) ->
    Session1 =
        case hg_invoice_repair:check_for_action(repair_session, Scenario) of
            RepairScenario = {result, _} ->
                hg_session:set_repair_scenario(RepairScenario, Session0);
            call ->
                Session0
        end,
    PaymentInfo = hg_invoice_payment:construct_payment_info(St, hg_invoice_payment:get_opts(St)),
    Session2 = hg_session:set_payment_info(PaymentInfo, Session1),
    {Result, Session3} = hg_session:process(Session2),
    finish_session_processing(hg_invoice_payment:get_activity(St), Result, Session3, St).

-spec handle_callback(activity(), callback(), hg_session:t(), st()) -> {callback_response(), machine_result()}.
handle_callback({refund, ID}, Payload, _Session0, St) ->
    PaymentInfo = hg_invoice_payment:construct_payment_info(St, hg_invoice_payment:get_opts(St)),
    Refund = hg_invoice_payment:try_get_refund_state(ID, St),
    {Resp, {Step, {Events0, Action}}} = hg_invoice_payment_refund:process_callback(Payload, PaymentInfo, Refund),
    Events1 = hg_invoice_payment_refund:wrap_events(Events0, Refund),
    {Resp, {Step, {Events1, Action}}};
handle_callback(Activity, Payload, Session0, St) ->
    PaymentInfo = hg_invoice_payment:construct_payment_info(St, hg_invoice_payment:get_opts(St)),
    Session1 = hg_session:set_payment_info(PaymentInfo, Session0),
    {Response, {Result, Session2}} = hg_session:process_callback(Payload, Session1),
    {Response, finish_session_processing(Activity, Result, Session2, St)}.

-spec finish_session_processing(activity(), result(), hg_session:t(), st()) -> machine_result().
finish_session_processing(Activity, {Events0, Action}, Session, St0) ->
    Events1 = hg_session:wrap_events(Events0, Session),
    case {hg_session:status(Session), hg_session:result(Session)} of
        {finished, ?session_succeeded()} ->
            TargetType = hg_invoice_payment:get_target_type(hg_session:target(Session)),
            _ = hg_invoice_payment:maybe_notify_fault_detector(Activity, TargetType, finish, St0),
            NewAction = hg_machine_action:set_timeout(0, Action),
            InvoiceID = hg_invoice_payment:get_invoice_id(
                hg_invoice_payment:get_invoice(hg_invoice_payment:get_opts(St0))
            ),
            St1 = hg_invoice_payment:collapse_changes(Events1, St0, #{invoice_id => InvoiceID}),
            _ =
                case St1 of
                    #st{new_cash_provided = true, activity = {payment, processing_accounter}} ->
                        %% Revert with St0 cause default rollback takes into account new cash
                        %% We need to rollback only current route.
                        %% Previously used routes are supposed to have their limits already rolled back.
                        Route = hg_invoice_payment:get_route(St0),
                        Routes = [Route],
                        _ = hg_invoice_payment:rollback_payment_limits(
                            Routes, hg_invoice_payment:get_iter(St0), St0, []
                        ),
                        _ = hg_invoice_payment:rollback_payment_cashflow(St0);
                    _ ->
                        ok
                end,
            {next, {Events1, NewAction}};
        {finished, ?session_failed(Failure)} ->
            hg_invoice_payment:process_failure(Activity, Events1, Action, Failure, St0);
        _ ->
            {next, {Events1, Action}}
    end.

%%% Session accessors

-spec get_session(target(), st()) -> session().
get_session(Target, #st{sessions = Sessions, routes = [Route | _PreviousRoutes]}) ->
    TargetSessions = maps:get(hg_invoice_payment:get_target_type(Target), Sessions, []),
    MatchingRoute = fun(#{route := SR}) -> SR =:= Route end,
    case lists:search(MatchingRoute, TargetSessions) of
        {value, Session} -> Session;
        _ -> undefined
    end.

-spec add_session(target(), session(), st()) -> st().
add_session(Target, Session, #st{sessions = Sessions} = St) ->
    TargetType = hg_invoice_payment:get_target_type(Target),
    TargetTypeSessions = maps:get(TargetType, Sessions, []),
    St#st{sessions = Sessions#{TargetType => [Session | TargetTypeSessions]}}.

-spec update_session(target(), session(), st()) -> st().
update_session(Target, Session, #st{sessions = Sessions} = St) ->
    TargetType = hg_invoice_payment:get_target_type(Target),
    [_ | Rest] = maps:get(TargetType, Sessions, []),
    St#st{sessions = Sessions#{TargetType => [Session | Rest]}}.

-spec get_activity_session(st()) -> session() | undefined.
get_activity_session(St) ->
    get_activity_session(hg_invoice_payment:get_activity(St), St).

-spec get_activity_session(activity(), st()) -> session() | undefined.
get_activity_session({payment, _Step}, St) ->
    get_session(hg_invoice_payment:get_target(St), St);
get_activity_session({refund, ID}, St) ->
    Refund = hg_invoice_payment:try_get_refund_state(ID, St),
    hg_invoice_payment_refund:session(Refund).

%%% Session creation

-spec start_session(target()) -> events().
start_session(Target) ->
    [hg_session:wrap_event(Target, hg_session:create())].

-spec start_capture(binary(), cash(), undefined | cart(), undefined | allocation()) -> events().
start_capture(Reason, Cost, Cart, Allocation) ->
    [?payment_capture_started(Reason, Cost, Cart, Allocation)] ++
        start_session(?captured(Reason, Cost, Cart, Allocation)).

-spec start_partial_capture(binary(), cash(), cart(), hg_cashflow:final_cash_flow(), allocation()) -> events().
start_partial_capture(Reason, Cost, Cart, FinalCashflow, Allocation) ->
    [
        ?payment_capture_started(Reason, Cost, Cart, Allocation),
        ?cash_flow_changed(FinalCashflow)
    ].

%%% Session event context

-spec create_session_event_context(target(), st(), change_opts()) -> hg_session:event_context().
create_session_event_context(Target, St, #{invoice_id := InvoiceID} = Opts) ->
    #{
        timestamp => define_event_timestamp(Opts),
        target => Target,
        route => hg_invoice_payment:get_route(St),
        invoice_id => InvoiceID,
        payment_id => hg_invoice_payment:get_payment_id(hg_invoice_payment:get_payment(St))
    }.

-spec define_event_timestamp(change_opts()) -> integer().
define_event_timestamp(#{timestamp := Dt}) ->
    hg_datetime:parse(Dt, millisecond);
define_event_timestamp(#{}) ->
    erlang:system_time(millisecond).

%%% Session retry

-spec retry_session(action(), target(), non_neg_integer()) -> {events(), action()}.
retry_session(Action, Target, Timeout) ->
    NewEvents = start_session(Target),
    NewAction = set_timer({timeout, Timeout}, Action),
    {NewEvents, NewAction}.

-spec get_actual_retry_strategy(target(), st()) -> retry_strategy().
get_actual_retry_strategy(Target, #st{retry_attempts = Attempts}) ->
    AttemptNum = maps:get(hg_invoice_payment:get_target_type(Target), Attempts, 0),
    hg_retry:skip_steps(get_initial_retry_strategy(hg_invoice_payment:get_target_type(Target)), AttemptNum).

-spec get_initial_retry_strategy(session_target_type()) -> retry_strategy().
get_initial_retry_strategy(TargetType) ->
    PolicyConfig = genlib_app:env(hellgate, payment_retry_policy, #{}),
    hg_retry:new_strategy(maps:get(TargetType, PolicyConfig, no_retry)).

-spec check_retry_possibility(Target, Failure, St) -> {retry, Timeout} | fatal when
    Failure :: failure(),
    Target :: target(),
    St :: st(),
    Timeout :: non_neg_integer().
check_retry_possibility(Target, Failure, St) ->
    case check_failure_type(Target, Failure) of
        transient ->
            RetryStrategy = get_actual_retry_strategy(Target, St),
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

-spec check_failure_type(target(), failure()) -> transient | fatal.
check_failure_type(Target, {failure, Failure}) ->
    payproc_errors:match(get_error_class(Target), Failure, fun do_check_failure_type/1);
check_failure_type(_Target, _Other) ->
    fatal.

-spec get_error_class(target()) -> atom().
get_error_class({Target, _}) when Target =:= processed; Target =:= captured; Target =:= cancelled ->
    'PaymentFailure';
get_error_class(Target) ->
    error({unsupported_target, Target}).

-spec do_check_failure_type(failure()) -> transient | fatal.
do_check_failure_type({authorization_failed, {temporarily_unavailable, _}}) ->
    transient;
do_check_failure_type(_Failure) ->
    fatal.

-spec set_timer(term(), action()) -> action().
set_timer(Timer, Action) ->
    hg_machine_action:set_timer(Timer, Action).
