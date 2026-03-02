%%% Payment adjustment module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Contains all adjustment-related functions.

-module(hg_invoice_payment_adjustment).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").

-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").

%% Types
-type st() :: hg_invoice_payment:st().
-type adjustment() :: hg_invoice_payment:adjustment().
-type adjustment_params() :: dmsl_payproc_thrift:'InvoicePaymentAdjustmentParams'().
-type adjustment_status_change() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentStatusChange'().
-type adjustment_state() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentState'().
-type adjustment_id() :: dmsl_domain_thrift:'InvoicePaymentAdjustmentID'().
-type payment_status() :: hg_invoice_payment:payment_status().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().
-type opts() :: hg_invoice_payment:opts().
-type result() :: hg_invoice_payment:result().
-type events() :: hg_invoice_payment:events().
-type action() :: hg_machine_action:action().
-type machine_result() :: hg_invoice_payment:machine_result().
-type payment() :: hg_invoice_payment:payment().

%% Adjustment functions
-export([create_adjustment/4]).
-export([create_cash_flow_adjustment/5]).
-export([create_status_adjustment/5]).
-export([process_adjustment_cashflow/3]).
-export([prepare_adjustment_cashflow/3]).
-export([finalize_adjustment_cashflow/3]).
-export([assert_adjustment_payment_status/1]).
-export([assert_adjustment_payment_statuses/2]).
-export([is_adjustment_payment_status_final/1]).
-export([merge_adjustment_change/2]).
-export([apply_adjustment_effects/2]).
-export([apply_adjustment_effect/3]).
-export([get_adjustment_cashflow/1]).
-export([maybe_inject_new_cost_amount/2]).
-export([maybe_get_domain_revision/1]).

%%% Adjustment creation

-spec create_adjustment(hg_datetime:timestamp(), adjustment_params(), st(), opts()) -> {adjustment(), result()}.
create_adjustment(Timestamp, Params, St, Opts) ->
    _ = hg_invoice_payment_validation:assert_no_adjustment_pending(St),
    case Params#payproc_InvoicePaymentAdjustmentParams.scenario of
        {cash_flow, #domain_InvoicePaymentAdjustmentCashFlow{domain_revision = DomainRevision}} ->
            create_cash_flow_adjustment(Timestamp, Params, DomainRevision, St, Opts);
        {status_change, Change} ->
            create_status_adjustment(Timestamp, Params, Change, St, Opts)
    end.

-spec create_cash_flow_adjustment(
    hg_datetime:timestamp(),
    adjustment_params(),
    undefined | hg_domain:revision(),
    st(),
    opts()
) -> {adjustment(), result()}.
create_cash_flow_adjustment(Timestamp, Params, DomainRevision, St, Opts) ->
    Payment = hg_invoice_payment:get_payment(St),
    Route = hg_invoice_payment:get_route(St),
    _ = hg_invoice_payment_validation:assert_payment_status([captured, refunded, charged_back, failed], Payment),
    NewRevision = maybe_get_domain_revision(DomainRevision),
    OldCashFlow = hg_invoice_payment:get_final_cashflow(St),
    VS = hg_invoice_payment_cashflow:collect_validation_varset(St, Opts),
    Allocation = hg_invoice_payment:get_allocation(St),
    {Payment1, AdditionalEvents} = maybe_inject_new_cost_amount(
        Payment, Params#payproc_InvoicePaymentAdjustmentParams.scenario
    ),
    Context = #{
        provision_terms => hg_invoice_payment:get_provider_terminal_terms(Route, VS, NewRevision),
        route => Route,
        payment => Payment1,
        timestamp => Timestamp,
        varset => VS,
        revision => NewRevision,
        allocation => Allocation
    },
    NewCashFlow =
        case Payment of
            #domain_InvoicePayment{status = {failed, _}} ->
                [];
            _ ->
                hg_invoice_payment_cashflow:calculate_cashflow(Context, Opts)
        end,
    AdjState =
        {cash_flow, #domain_InvoicePaymentAdjustmentCashFlowState{
            scenario = #domain_InvoicePaymentAdjustmentCashFlow{domain_revision = DomainRevision}
        }},
    construct_adjustment(
        Timestamp,
        Params,
        NewRevision,
        OldCashFlow,
        NewCashFlow,
        AdjState,
        AdditionalEvents,
        St
    ).

