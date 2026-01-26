%%% Payment state management module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Contains all state management functions: merge_change, collapse_changes,
%%% record_status_change, and state setters/getters.

-module(hg_invoice_payment_state).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").

-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").

%% Types
-type st() :: hg_invoice_payment:st().
-type change() :: hg_invoice_payment:change().
-type change_opts() :: hg_invoice_payment:change_opts().
-type chargeback_id() :: hg_invoice_payment_chargeback:id().
-type chargeback_state() :: hg_invoice_payment_chargeback:state().
-type refund_id() :: hg_invoice_payment:refund_id().
-type refund_state() :: hg_invoice_payment:refund_state().
-type adjustment_id() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentID'().
-type adjustment() :: hg_invoice_payment:adjustment().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().
-type trx_info() :: hg_invoice_payment:trx_info().
-type target() :: hg_invoice_payment:target().

%% State management functions
-export([merge_change/3]).
-export([collapse_changes/3]).
-export([record_status_change/2]).
-export([set_chargeback_state/3]).
-export([set_refund_state/3]).
-export([set_adjustment/3]).
-export([set_cashflow/2]).
-export([set_trx/2]).
-export([try_get_refund_state/2]).
-export([try_get_chargeback_state/2]).
-export([try_get_adjustment/2]).
-export([latest_adjustment_id/1]).
-export([save_retry_attempt/2]).

%%% State merging

-spec merge_change(change(), st() | undefined, change_opts()) -> st().
merge_change(Change, undefined, Opts) ->
    merge_change(Change, #st{activity = {payment, new}}, Opts);
merge_change(Change = ?payment_started(Payment), #st{} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition({payment, new}, Change, St, Opts),
    St#st{
        target = ?processed(),
        payment = Payment,
        activity = {payment, shop_limit_initializing},
        timings = hg_timings:mark(started, hg_invoice_payment:define_event_timestamp(Opts))
    };
merge_change(Change = ?shop_limit_initiated(), #st{} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition({payment, shop_limit_initializing}, Change, St, Opts),
    St#st{
        shop_limit_status = initialized,
        activity = {payment, shop_limit_finalizing}
    };
merge_change(Change = ?shop_limit_applied(), #st{} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition({payment, shop_limit_finalizing}, Change, St, Opts),
    St#st{
        shop_limit_status = finalized,
        activity = {payment, risk_scoring}
    };
merge_change(Change = ?risk_score_changed(RiskScore), #st{} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [
            {payment, S}
         || S <- [
                risk_scoring,
                %% Added for backward compatibility
                shop_limit_initializing
            ]
        ],
        Change,
        St,
        Opts
    ),
    St#st{
        risk_score = RiskScore,
        activity = {payment, routing}
    };
merge_change(
    Change = ?route_changed(Route, Candidates, Scores, Limits, Decision),
    #st{routes = Routes, route_scores = RouteScores, route_limits = RouteLimits} = St,
    Opts
) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [{payment, S} || S <- [routing, processing_failure]], Change, St, Opts
    ),
    Skip =
        case Decision of
            #payproc_RouteDecisionContext{skip_recurrent = true} ->
                true;
            _ ->
                false
        end,
    Payment0 = hg_invoice_payment:get_payment(St),
    Payment1 = Payment0#domain_InvoicePayment{skip_recurrent = Skip},
    St#st{
        %% On route change we expect cash flow from previous attempt to be rolled back.
        %% So on `?payment_rollback_started(_)` event for routing failure we won't try to do it again.
        cash_flow = undefined,
        %% `trx` from previous session (if any) also must be considered obsolete.
        trx = undefined,
        routes = [Route | Routes],
        candidate_routes = ordsets:to_list(Candidates),
        activity = {payment, cash_flow_building},
        route_scores = hg_maybe:apply(fun(S) -> maps:merge(RouteScores, S) end, Scores, RouteScores),
        route_limits = hg_maybe:apply(fun(L) -> maps:merge(RouteLimits, L) end, Limits, RouteLimits),
        payment = Payment1
    };
merge_change(Change = ?payment_capture_started(Data), #st{} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition([{payment, S} || S <- [flow_waiting]], Change, St, Opts),
    St#st{
        capture_data = Data,
        activity = {payment, processing_capture},
        allocation = Data#payproc_InvoicePaymentCaptureData.allocation
    };
merge_change(Change = ?cash_flow_changed(CashFlow), #st{activity = Activity} = St0, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [
            {payment, S}
         || S <- [
                cash_flow_building,
                processing_capture,
                processing_accounter
            ]
        ],
        Change,
        St0,
        Opts
    ),
    St = St0#st{
        final_cash_flow = CashFlow
    },
    case Activity of
        {payment, processing_accounter} ->
            St#st{new_cash = undefined, new_cash_flow = CashFlow};
        {payment, cash_flow_building} ->
            St#st{
                cash_flow = CashFlow,
                activity = {payment, processing_session}
            };
        {payment, processing_capture} ->
            St#st{
                partial_cash_flow = CashFlow,
                activity = {payment, updating_accounter}
            };
        _ ->
            St
    end;
