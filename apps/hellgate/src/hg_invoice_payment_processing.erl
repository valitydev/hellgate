%%% Payment processing module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Handles payment processing signals, calls, timeouts, results, and failures.

-module(hg_invoice_payment_processing).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").
-include_lib("hellgate/include/allocation.hrl").

-include("hg_invoice_payment.hrl").
-include("domain.hrl").
-include("payment_events.hrl").

%% API - exported for use by hg_invoice_payment
-export([process_signal/3]).
-export([process_call/3]).
-export([process_timeout/3]).
-export([process_result/2]).
-export([process_result/3]).
-export([process_failure/5]).
-export([process_failure/6]).
-export([process_fatal_payment_failure/5]).
-export([process_chargeback/4]).
-export([process_accounter_update/2]).
-export([finalize_payment/2]).
-export([process_shop_limit_initialization/2]).
-export([process_shop_limit_failure/2]).
-export([process_shop_limit_finalization/2]).
-export([repair_process_timeout/3]).
-export([get_action/3]).
-export([maybe_set_charged_back_status/3]).

%% Internal helpers
-export([process_timeout/1]).
-export([process_callback/3]).
-export([process_callback/4]).
-export([process_session_change/3]).
-export([process_session_change/4]).
-export([process_refund/2]).
-export([process_refund_result/3]).
-export([construct_shop_limit_failure/2]).
-export([check_recurrent_token/1]).
-export([choose_fd_operation_status_for_failure/1]).
-export([do_choose_fd_operation_status_for_failure/1]).

-type activity() :: hg_invoice_payment:activity().
-type st() :: hg_invoice_payment:st().
-type opts() :: hg_invoice_payment:opts().
-type action() :: hg_machine_action:t().
-type machine_result() :: hg_invoice_payment:machine_result().
-type tag() :: dmsl_proxy_provider_thrift:'CallbackTag'().
-type callback() :: dmsl_proxy_provider_thrift:'Callback'().
-type session_change() :: hg_session:change().
-type callback_response() :: dmsl_proxy_provider_thrift:'CallbackResponse'().
-type failure() :: hg_invoice_payment:failure().
-type change() :: hg_invoice_payment:change().
-type chargeback_activity_type() :: hg_invoice_payment_chargeback:activity().
-type chargeback_id() :: hg_invoice_payment_chargeback:id().
-type target() :: hg_invoice_payment:target().
-type refund_id() :: hg_invoice_payment:refund_id().
-type adjustment_id() :: hg_invoice_payment:adjustment_id().

%%% API

