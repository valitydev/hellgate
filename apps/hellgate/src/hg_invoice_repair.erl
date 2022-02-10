-module(hg_invoice_repair).

-include("domain.hrl").
-include("payment_events.hrl").

-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").

-export([check_for_action/2]).
-export([get_repair_state/3]).

%% dmsl types

-type risk_score() :: dmsl_domain_thrift:'RiskScore'().
-type proxy_result() :: dmsl_proxy_provider_thrift:'PaymentProxyResult'().
-type scenario() :: dmsl_payment_processing_thrift:'InvoiceRepairScenario'().

%% user types

-type action_type() ::
    fail_pre_processing
    | skip_inspector
    | repair_session.

-type scenario_result() ::
    hg_invoice_payment:machine_result()
    | proxy_result()
    | risk_score().

%% exported types

-export_type([scenario/0]).
-export_type([action_type/0]).

%% Repair

-spec check_for_action(action_type(), scenario()) -> call | {result, scenario_result()}.
check_for_action(ActionType, {complex, #payproc_InvoiceRepairComplex{scenarios = Scenarios}}) ->
    check_complex_list(ActionType, Scenarios);
check_for_action(
    fail_pre_processing,
    {fail_pre_processing, #payproc_InvoiceRepairFailPreProcessing{failure = Failure}}
) ->
    {result, {done, {[?payment_status_changed(?failed({failure, Failure}))], hg_machine_action:instant()}}};
check_for_action(skip_inspector, {skip_inspector, #payproc_InvoiceRepairSkipInspector{risk_score = RiskScore}}) ->
    {result, RiskScore};
check_for_action(repair_session, {fail_session, #payproc_InvoiceRepairFailSession{failure = Failure, trx = Trx}}) ->
    ProxyResult = #prxprv_PaymentProxyResult{
        intent = {finish, #'prxprv_FinishIntent'{status = {failure, Failure}}},
        trx = Trx
    },
    {result, ProxyResult};
check_for_action(repair_session, {fulfill_session, #payproc_InvoiceRepairFulfillSession{trx = Trx}}) ->
    ProxyResult = #prxprv_PaymentProxyResult{
        intent = {finish, #'prxprv_FinishIntent'{status = {success, #'prxprv_Success'{}}}},
        trx = Trx
    },
    {result, ProxyResult};
check_for_action(_Type, _Scenario) ->
    call.

check_complex_list(_ActionType, []) ->
    call;
check_complex_list(ActionType, [Scenario | Rest]) ->
    case check_for_action(ActionType, Scenario) of
        {result, _Value} = Result ->
            Result;
        call ->
            check_complex_list(ActionType, Rest)
    end.

%% create repair event

-spec get_repair_state(hg_invoice_payment:activity(), scenario(), hg_invoice_payment:st()) -> hg_invoice_payment:st().
get_repair_state(Activity, Scenario, St) ->
    ok = check_activity_compatibility(Scenario, Activity),
    hg_invoice_payment:set_repair_scenario(Scenario, St).

-define(SCENARIO_COMPLEX(Scenarios), {complex, #payproc_InvoiceRepairComplex{scenarios = Scenarios}}).
-define(SCENARIO_FAIL_PRE_PROCESSING, {fail_pre_processing, #payproc_InvoiceRepairFailPreProcessing{}}).
-define(SCENARIO_SKIP_INSPECTOR, {skip_inspector, #payproc_InvoiceRepairSkipInspector{}}).
-define(SCENARIO_FAIL_SESSION, {fail_session, #payproc_InvoiceRepairFailSession{}}).
-define(SCENARIO_FULFILL_SESSION, {fulfill_session, #payproc_InvoiceRepairFulfillSession{}}).

check_activity_compatibility(?SCENARIO_COMPLEX(Scenarios), Activity) ->
    lists:foreach(fun(Scenario) -> check_activity_compatibility(Scenario, Activity) end, Scenarios);
check_activity_compatibility(?SCENARIO_FAIL_PRE_PROCESSING, {payment, new}) ->
    ok;
check_activity_compatibility(?SCENARIO_FAIL_PRE_PROCESSING, {payment, risk_scoring}) ->
    ok;
check_activity_compatibility(?SCENARIO_FAIL_PRE_PROCESSING, {payment, routing}) ->
    ok;
check_activity_compatibility(?SCENARIO_FAIL_PRE_PROCESSING, {payment, cash_flow_building}) ->
    ok;
check_activity_compatibility(?SCENARIO_SKIP_INSPECTOR, {payment, new}) ->
    ok;
check_activity_compatibility(?SCENARIO_SKIP_INSPECTOR, {payment, risk_scoring}) ->
    ok;
check_activity_compatibility(?SCENARIO_FAIL_SESSION, {payment, processing_session}) ->
    ok;
check_activity_compatibility(?SCENARIO_FAIL_SESSION, {payment, processing_capture}) ->
    ok;
check_activity_compatibility(?SCENARIO_FAIL_SESSION, {refund_session, _}) ->
    ok;
check_activity_compatibility(?SCENARIO_FULFILL_SESSION, {payment, processing_session}) ->
    ok;
check_activity_compatibility(?SCENARIO_FULFILL_SESSION, {payment, processing_capture}) ->
    ok;
check_activity_compatibility(?SCENARIO_FULFILL_SESSION, {refund_session, _}) ->
    ok;
check_activity_compatibility(Scenario, Activity) ->
    throw({exception, {activity_not_compatible_with_scenario, Activity, Scenario}}).