merge_change(Change = ?rec_token_acquired(Token), #st{} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [{payment, S} || S <- [processing_session, finalizing_session]], Change, St, Opts
    ),
    St#st{recurrent_token = Token};
merge_change(Change = ?cash_changed(_OldCash, NewCash), #st{} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [{adjustment_new, latest_adjustment_id(St)}, {payment, processing_session}],
        Change,
        St,
        Opts
    ),
    Payment0 = hg_invoice_payment:get_payment(St),
    Payment1 = Payment0#domain_InvoicePayment{changed_cost = NewCash},
    St#st{new_cash = NewCash, new_cash_provided = true, payment = Payment1};
merge_change(Change = ?payment_rollback_started(Failure), St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [
            {payment, shop_limit_finalizing},
            {payment, cash_flow_building},
            {payment, processing_session}
        ],
        Change,
        St,
        Opts
    ),
    Activity =
        case St of
            #st{shop_limit_status = initialized} ->
                {payment, shop_limit_failure};
            #st{cash_flow = undefined} ->
                {payment, routing_failure};
            _ ->
                {payment, processing_failure}
        end,
    St#st{
        failure = Failure,
        activity = Activity,
        timings = hg_invoice_payment:accrue_status_timing(failed, Opts, St)
    };
merge_change(Change = ?payment_status_changed({failed, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [
            {payment, S}
         || S <- [
                risk_scoring,
                routing,
                cash_flow_building,
                shop_limit_failure,
                routing_failure,
                processing_failure
            ]
        ],
        Change,
        St,
        Opts
    ),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = idle,
        failure = undefined,
        timings = hg_invoice_payment:accrue_status_timing(failed, Opts, St)
    };
merge_change(Change = ?payment_status_changed({cancelled, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition({payment, finalizing_accounter}, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = idle,
        timings = hg_invoice_payment:accrue_status_timing(cancelled, Opts, St)
    };
merge_change(Change = ?payment_status_changed({captured, Captured} = Status), #st{payment = Payment} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition([idle, {payment, finalizing_accounter}], Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{
            status = Status,
            cost = hg_invoice_payment:get_captured_cost(Captured, Payment)
        },
        activity = idle,
        timings = hg_invoice_payment:accrue_status_timing(captured, Opts, St),
        allocation = hg_invoice_payment:get_captured_allocation(Captured)
    };
merge_change(Change = ?payment_status_changed({processed, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition({payment, processing_accounter}, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status},
        activity = {payment, flow_waiting},
        timings = hg_invoice_payment:accrue_status_timing(processed, Opts, St)
    };
merge_change(Change = ?payment_status_changed({refunded, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(idle, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status}
    };
merge_change(Change = ?payment_status_changed({charged_back, _} = Status), #st{payment = Payment} = St, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(idle, Change, St, Opts),
    (record_status_change(Change, St))#st{
        payment = Payment#domain_InvoicePayment{status = Status}
    };
merge_change(Change = ?chargeback_ev(ID, Event), St, Opts) ->
    St1 =
        case Event of
            ?chargeback_created(_) ->
                _ = hg_invoice_payment_validation:validate_transition(idle, Change, St, Opts),
                St#st{activity = {chargeback, ID, preparing_initial_cash_flow}};
            ?chargeback_stage_changed(_) ->
                _ = hg_invoice_payment_validation:validate_transition(idle, Change, St, Opts),
                St;
            ?chargeback_levy_changed(_) ->
                _ = hg_invoice_payment_validation:validate_transition(
                    [idle, {chargeback, ID, updating_chargeback}], Change, St, Opts
                ),
                St#st{activity = {chargeback, ID, updating_chargeback}};
            ?chargeback_body_changed(_) ->
                _ = hg_invoice_payment_validation:validate_transition(
                    [idle, {chargeback, ID, updating_chargeback}], Change, St, Opts
                ),
                St#st{activity = {chargeback, ID, updating_chargeback}};
            ?chargeback_cash_flow_changed(_) ->
                Valid = [{chargeback, ID, Activity} || Activity <- [preparing_initial_cash_flow, updating_cash_flow]],
                _ = hg_invoice_payment_validation:validate_transition(Valid, Change, St, Opts),
                case St of
                    #st{activity = {chargeback, ID, preparing_initial_cash_flow}} ->
                        St#st{activity = idle};
                    #st{activity = {chargeback, ID, updating_cash_flow}} ->
                        St#st{activity = {chargeback, ID, finalising_accounter}}
                end;
            ?chargeback_target_status_changed(?chargeback_status_accepted()) ->
                _ = hg_invoice_payment_validation:validate_transition(
                    [idle, {chargeback, ID, updating_chargeback}], Change, St, Opts
                ),
                case St of
                    #st{activity = idle} ->
                        St#st{activity = {chargeback, ID, finalising_accounter}};
                    #st{activity = {chargeback, ID, updating_chargeback}} ->
                        St#st{activity = {chargeback, ID, updating_cash_flow}}
                end;
            ?chargeback_target_status_changed(_) ->
                _ = hg_invoice_payment_validation:validate_transition(
                    [idle, {chargeback, ID, updating_chargeback}], Change, St, Opts
                ),
                St#st{activity = {chargeback, ID, updating_cash_flow}};
            ?chargeback_status_changed(_) ->
                _ = hg_invoice_payment_validation:validate_transition(
                    [idle, {chargeback, ID, finalising_accounter}], Change, St, Opts
                ),
                St#st{activity = idle}
        end,
    ChargebackSt = hg_invoice_payment_chargeback:merge_change(Event, try_get_chargeback_state(ID, St1)),
    set_chargeback_state(ID, ChargebackSt, St1);
merge_change(?refund_ev(ID, Event), St, Opts) ->
    EventContext = hg_invoice_payment:create_refund_event_context(St, Opts),
    St1 =
        case Event of
            ?refund_status_changed(?refund_succeeded()) ->
                RefundSt0 = hg_invoice_payment_refund:apply_event(
                    Event, try_get_refund_state(ID, St), EventContext
                ),
                DomainRefund = hg_invoice_payment_refund:refund(RefundSt0),
                Allocation = hg_invoice_payment:get_allocation(St),
                FinalAllocation = hg_maybe:apply(
                    fun(A) ->
                        #domain_InvoicePaymentRefund{allocation = RefundAllocation} = DomainRefund,
                        {ok, FA} = hg_allocation:sub(A, RefundAllocation),
                        FA
                    end,
                    Allocation
                ),
                St#st{allocation = FinalAllocation};
            _ ->
                St
        end,
    RefundSt1 = hg_invoice_payment_refund:apply_event(Event, try_get_refund_state(ID, St1), EventContext),
    St2 = set_refund_state(ID, RefundSt1, St1),
    case hg_invoice_payment_refund:status(RefundSt1) of
        S when S == succeeded; S == failed ->
            St2#st{activity = idle};
        _ ->
            St2#st{activity = {refund, ID}}
    end;
merge_change(Change = ?adjustment_ev(ID, Event), St, Opts) ->
    St1 =
        case Event of
            ?adjustment_created(_) ->
                _ = hg_invoice_payment_validation:validate_transition(idle, Change, St, Opts),
                St#st{activity = {adjustment_new, ID}};
            ?adjustment_status_changed(?adjustment_processed()) ->
                _ = hg_invoice_payment_validation:validate_transition({adjustment_new, ID}, Change, St, Opts),
                St#st{activity = {adjustment_pending, ID}};
            ?adjustment_status_changed(_) ->
                _ = hg_invoice_payment_validation:validate_transition({adjustment_pending, ID}, Change, St, Opts),
                St#st{activity = idle}
        end,
    Adjustment = hg_invoice_payment_adjustment:merge_adjustment_change(Event, try_get_adjustment(ID, St1)),
    St2 = set_adjustment(ID, Adjustment, St1),
    % TODO new cashflow imposed implicitly on the payment state? rough
    case hg_invoice_payment:get_adjustment_status(Adjustment) of
        ?adjustment_captured(_) ->
            hg_invoice_payment_adjustment:apply_adjustment_effects(Adjustment, St2);
        _ ->
            St2
    end;
merge_change(
    Change = ?session_ev(Target, Event = ?session_started()),
    #st{activity = Activity} = St,
    Opts
) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [
            {payment, S}
         || S <- [
                processing_session,
                flow_waiting,
                processing_capture,
                updating_accounter,
                finalizing_session
            ]
        ],
        Change,
        St,
        Opts
    ),
    % FIXME why the hell dedicated handling
    Session0 = hg_session:apply_event(
        Event, undefined, hg_invoice_payment:create_session_event_context(Target, St, Opts)
    ),
    %% We need to pass processed trx_info to captured/cancelled session due to provider requirements
    Session1 = hg_session:set_trx_info(hg_invoice_payment:get_trx(St), Session0),
    St1 = hg_invoice_payment:add_session(Target, Session1, St#st{target = Target}),
    St2 = save_retry_attempt(Target, St1),
    case Activity of
        {payment, processing_session} ->
            %% session retrying
            St2#st{activity = {payment, processing_session}};
        {payment, PaymentActivity} when PaymentActivity == flow_waiting; PaymentActivity == processing_capture ->
            %% session flow
            St2#st{
                activity = {payment, finalizing_session},
                timings = hg_invoice_payment:try_accrue_waiting_timing(Opts, St2)
            };
        {payment, updating_accounter} ->
            %% session flow
            St2#st{activity = {payment, finalizing_session}};
        {payment, finalizing_session} ->
            %% session retrying
            St2#st{activity = {payment, finalizing_session}};
        _ ->
            St2
    end;
merge_change(Change = ?session_ev(Target, Event), St = #st{activity = Activity}, Opts) ->
    _ = hg_invoice_payment_validation:validate_transition(
        [{payment, S} || S <- [processing_session, finalizing_session]], Change, St, Opts
    ),
    Session = hg_session:apply_event(
        Event,
        hg_invoice_payment:get_session(Target, St),
        hg_invoice_payment:create_session_event_context(Target, St, Opts)
    ),
    St1 = hg_invoice_payment:update_session(Target, Session, St),
    % FIXME leaky transactions
    St2 = set_trx(hg_session:trx_info(Session), St1),
    case Session of
        #{status := finished, result := ?session_succeeded()} ->
            NextActivity =
                case Activity of
                    {payment, processing_session} ->
                        {payment, processing_accounter};
                    {payment, finalizing_session} ->
                        {payment, finalizing_accounter};
                    _ ->
                        Activity
                end,
            St2#st{activity = NextActivity};
        _ ->
            St2
    end.

-spec collapse_changes([change()], st() | undefined, change_opts()) -> st() | undefined.
collapse_changes(Changes, St, Opts) ->
    lists:foldl(fun(C, St1) -> merge_change(C, St1, Opts) end, St, Changes).

-spec record_status_change(change(), st()) -> st().
record_status_change(?payment_status_changed(Status), St) ->
    St#st{status_log = [Status | St#st.status_log]}.

%%% State setters

-spec set_chargeback_state(chargeback_id(), chargeback_state(), st()) -> st().
set_chargeback_state(ID, ChargebackSt, #st{chargebacks = CBs} = St) ->
    St#st{chargebacks = CBs#{ID => ChargebackSt}}.

-spec set_refund_state(refund_id(), refund_state(), st()) -> st().
set_refund_state(ID, RefundSt, #st{refunds = Rs} = St) ->
    St#st{refunds = Rs#{ID => RefundSt}}.

-spec set_adjustment(adjustment_id(), adjustment(), st()) -> st().
set_adjustment(ID, Adjustment, #st{adjustments = As} = St) ->
    St#st{adjustments = lists:keystore(ID, #domain_InvoicePaymentAdjustment.id, As, Adjustment)}.

-spec set_cashflow(final_cash_flow(), st()) -> st().
set_cashflow(Cashflow, #st{} = St) ->
    St#st{
        cash_flow = Cashflow,
        final_cash_flow = Cashflow
    }.

-spec set_trx(trx_info() | undefined, st()) -> st().
set_trx(undefined, #st{} = St) ->
    St;
set_trx(Trx, #st{} = St) ->
    St#st{trx = Trx}.

%%% State getters (try_* versions)

-spec try_get_refund_state(refund_id(), st()) -> refund_state() | undefined.
try_get_refund_state(ID, #st{refunds = Rs}) ->
    case Rs of
        #{ID := RefundSt} ->
            RefundSt;
        #{} ->
            undefined
    end.

-spec try_get_chargeback_state(chargeback_id(), st()) -> chargeback_state() | undefined.
try_get_chargeback_state(ID, #st{chargebacks = CBs}) ->
    case CBs of
        #{ID := ChargebackSt} ->
            ChargebackSt;
        #{} ->
            undefined
    end.

-spec try_get_adjustment(adjustment_id(), st()) -> adjustment() | undefined.
try_get_adjustment(ID, #st{adjustments = As}) ->
    case lists:keyfind(ID, #domain_InvoicePaymentAdjustment.id, As) of
        V = #domain_InvoicePaymentAdjustment{} ->
            V;
        false ->
            undefined
    end.

%%% Helper functions

-spec latest_adjustment_id(st()) -> adjustment_id() | undefined.
latest_adjustment_id(#st{adjustments = []}) ->
    undefined;
latest_adjustment_id(#st{adjustments = Adjustments}) ->
    Adjustment = lists:last(Adjustments),
    Adjustment#domain_InvoicePaymentAdjustment.id.

-spec save_retry_attempt(target(), st()) -> st().
save_retry_attempt(Target, #st{retry_attempts = Attempts} = St) ->
    St#st{
        retry_attempts = maps:update_with(hg_invoice_payment:get_target_type(Target), fun(N) -> N + 1 end, 0, Attempts)
    }.