-spec maybe_inject_new_cost_amount(payment(), adjustment_scenario()) -> {payment(), events()}.
maybe_inject_new_cost_amount(
    Payment,
    {'cash_flow', #domain_InvoicePaymentAdjustmentCashFlow{new_amount = NewAmount}}
) when NewAmount =/= undefined ->
    OldCost = get_payment_cost(Payment),
    NewCost = OldCost#domain_Cash{amount = NewAmount},
    Payment1 = Payment#domain_InvoicePayment{cost = NewCost},
    {Payment1, [?cash_changed(OldCost, NewCost)]};
maybe_inject_new_cost_amount(Payment, _AdjustmentScenario) ->
    {Payment, []}.

-type adjustment_scenario() ::
    {'cash_flow', dmsl_domain_thrift:'InvoicePaymentAdjustmentCashFlow'()}
    | {'status_change', dmsl_domain_thrift:'InvoicePaymentAdjustmentStatusChange'()}.

-spec create_status_adjustment(
    hg_datetime:timestamp(),
    adjustment_params(),
    adjustment_status_change(),
    st(),
    opts()
) -> {adjustment(), result()}.
create_status_adjustment(Timestamp, Params, Change, St, Opts) ->
    #domain_InvoicePaymentAdjustmentStatusChange{
        target_status = TargetStatus
    } = Change,
    #domain_InvoicePayment{
        status = Status,
        domain_revision = DomainRevision
    } = hg_invoice_payment:get_payment(St),
    ok = assert_adjustment_payment_status(Status),
    ok = hg_invoice_payment_validation:assert_no_refunds(St),
    ok = assert_adjustment_payment_statuses(TargetStatus, Status),
    OldCashFlow = hg_invoice_payment_cashflow:get_cash_flow_for_status(Status, St),
    NewCashFlow = hg_invoice_payment_cashflow:get_cash_flow_for_target_status(TargetStatus, St, Opts),
    AdjState =
        {status_change, #domain_InvoicePaymentAdjustmentStatusChangeState{
            scenario = Change
        }},
    construct_adjustment(
        Timestamp,
        Params,
        DomainRevision,
        OldCashFlow,
        NewCashFlow,
        AdjState,
        [],
        St
    ).

-spec maybe_get_domain_revision(undefined | hg_domain:revision()) -> hg_domain:revision().
maybe_get_domain_revision(undefined) ->
    hg_domain:head();
maybe_get_domain_revision(DomainRevision) ->
    DomainRevision.

-spec assert_adjustment_payment_status(payment_status()) -> ok | no_return().
assert_adjustment_payment_status(Status) ->
    hg_invoice_payment_validation:assert_adjustment_payment_status(Status).

-spec assert_adjustment_payment_statuses(payment_status(), payment_status()) -> ok | no_return().
assert_adjustment_payment_statuses(TargetStatus, Status) ->
    hg_invoice_payment_validation:assert_adjustment_payment_statuses(TargetStatus, Status).

-spec is_adjustment_payment_status_final(payment_status()) -> boolean().
is_adjustment_payment_status_final(Status) ->
    hg_invoice_payment_validation:is_adjustment_payment_status_final(Status).

%%% Adjustment processing

-spec process_adjustment_cashflow(adjustment_id(), action(), st()) -> machine_result().
process_adjustment_cashflow(ID, _Action, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    Adjustment = hg_invoice_payment:get_adjustment(ID, St),
    ok = prepare_adjustment_cashflow(Adjustment, St, Opts),
    Events = [?adjustment_ev(ID, ?adjustment_status_changed(?adjustment_processed()))],
    {next, {Events, hg_machine_action:instant()}}.

-spec prepare_adjustment_cashflow(adjustment(), st(), opts()) -> ok | no_return().
prepare_adjustment_cashflow(Adjustment, St, Options) ->
    PlanID = construct_adjustment_plan_id(Adjustment, St, Options),
    Plan = get_adjustment_cashflow_plan(Adjustment),
    plan(PlanID, Plan).

-spec finalize_adjustment_cashflow(adjustment(), st(), opts()) -> ok | no_return().
finalize_adjustment_cashflow(Adjustment, St, Options) ->
    PlanID = construct_adjustment_plan_id(Adjustment, St, Options),
    Plan = get_adjustment_cashflow_plan(Adjustment),
    commit(PlanID, Plan).

-spec get_adjustment_cashflow(adjustment()) -> final_cash_flow().
get_adjustment_cashflow(#domain_InvoicePaymentAdjustment{new_cash_flow = Cashflow}) ->
    Cashflow.

%%% Adjustment state management

-spec merge_adjustment_change(adjustment_change(), undefined | adjustment()) -> adjustment().
merge_adjustment_change(?adjustment_created(Adjustment), undefined) ->
    Adjustment;
merge_adjustment_change(?adjustment_status_changed(Status), Adjustment) ->
    Adjustment#domain_InvoicePaymentAdjustment{status = Status}.

-type adjustment_change() ::
    {invoice_payment_adjustment_created, dmsl_payproc_thrift:'InvoicePaymentAdjustmentCreated'()}
    | {invoice_payment_adjustment_status_changed, dmsl_payproc_thrift:'InvoicePaymentAdjustmentStatusChanged'()}.

-define(adjustment_target_status(Status), #domain_InvoicePaymentAdjustment{
    state =
        {status_change, #domain_InvoicePaymentAdjustmentStatusChangeState{
            scenario = #domain_InvoicePaymentAdjustmentStatusChange{target_status = Status}
        }}
}).

-spec apply_adjustment_effects(adjustment(), st()) -> st().
apply_adjustment_effects(Adjustment, St) ->
    apply_adjustment_effect(
        status,
        Adjustment,
        apply_adjustment_effect(cashflow, Adjustment, St)
    ).