-spec process_signal(timeout, st(), opts()) -> machine_result().
process_signal(timeout, St, Options) ->
    scoper:scope(
        payment,
        hg_invoice_payment:get_st_meta(St),
        fun() -> process_timeout(St#st{opts = Options}) end
    ).

-spec process_timeout(st()) -> machine_result().
process_timeout(St) ->
    Action = hg_machine_action:new(),
    repair_process_timeout(hg_invoice_payment:get_activity(St), Action, St).

-spec process_timeout(activity(), action(), st()) -> machine_result().
process_timeout({payment, shop_limit_initializing}, Action, St) ->
    process_shop_limit_initialization(Action, St);
process_timeout({payment, shop_limit_failure}, Action, St) ->
    process_shop_limit_failure(Action, St);
process_timeout({payment, shop_limit_finalizing}, Action, St) ->
    process_shop_limit_finalization(Action, St);
process_timeout({payment, risk_scoring}, Action, St) ->
    hg_invoice_payment_routing:process_risk_score(Action, St);
process_timeout({payment, routing}, Action, St) ->
    hg_invoice_payment_routing:process_routing(Action, St);
process_timeout({payment, cash_flow_building}, Action, St) ->
    hg_invoice_payment_cashflow:process_cash_flow_building(Action, St);
process_timeout({payment, Step}, _Action, St) when
    Step =:= processing_session orelse
        Step =:= finalizing_session
->
    hg_invoice_payment_session:process_session(St);
process_timeout({payment, Step}, Action, St) when
    Step =:= processing_failure orelse
        Step =:= routing_failure orelse
        Step =:= processing_accounter orelse
        Step =:= finalizing_accounter
->
    process_result(Action, St);
process_timeout({payment, updating_accounter}, Action, St) ->
    process_accounter_update(Action, St);
process_timeout({chargeback, ID, Type}, Action, St) ->
    process_chargeback(Type, ID, Action, St);
process_timeout({refund, ID}, _Action, St) ->
    process_refund(ID, St);
process_timeout({adjustment_new, ID}, Action, St) ->
    hg_invoice_payment_adjustment:process_adjustment_cashflow(ID, Action, St);
process_timeout({adjustment_pending, ID}, Action, St) ->
    process_adjustment_capture(ID, Action, St);
process_timeout({payment, flow_waiting}, Action, St) ->
    finalize_payment(Action, St).

-spec process_adjustment_capture(adjustment_id(), action(), st()) -> machine_result().
process_adjustment_capture(ID, _Action, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    Adjustment = hg_invoice_payment:get_adjustment(ID, St),
    ok = hg_invoice_payment_validation:assert_adjustment_status(processed, Adjustment),
    ok = hg_invoice_payment_adjustment:finalize_adjustment_cashflow(Adjustment, St, Opts),
    Status = ?adjustment_captured(maps:get(timestamp, Opts)),
    Event = ?adjustment_ev(ID, ?adjustment_status_changed(Status)),
    {done, {[Event], hg_machine_action:new()}}.

-spec process_call
    ({callback, tag(), callback()}, st(), opts()) -> {callback_response(), machine_result()};
    ({session_change, tag(), session_change()}, st(), opts()) -> {ok, machine_result()}.
process_call({callback, Tag, Payload}, St, Options) ->
    scoper:scope(
        payment,
        hg_invoice_payment:get_st_meta(St),
        fun() -> process_callback(Tag, Payload, St#st{opts = Options}) end
    );
process_call({session_change, Tag, SessionChange}, St, Options) ->
    scoper:scope(
        payment,
        hg_invoice_payment:get_st_meta(St),
        fun() -> process_session_change(Tag, SessionChange, St#st{opts = Options}) end
    ).

-spec process_callback(tag(), callback(), st()) -> {callback_response(), machine_result()}.
process_callback(Tag, Payload, St) ->
    Session = hg_invoice_payment_session:get_activity_session(St),
    process_callback(Tag, Payload, Session, St).

-spec process_callback(tag(), callback(), hg_session:t() | undefined, st()) ->
    {callback_response(), machine_result()}.
process_callback(Tag, Payload, Session, St) when Session /= undefined ->
    case {hg_session:status(Session), hg_session:tags(Session)} of
        {suspended, [Tag | _]} ->
            hg_invoice_payment_session:handle_callback(hg_invoice_payment:get_activity(St), Payload, Session, St);
        _ ->
            throw(invalid_callback)
    end;
process_callback(_Tag, _Payload, undefined, _St) ->
    throw(invalid_callback).

-spec process_session_change(tag(), session_change(), st()) -> {ok, machine_result()}.
process_session_change(Tag, SessionChange, St) ->
    Session = hg_invoice_payment_session:get_activity_session(St),
    process_session_change(Tag, SessionChange, Session, St).

-spec process_session_change(tag(), session_change(), hg_session:t() | undefined, st()) ->
    {ok, machine_result()}.
process_session_change(Tag, SessionChange, Session0, St) when Session0 /= undefined ->
    %% NOTE Change allowed only for suspended session. Not suspended
    %% session does not have registered callback with tag.
    case {hg_session:status(Session0), hg_session:tags(Session0)} of
        {suspended, [Tag | _]} ->
            {Result, Session1} = hg_session:process_change(SessionChange, Session0),
            {ok,
                hg_invoice_payment_session:finish_session_processing(
                    hg_invoice_payment:get_activity(St), Result, Session1, St
                )};
        _ ->
            throw(invalid_callback)
    end;
process_session_change(_Tag, _Payload, undefined, _St) ->
    throw(invalid_callback).

-spec process_shop_limit_initialization(action(), st()) -> machine_result().
process_shop_limit_initialization(Action, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    _ = hg_invoice_payment:hold_shop_limits(Opts, St),
    case hg_invoice_payment:check_shop_limits(Opts, St) of
        ok ->
            {next, {[?shop_limit_initiated()], hg_machine_action:set_timeout(0, Action)}};
        {error, {limit_overflow = Error, IDs}} ->
            Failure = construct_shop_limit_failure(Error, IDs),
            Events = [
                ?shop_limit_initiated(),
                ?payment_rollback_started(Failure)
            ],
            {next, {Events, hg_machine_action:set_timeout(0, Action)}}
    end.

-spec construct_shop_limit_failure(atom(), list()) -> failure().
construct_shop_limit_failure(limit_overflow, IDs) ->
    Error = mk_static_error([authorization_failed, shop_limit_exceeded, unknown]),
    Reason = genlib:format("Limits with following IDs overflowed: ~p", [IDs]),
    {failure, payproc_errors:construct('PaymentFailure', Error, Reason)}.

-type static_error() ::
    {atom() | {'unknown_error', binary()}, dmsl_payproc_error_thrift:'GeneralFailure'() | static_error()}.

-spec mk_static_error([atom(), ...]) -> static_error().
mk_static_error([_ | _] = Codes) ->
    mk_static_error_(#payproc_error_GeneralFailure{}, lists:reverse(Codes)).

-spec mk_static_error_(dmsl_payproc_error_thrift:'GeneralFailure'() | static_error(), [atom()]) -> static_error().
mk_static_error_(T, []) ->
    T;
mk_static_error_(Sub, [Code | Codes]) ->
    mk_static_error_({Code, Sub}, Codes).

-spec process_shop_limit_failure(action(), st()) -> machine_result().
process_shop_limit_failure(Action, #st{failure = Failure} = St) ->
    Opts = hg_invoice_payment:get_opts(St),
    _ = hg_invoice_payment:rollback_shop_limits(Opts, St, [ignore_business_error, ignore_not_found]),
    {done, {[?payment_status_changed(?failed(Failure))], hg_machine_action:set_timeout(0, Action)}}.

-spec process_shop_limit_finalization(action(), st()) -> machine_result().
process_shop_limit_finalization(Action, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    _ = hg_invoice_payment:commit_shop_limits(Opts, St),
    {next, {[?shop_limit_applied()], hg_machine_action:set_timeout(0, Action)}}.

-spec process_chargeback(chargeback_activity_type(), chargeback_id(), action(), st()) -> machine_result().
process_chargeback(finalising_accounter = Type, ID, Action0, St) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, St),
    ChargebackOpts = hg_invoice_payment:get_chargeback_opts(St),
    ChargebackBody = hg_invoice_payment_chargeback:get_body(ChargebackState),
    ChargebackTarget = hg_invoice_payment_chargeback:get_target_status(ChargebackState),
    MaybeChargedback = maybe_set_charged_back_status(ChargebackTarget, ChargebackBody, St),
    {Changes, Action1} = hg_invoice_payment_chargeback:process_timeout(Type, ChargebackState, Action0, ChargebackOpts),
    {done, {[?chargeback_ev(ID, C) || C <- Changes] ++ MaybeChargedback, Action1}};
process_chargeback(Type, ID, Action0, St) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, St),
    ChargebackOpts = hg_invoice_payment:get_chargeback_opts(St),
    {Changes0, Action1} = hg_invoice_payment_chargeback:process_timeout(Type, ChargebackState, Action0, ChargebackOpts),
    Changes1 = [?chargeback_ev(ID, C) || C <- Changes0],
    case Type of
        %% NOTE In case if payment is already charged back and we want
        %% to reopen and change it, this will ensure machine to
        %% continue processing activities following cashflow update
        %% event.
        updating_cash_flow ->
            {next, {Changes1, Action1}};
        _ ->
            {done, {Changes1, Action1}}
    end.

-spec maybe_set_charged_back_status(
    dmsl_domain_thrift:'InvoicePaymentChargebackStatus'(),
    dmsl_domain_thrift:'Cash'(),
    st()
) -> [change()].
maybe_set_charged_back_status(?chargeback_status_accepted(), ChargebackBody, St) ->
    InterimPaymentAmount = hg_invoice_payment:get_remaining_payment_balance(St),
    case hg_cash:sub(InterimPaymentAmount, ChargebackBody) of
        ?cash(0, _) ->
            [?payment_status_changed(?charged_back())];
        ?cash(Amount, _) when Amount > 0 ->
            []
    end;
maybe_set_charged_back_status(
    ?chargeback_status_cancelled(),
    _ChargebackBody,
    #st{
        payment = #domain_InvoicePayment{status = ?charged_back()},
        status_log = [_ActualStatus, PrevStatus | _]
    }
) ->
    [?payment_status_changed(PrevStatus)];
maybe_set_charged_back_status(_ChargebackStatus, _ChargebackBody, _St) ->
    [].

-spec process_accounter_update(action(), st()) -> machine_result().
process_accounter_update(Action, #st{partial_cash_flow = FinalCashflow, capture_data = CaptureData} = St) ->
    #payproc_InvoicePaymentCaptureData{
        reason = Reason,
        cash = Cost,
        cart = Cart,
        allocation = Allocation
    } = CaptureData,
    _Clock = hg_accounting:plan(
        hg_invoice_payment:construct_payment_plan_id(St),
        [
            {2, hg_cashflow:revert(hg_invoice_payment:get_cashflow(St))},
            {3, FinalCashflow}
        ]
    ),
    Events = hg_invoice_payment_session:start_session(?captured(Reason, Cost, Cart, Allocation)),
    {next, {Events, hg_machine_action:set_timeout(0, Action)}}.

-spec finalize_payment(action(), st()) -> machine_result().
finalize_payment(Action, St) ->
    Payment = hg_invoice_payment:get_payment(St),
    Target =
        case hg_invoice_payment:get_payment_flow(Payment) of
            ?invoice_payment_flow_instant() ->
                ?captured(<<"Timeout">>, hg_invoice_payment:get_payment_cost(Payment));
            ?invoice_payment_flow_hold(OnHoldExpiration, _) ->
                case OnHoldExpiration of
                    cancel ->
                        ?cancelled();
                    capture ->
                        ?captured(
                            <<"Timeout">>,
                            hg_invoice_payment:get_payment_cost(Payment)
                        )
                end
        end,
    StartEvents =
        case Target of
            ?captured(Reason, Cost) ->
                hg_invoice_payment_session:start_capture(
                    Reason, Cost, undefined, hg_invoice_payment:get_allocation(St)
                );
            _ ->
                hg_invoice_payment_session:start_session(Target)
        end,
    {done, {StartEvents, hg_machine_action:set_timeout(0, Action)}}.

-spec process_result(action(), st()) -> machine_result().
process_result(Action, St) ->
    process_result(hg_invoice_payment:get_activity(St), Action, St).

-spec process_result(activity(), action(), st()) -> machine_result().
process_result({payment, processing_accounter}, Action, #st{new_cash = Cost} = St0) when
    Cost =/= undefined
->
    %% Rebuild cashflow for new cost
    Payment0 = hg_invoice_payment:get_payment(St0),
    Payment1 = Payment0#domain_InvoicePayment{cost = Cost},
    St1 = St0#st{payment = Payment1},
    Opts = hg_invoice_payment:get_opts(St1),
    Revision = hg_invoice_payment:get_payment_revision(St1),
    Timestamp = hg_invoice_payment:get_payment_created_at(Payment0),
    VS = hg_invoice_payment_cashflow:collect_validation_varset(St1, Opts),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, Timestamp, VS),
    Route = hg_invoice_payment:get_route(St1),
    ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
    Context = #{
        provision_terms => ProviderTerms,
        merchant_terms => MerchantTerms,
        route => Route,
        payment => Payment1,
        timestamp => Timestamp,
        varset => VS,
        revision => Revision
    },
    FinalCashflow = hg_invoice_payment_cashflow:calculate_cashflow(Context, Opts),
    %% Hold limits (only for chosen route) for new cashflow
    {_PaymentInstitution, RouteVS, _Revision} = hg_invoice_payment_routing:route_args(St1),
    Routes = [hg_route:from_payment_route(Route)],
    _ = hg_invoice_payment:hold_limit_routes(Routes, RouteVS, hg_invoice_payment:get_iter(St1), St1),
    %% Hold cashflow
    St2 = St1#st{new_cash_flow = FinalCashflow},
    _Clock = hg_accounting:plan(
        hg_invoice_payment:construct_payment_plan_id(St2),
        hg_invoice_payment:get_cashflow_plan(St2)
    ),
    {next, {[?cash_flow_changed(FinalCashflow)], hg_machine_action:set_timeout(0, Action)}};
process_result({payment, processing_accounter}, Action, St) ->
    Target = hg_invoice_payment:get_target(St),
    NewAction = get_action(Target, Action, St),
    {done, {[?payment_status_changed(Target)], NewAction}};
process_result({payment, routing_failure}, Action, #st{failure = Failure} = St) ->
    NewAction = hg_machine_action:set_timeout(0, Action),
    Routes = hg_invoice_payment:get_candidate_routes(St),
    _ = hg_invoice_payment:rollback_payment_limits(Routes, hg_invoice_payment:get_iter(St), St, [
        ignore_business_error,
        ignore_not_found
    ]),
    {done, {[?payment_status_changed(?failed(Failure))], NewAction}};
process_result({payment, processing_failure}, Action, #st{failure = Failure} = St) ->
    NewAction = hg_machine_action:set_timeout(0, Action),
    %% We need to rollback only current route.
    %% Previously used routes are supposed to have their limits already rolled back.
    Route = hg_invoice_payment:get_route(St),
    Routes = [Route],
    _ = hg_invoice_payment:rollback_payment_limits(Routes, hg_invoice_payment:get_iter(St), St, []),
    _ = hg_invoice_payment:rollback_payment_cashflow(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Behaviour = hg_invoice_payment:get_route_cascade_behaviour(Route, Revision),
    case hg_invoice_payment:is_route_cascade_available(Behaviour, Route, ?failed(Failure), St) of
        true ->
            hg_invoice_payment_routing:process_routing(NewAction, St);
        false ->
            {done, {[?payment_status_changed(?failed(Failure))], NewAction}}
    end;
process_result({payment, finalizing_accounter}, Action, St) ->
    Target = hg_invoice_payment:get_target(St),
    _PostingPlanLog =
        case Target of
            ?captured() ->
                hg_invoice_payment:commit_payment_limits(St),
                hg_invoice_payment:commit_payment_cashflow(St);
            ?cancelled() ->
                Route = hg_invoice_payment:get_route(St),
                _ = hg_invoice_payment:rollback_payment_limits([Route], hg_invoice_payment:get_iter(St), St, []),
                hg_invoice_payment:rollback_payment_cashflow(St)
        end,
    check_recurrent_token(St),
    NewAction = get_action(Target, Action, St),
    {done, {[?payment_status_changed(Target)], NewAction}}.

-spec process_failure(activity(), [change()], action(), failure(), st()) -> machine_result().
process_failure(Activity, Events, Action, Failure, St) ->
    process_failure(Activity, Events, Action, Failure, St, undefined).

-spec process_failure(activity(), [change()], action(), failure(), st(), undefined) -> machine_result().
process_failure({payment, processing_failure}, Events, Action, _Failure, #st{failure = Failure}, _RefundSt) when
    Failure =/= undefined
->
    %% In case of cascade attempt we may catch and handle routing failure during 'processing_failure' activity
    {done, {Events ++ [?payment_status_changed(?failed(Failure))], Action}};
process_failure({payment, Step}, Events, Action, Failure, _St, _RefundSt) when
    Step =:= risk_scoring orelse
        Step =:= routing
->
    {done, {Events ++ [?payment_status_changed(?failed(Failure))], Action}};
process_failure({payment, Step} = Activity, Events, Action, Failure, St, _RefundSt) when
    Step =:= processing_session orelse
        Step =:= finalizing_session
->
    Target = hg_invoice_payment:get_target(St),
    case hg_invoice_payment_session:check_retry_possibility(Target, Failure, St) of
        {retry, Timeout} ->
            _ = logger:notice("Retry session after transient failure, wait ~p", [Timeout]),
            {SessionEvents, SessionAction} = hg_invoice_payment_session:retry_session(Action, Target, Timeout),
            {next, {Events ++ SessionEvents, SessionAction}};
        fatal ->
            TargetType = hg_invoice_payment:get_target_type(Target),
            OperationStatus = choose_fd_operation_status_for_failure(Failure),
            _ = hg_invoice_payment:maybe_notify_fault_detector(Activity, TargetType, OperationStatus, St),
            process_fatal_payment_failure(Target, Events, Action, Failure, St)
    end.

-spec process_fatal_payment_failure(target(), [change()], action(), failure(), st()) -> machine_result().
process_fatal_payment_failure(?cancelled(), _Events, _Action, Failure, _St) ->
    error({invalid_cancel_failure, Failure});
process_fatal_payment_failure(?captured(), _Events, _Action, Failure, _St) ->
    error({invalid_capture_failure, Failure});
process_fatal_payment_failure(?processed(), Events, Action, Failure, _St) ->
    RollbackStarted = [?payment_rollback_started(Failure)],
    {next, {Events ++ RollbackStarted, hg_machine_action:set_timeout(0, Action)}}.

-spec repair_process_timeout(activity(), action(), st()) -> machine_result().
repair_process_timeout(Activity, Action, #st{repair_scenario = Scenario} = St) ->
    case hg_invoice_repair:check_for_action(fail_pre_processing, Scenario) of
        {result, Result} when
            Activity =:= {payment, routing} orelse
                Activity =:= {payment, cash_flow_building}
        ->
            hg_invoice_payment:rollback_broken_payment_limits(St),
            Result;
        {result, Result} ->
            Result;
        call ->
            process_timeout(Activity, Action, St)
    end.

-spec get_action(target(), action(), st()) -> action().
get_action(?processed(), Action, St) ->
    Payment = hg_invoice_payment:get_payment(St),
    case hg_invoice_payment:get_payment_flow(Payment) of
        ?invoice_payment_flow_instant() ->
            hg_machine_action:set_timeout(0, Action);
        ?invoice_payment_flow_hold(_, HeldUntil) ->
            hg_machine_action:set_deadline(HeldUntil, Action)
    end;
get_action(_Target, Action, _St) ->
    Action.

-spec process_refund(refund_id(), st()) -> machine_result().
process_refund(ID, #st{opts = Options0, payment = Payment, repair_scenario = Scenario} = St) ->
    RepairScenario =
        case hg_invoice_repair:check_for_action(repair_session, Scenario) of
            call -> undefined;
            RepairAction -> RepairAction
        end,
    PaymentInfo = hg_invoice_payment:construct_payment_info(St, hg_invoice_payment:get_opts(St)),
    Options1 = Options0#{
        payment => Payment,
        payment_info => PaymentInfo,
        repair_scenario => RepairScenario
    },
    Refund = hg_invoice_payment:try_get_refund_state(ID, St),
    {Step, {Events0, Action}} = hg_invoice_payment_refund:process(Options1, Refund),
    Events1 = hg_invoice_payment_refund:wrap_events(Events0, Refund),
    Events2 =
        case hg_invoice_payment_refund:is_status_changed(?refund_succeeded(), Events1) of
            true ->
                process_refund_result(Events1, Refund, St);
            false ->
                Events1
        end,
    {Step, {Events2, Action}}.

-spec process_refund_result([change()], hg_invoice_payment_refund:t(), st()) -> [change()].
process_refund_result(Changes, Refund0, St) ->
    Events = [Event || ?refund_ev(_, Event) <- Changes],
    Refund1 = hg_invoice_payment_refund:update_state_with(Events, Refund0),
    PaymentEvents =
        case
            hg_cash:sub(
                hg_invoice_payment:get_remaining_payment_balance(St),
                hg_invoice_payment_refund:cash(Refund1)
            )
        of
            ?cash(0, _) ->
                [
                    ?payment_status_changed(?refunded())
                ];
            ?cash(Amount, _) when Amount > 0 ->
                []
        end,
    Changes ++ PaymentEvents.

-spec check_recurrent_token(st()) -> ok.
check_recurrent_token(#st{
    payment = #domain_InvoicePayment{make_recurrent = true, skip_recurrent = true},
    recurrent_token = undefined
}) ->
    ok;
check_recurrent_token(#st{
    payment = #domain_InvoicePayment{id = ID, make_recurrent = true, skip_recurrent = true},
    recurrent_token = _Token
}) ->
    _ = logger:warning("Got recurrent token in non recurrent payment. Payment id:~p", [ID]);
check_recurrent_token(#st{
    payment = #domain_InvoicePayment{id = ID, make_recurrent = true},
    recurrent_token = undefined
}) ->
    _ = logger:warning("Fail to get recurrent token in recurrent payment. Payment id:~p", [ID]);
check_recurrent_token(#st{
    payment = #domain_InvoicePayment{id = ID, make_recurrent = MakeRecurrent},
    recurrent_token = Token
}) when
    (MakeRecurrent =:= false orelse MakeRecurrent =:= undefined) andalso
        Token =/= undefined
->
    _ = logger:warning("Got recurrent token in non recurrent payment. Payment id:~p", [ID]);
check_recurrent_token(_) ->
    ok.

-spec choose_fd_operation_status_for_failure(failure()) -> atom().
choose_fd_operation_status_for_failure({failure, Failure}) ->
    payproc_errors:match('PaymentFailure', Failure, fun do_choose_fd_operation_status_for_failure/1);
choose_fd_operation_status_for_failure(_Failure) ->
    finish.

%% Internal helper - not exported
get_merchant_payments_terms(Opts, Revision, _Timestamp, VS) ->
    Shop = hg_invoice_payment:get_shop(Opts, Revision),
    TermSet = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS),
    TermSet#domain_TermSet.payments.

-spec do_choose_fd_operation_status_for_failure(tuple()) -> atom().
do_choose_fd_operation_status_for_failure({authorization_failed, {FailType, _}}) ->
    DefaultBenignFailures = [
        insufficient_funds,
        rejected_by_issuer,
        processing_deadline_reached
    ],
    FDConfig = genlib_app:env(hellgate, fault_detector, #{}),
    Config = genlib_map:get(conversion, FDConfig, #{}),
    BenignFailures = genlib_map:get(benign_failures, Config, DefaultBenignFailures),
    case lists:member(FailType, BenignFailures) of
        false -> error;
        true -> finish
    end;
do_choose_fd_operation_status_for_failure(_Failure) ->
    finish.