-spec apply_adjustment_effect(status | cashflow, adjustment(), st()) -> st().
apply_adjustment_effect(status, ?adjustment_target_status(Status), St = #st{payment = Payment}) ->
    case Status of
        {captured, Capture} ->
            St#st{
                payment = Payment#domain_InvoicePayment{
                    status = Status,
                    cost = get_captured_cost(Capture, Payment)
                }
            };
        _ ->
            St#st{
                payment = Payment#domain_InvoicePayment{
                    status = Status
                }
            }
    end;
apply_adjustment_effect(status, #domain_InvoicePaymentAdjustment{}, St) ->
    St;
apply_adjustment_effect(cashflow, Adjustment, St) ->
    set_cashflow(get_adjustment_cashflow(Adjustment), St).

%%% Internal helper functions

-spec construct_adjustment(
    hg_datetime:timestamp(),
    adjustment_params(),
    hg_domain:revision(),
    final_cash_flow(),
    final_cash_flow(),
    adjustment_state(),
    events(),
    st()
) -> {adjustment(), result()}.
construct_adjustment(
    Timestamp,
    Params,
    DomainRevision,
    OldCashFlow,
    NewCashFlow,
    State,
    AdditionalEvents,
    St
) ->
    ID = construct_adjustment_id(St),
    Adjustment = #domain_InvoicePaymentAdjustment{
        id = ID,
        status = ?adjustment_pending(),
        created_at = Timestamp,
        domain_revision = DomainRevision,
        reason = Params#payproc_InvoicePaymentAdjustmentParams.reason,
        old_cash_flow_inverse = hg_cashflow:revert(OldCashFlow),
        new_cash_flow = NewCashFlow,
        state = State
    },
    Events = [?adjustment_ev(ID, ?adjustment_created(Adjustment)) | AdditionalEvents],
    {Adjustment, {Events, hg_machine_action:instant()}}.

-spec construct_adjustment_id(st()) -> adjustment_id().
construct_adjustment_id(#st{adjustments = As}) ->
    erlang:integer_to_binary(length(As) + 1).

-spec construct_adjustment_plan_id(adjustment(), st(), opts()) -> binary().
construct_adjustment_plan_id(Adjustment, St, Options) ->
    hg_utils:construct_complex_id([
        hg_invoice_payment:get_invoice_id(hg_invoice_payment:get_invoice(Options)),
        hg_invoice_payment:get_payment_id(hg_invoice_payment:get_payment(St)),
        {adj, get_adjustment_id(Adjustment)}
    ]).

-spec get_adjustment_id(adjustment()) -> adjustment_id().
get_adjustment_id(#domain_InvoicePaymentAdjustment{id = ID}) ->
    ID.

%%% Helper functions (re-exported from hg_invoice_payment for convenience)

-spec get_payment_cost(payment()) -> dmsl_domain_thrift:'Cash'().
get_payment_cost(#domain_InvoicePayment{changed_cost = Cost}) when Cost =/= undefined ->
    Cost;
get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

-spec set_cashflow(final_cash_flow(), st()) -> st().
set_cashflow(Cashflow, #st{} = St) ->
    St#st{
        cash_flow = Cashflow,
        final_cash_flow = Cashflow
    }.

-spec get_captured_cost(dmsl_domain_thrift:'InvoicePaymentCaptured'(), payment()) ->
    dmsl_domain_thrift:'Cash'().
get_captured_cost(#domain_InvoicePaymentCaptured{cost = Cost}, _) when Cost /= undefined ->
    Cost;
get_captured_cost(_, #domain_InvoicePayment{cost = Cost}) ->
    Cost.

-spec get_adjustment_cashflow_plan(adjustment()) -> [{non_neg_integer(), final_cash_flow()}].
get_adjustment_cashflow_plan(#domain_InvoicePaymentAdjustment{
    old_cash_flow_inverse = CashflowInverse,
    new_cash_flow = Cashflow
}) ->
    number_plan([CashflowInverse, Cashflow], 1, []).

-spec number_plan([final_cash_flow()], non_neg_integer(), [{non_neg_integer(), final_cash_flow()}]) ->
    [{non_neg_integer(), final_cash_flow()}].
number_plan([], _Number, Acc) ->
    lists:reverse(Acc);
number_plan([[] | Tail], Number, Acc) ->
    number_plan(Tail, Number, Acc);
number_plan([NonEmpty | Tail], Number, Acc) ->
    number_plan(Tail, Number + 1, [{Number, NonEmpty} | Acc]).

-spec plan(binary(), [{non_neg_integer(), final_cash_flow()}]) -> ok | no_return().
plan(_PlanID, []) ->
    ok;
plan(PlanID, Plan) ->
    _ = hg_accounting:plan(PlanID, Plan),
    ok.

-spec commit(binary(), [{non_neg_integer(), final_cash_flow()}]) -> ok | no_return().
commit(_PlanID, []) ->
    ok;
commit(PlanID, Plan) ->
    _ = hg_accounting:commit(PlanID, Plan),
    ok.
