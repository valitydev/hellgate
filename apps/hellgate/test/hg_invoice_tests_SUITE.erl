%% TODO
%%%  - Do not share state between test cases
%%%  - Run cases in parallel

-module(hg_invoice_tests_SUITE).

-include("hg_ct_domain.hrl").
-include_lib("damsel/include/dmsl_repair_thrift.hrl").
-include_lib("hellgate/include/allocation.hrl").

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([invoice_creation_idempotency/1]).
-export([invalid_invoice_shop/1]).
-export([invalid_invoice_amount/1]).
-export([invalid_invoice_currency/1]).
-export([invalid_party_status/1]).
-export([invalid_shop_status/1]).
-export([invalid_invoice_template_cost/1]).
-export([invalid_invoice_template_id/1]).
-export([invoive_w_template_idempotency/1]).
-export([invoice_w_template/1]).
-export([invoice_cancellation/1]).
-export([overdue_invoice_cancellation/1]).
-export([invoice_cancellation_after_payment_timeout/1]).
-export([invalid_payment_amount/1]).

-export([payment_start_idempotency/1]).
-export([payment_success/1]).
-export([register_payment_success/1]).
-export([register_payment_customer_payer_success/1]).

-export([payment_limit_success/1]).
-export([register_payment_limit_success/1]).
-export([payment_limit_other_shop_success/1]).
-export([payment_limit_overflow/1]).
-export([refund_limit_success/1]).
-export([payment_partial_capture_limit_success/1]).
-export([switch_provider_after_limit_overflow/1]).
-export([limit_not_found/1]).
-export([limit_hold_currency_error/1]).
-export([limit_hold_operation_not_supported/1]).
-export([limit_hold_payment_tool_not_supported/1]).
-export([limit_hold_two_routes_failure/1]).

-export([processing_deadline_reached_test/1]).
-export([payment_success_empty_cvv/1]).
-export([payment_success_additional_info/1]).
-export([payment_w_terminal_w_payment_service_success/1]).
-export([payment_w_crypto_currency_success/1]).
-export([payment_bank_card_category_condition/1]).
-export([payment_w_wallet_success/1]).
-export([payment_w_customer_success/1]).
-export([payment_w_another_shop_customer/1]).
-export([payment_w_another_party_customer/1]).
-export([payment_w_deleted_customer/1]).
-export([payment_w_mobile_commerce/1]).
-export([payment_suspend_timeout_failure/1]).
-export([payments_w_bank_card_issuer_conditions/1]).
-export([payments_w_bank_conditions/1]).
-export([payment_success_on_second_try/1]).
-export([payment_fail_after_silent_callback/1]).
-export([invoice_success_on_third_payment/1]).
-export([party_revision_check/1]).
-export([payment_customer_risk_score_check/1]).
-export([payment_risk_score_check/1]).
-export([payment_risk_score_check_fail/1]).
-export([payment_risk_score_check_timeout/1]).
-export([invalid_payment_adjustment/1]).
-export([payment_adjustment_success/1]).
-export([payment_adjustment_refunded_success/1]).
-export([payment_adjustment_chargeback_success/1]).
-export([payment_adjustment_captured_partial/1]).
-export([payment_adjustment_captured_from_failed/1]).
-export([payment_adjustment_failed_from_captured/1]).
-export([status_adjustment_of_partial_refunded_payment/1]).
-export([registered_payment_adjustment_success/1]).
-export([invalid_payment_w_deprived_party/1]).
-export([external_account_posting/1]).
-export([terminal_cashflow_overrides_provider/1]).
-export([payment_hold_cancellation/1]).
-export([payment_hold_double_cancellation/1]).
-export([payment_hold_cancellation_captured/1]).
-export([payment_hold_auto_cancellation/1]).
-export([payment_hold_capturing/1]).
-export([payment_hold_double_capturing/1]).
-export([payment_hold_capturing_cancelled/1]).
-export([deadline_doesnt_affect_payment_capturing/1]).
-export([payment_hold_partial_capturing/1]).
-export([payment_hold_partial_capturing_with_cart/1]).
-export([payment_hold_partial_capturing_with_cart_missing_cash/1]).
-export([invalid_currency_partial_capture/1]).
-export([invalid_amount_partial_capture/1]).
-export([invalid_permit_partial_capture_in_service/1]).
-export([invalid_permit_partial_capture_in_provider/1]).
-export([payment_hold_auto_capturing/1]).

-export([create_chargeback_not_allowed/1]).
-export([create_chargeback_inconsistent/1]).
-export([create_chargeback_exceeded/1]).
-export([create_chargeback_idempotency/1]).
-export([cancel_payment_chargeback/1]).
-export([cancel_partial_payment_chargeback/1]).
-export([cancel_partial_payment_chargeback_exceeded/1]).
-export([cancel_payment_chargeback_refund/1]).
-export([reject_payment_chargeback_inconsistent/1]).
-export([reject_payment_chargeback/1]).
-export([reject_payment_chargeback_no_fees/1]).
-export([reject_payment_chargeback_new_levy/1]).
-export([accept_payment_chargeback_inconsistent/1]).
-export([accept_payment_chargeback_exceeded/1]).
-export([accept_payment_chargeback_empty_params/1]).
-export([accept_payment_chargeback_twice/1]).
-export([accept_payment_chargeback_new_body/1]).
-export([accept_payment_chargeback_new_levy/1]).
-export([reopen_accepted_payment_chargeback_fails/1]).
-export([reopen_payment_chargeback_inconsistent/1]).
-export([reopen_payment_chargeback_exceeded/1]).
-export([reopen_payment_chargeback_cancel/1]).
-export([reopen_payment_chargeback_reject/1]).
-export([reopen_payment_chargeback_accept/1]).
-export([reopen_payment_chargeback_skip_stage_accept/1]).
-export([reopen_payment_chargeback_accept_new_levy/1]).
-export([reopen_payment_chargeback_arbitration/1]).
-export([reopen_payment_chargeback_arbitration_reopen_fails/1]).

-export([invalid_refund_party_status/1]).
-export([invalid_refund_shop_status/1]).
-export([payment_refund_idempotency/1]).
-export([payment_refund_success/1]).
-export([payment_success_ruleset/1]).
-export([payment_refund_failure/1]).
-export([deadline_doesnt_affect_payment_refund/1]).
-export([payment_manual_refund/1]).
-export([payment_partial_refunds_success/1]).
-export([payment_refund_id_types/1]).
-export([payment_temporary_unavailability_retry_success/1]).
-export([payment_temporary_unavailability_too_many_retries/1]).
-export([invalid_amount_payment_partial_refund/1]).
-export([invalid_amount_partial_capture_and_refund/1]).
-export([ineligible_payment_partial_refund/1]).
-export([invalid_currency_payment_partial_refund/1]).
-export([cant_start_simultaneous_partial_refunds/1]).
-export([retry_temporary_unavailability_refund/1]).
-export([rounding_cashflow_volume/1]).
-export([payment_with_offsite_preauth_success/1]).
-export([payment_with_offsite_preauth_failed/1]).
-export([payment_with_tokenized_bank_card/1]).
-export([terms_retrieval/1]).
-export([payment_has_optional_fields/1]).
-export([payment_last_trx_correct/1]).
-export([payment_w_misconfigured_routing_failed/1]).
-export([payment_capture_failed/1]).
-export([payment_capture_retries_exceeded/1]).
-export([payment_partial_capture_success/1]).
-export([payment_error_in_cancel_session_does_not_cause_payment_failure/1]).
-export([payment_error_in_capture_session_does_not_cause_payment_failure/1]).

-export([registered_payment_manual_refund_success/1]).

-export([adhoc_repair_working_failed/1]).
-export([adhoc_repair_failed_succeeded/1]).
-export([adhoc_repair_force_removal/1]).
-export([adhoc_repair_invalid_changes_failed/1]).
-export([adhoc_repair_force_invalid_transition/1]).

-export([repair_fail_pre_processing_succeeded/1]).
-export([repair_skip_inspector_succeeded/1]).
-export([repair_fail_session_on_processed_succeeded/1]).
-export([repair_fail_suspended_session_succeeded/1]).
-export([repair_fail_session_on_pre_processing/1]).
-export([repair_fail_session_on_refund_succeeded/1]).
-export([repair_complex_first_scenario_succeeded/1]).
-export([repair_complex_second_scenario_succeeded/1]).
-export([repair_fulfill_session_on_processed_succeeded/1]).
-export([repair_fulfill_suspended_session_succeeded/1]).
-export([repair_fulfill_session_on_pre_processing_failed/1]).
-export([repair_fulfill_session_with_trx_succeeded/1]).
-export([repair_fulfill_session_on_refund_succeeded/1]).
-export([repair_fulfill_session_on_captured_succeeded/1]).

-export([consistent_account_balances/1]).

-export([allocation_create_invoice/1]).
-export([allocation_capture_payment/1]).
-export([allocation_refund_payment/1]).

-export([payment_cascade_success/1]).
-export([payment_cascade_fail_wo_available_attempt_limit/1]).
-export([payment_cascade_failures/1]).
-export([payment_cascade_no_route/1]).

%%

-behaviour(supervisor).

-export([init/1]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

%% tests descriptions

-type config() :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name() :: hg_ct_helper:group_name().
-type test_return() :: _ | no_return().

-define(PARTY_ID_WITH_LIMIT, <<"bIg merch limit">>).
-define(PARTY_ID_WITH_SEVERAL_LIMITS, <<"bIg merch limit cascading">>).
-define(PARTYID_EXTERNAL, <<"DUBTV">>).
-define(LIMIT_ID, <<"ID">>).
-define(LIMIT_ID2, <<"ID2">>).
-define(LIMIT_ID3, <<"ID3">>).
-define(LIMIT_ID4, <<"ID4">>).
-define(LIMIT_UPPER_BOUNDARY, 100000).
-define(BIG_LIMIT_UPPER_BOUNDARY, 1000000).
-define(DEFAULT_NEXT_CHANGE_TIMEOUT, 12000).

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

-spec all() -> [test_case_name() | {group, group_name()}].
all() ->
    [
        invalid_party_status,
        invalid_shop_status,

        % With constant domain config
        {group, all_non_destructive_tests},

        payments_w_bank_card_issuer_conditions,
        payments_w_bank_conditions,

        % With variable domain config
        {group, adjustments},
        {group, holds_management_with_custom_config},
        {group, refunds},
        {group, chargebacks},
        rounding_cashflow_volume,
        terms_retrieval,

        consistent_account_balances
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {all_non_destructive_tests, [], [
            {group, base_payments},
            % {group, operation_limits_legacy},
            {group, operation_limits},

            payment_w_customer_success,
            payment_customer_risk_score_check,
            payment_risk_score_check,
            payment_risk_score_check_fail,
            payment_risk_score_check_timeout,
            party_revision_check,

            invalid_payment_w_deprived_party,
            external_account_posting,
            terminal_cashflow_overrides_provider,

            {group, holds_management},

            {group, offsite_preauth_payment},

            payment_with_tokenized_bank_card,

            {group, adhoc_repairs},

            {group, repair_scenarios},

            {group, allocation},

            {group, route_cascading}
        ]},

        {base_payments, [], [
            invoice_creation_idempotency,
            invalid_invoice_shop,
            invalid_invoice_amount,
            invalid_invoice_currency,
            invalid_invoice_template_cost,
            invalid_invoice_template_id,
            invoive_w_template_idempotency,
            invoice_w_template,
            invoice_cancellation,
            overdue_invoice_cancellation,
            invoice_cancellation_after_payment_timeout,
            invalid_payment_amount,

            payment_start_idempotency,
            payment_success,
            register_payment_success,
            register_payment_customer_payer_success,
            payment_success_ruleset,
            processing_deadline_reached_test,
            payment_success_empty_cvv,
            payment_success_additional_info,
            payment_bank_card_category_condition,
            payment_w_terminal_w_payment_service_success,
            payment_w_crypto_currency_success,
            payment_w_wallet_success,
            payment_w_customer_success,
            payment_w_another_shop_customer,
            payment_w_another_party_customer,
            payment_w_deleted_customer,
            payment_w_mobile_commerce,
            payment_suspend_timeout_failure,
            payment_success_on_second_try,
            payment_fail_after_silent_callback,
            payment_temporary_unavailability_retry_success,
            payment_temporary_unavailability_too_many_retries,
            payment_has_optional_fields,
            payment_last_trx_correct,
            invoice_success_on_third_payment,
            payment_w_misconfigured_routing_failed,
            payment_capture_failed,
            payment_capture_retries_exceeded,
            payment_partial_capture_success,
            payment_error_in_cancel_session_does_not_cause_payment_failure,
            payment_error_in_capture_session_does_not_cause_payment_failure
        ]},

        {adjustments, [], [
            invalid_payment_adjustment,
            payment_adjustment_success,
            payment_adjustment_refunded_success,
            payment_adjustment_chargeback_success,
            payment_adjustment_captured_partial,
            payment_adjustment_captured_from_failed,
            payment_adjustment_failed_from_captured,
            status_adjustment_of_partial_refunded_payment,
            registered_payment_adjustment_success
        ]},

        {chargebacks, [], [
            create_chargeback_not_allowed,
            create_chargeback_inconsistent,
            create_chargeback_exceeded,
            create_chargeback_idempotency,
            cancel_payment_chargeback,
            cancel_partial_payment_chargeback,
            cancel_partial_payment_chargeback_exceeded,
            cancel_payment_chargeback_refund,
            reject_payment_chargeback_inconsistent,
            reject_payment_chargeback,
            reject_payment_chargeback_no_fees,
            reject_payment_chargeback_new_levy,
            accept_payment_chargeback_inconsistent,
            accept_payment_chargeback_exceeded,
            accept_payment_chargeback_empty_params,
            accept_payment_chargeback_twice,
            accept_payment_chargeback_new_body,
            accept_payment_chargeback_new_levy,
            reopen_accepted_payment_chargeback_fails,
            reopen_payment_chargeback_inconsistent,
            reopen_payment_chargeback_exceeded,
            reopen_payment_chargeback_cancel,
            reopen_payment_chargeback_reject,
            reopen_payment_chargeback_accept,
            reopen_payment_chargeback_skip_stage_accept,
            reopen_payment_chargeback_accept_new_levy,
            reopen_payment_chargeback_arbitration,
            reopen_payment_chargeback_arbitration_reopen_fails
        ]},

        {operation_limits, [], [
            payment_limit_success,
            register_payment_limit_success,
            payment_limit_other_shop_success,
            payment_limit_overflow,
            payment_partial_capture_limit_success,
            switch_provider_after_limit_overflow,
            limit_not_found,
            refund_limit_success,
            limit_hold_currency_error,
            limit_hold_operation_not_supported,
            limit_hold_payment_tool_not_supported,
            limit_hold_two_routes_failure
        ]},

        {refunds, [], [
            invalid_refund_party_status,
            invalid_refund_shop_status,
            %%{parallel, [], [
            retry_temporary_unavailability_refund,
            payment_refund_idempotency,
            payment_refund_success,
            payment_refund_failure,
            payment_partial_refunds_success,
            invalid_amount_payment_partial_refund,
            invalid_amount_partial_capture_and_refund,
            invalid_currency_payment_partial_refund,
            cant_start_simultaneous_partial_refunds,
            %% ]},
            deadline_doesnt_affect_payment_refund,
            ineligible_payment_partial_refund,
            payment_manual_refund,
            payment_refund_id_types,

            registered_payment_manual_refund_success
        ]},

        {holds_management, [], [
            payment_hold_cancellation,
            payment_hold_double_cancellation,
            payment_hold_cancellation_captured,
            payment_hold_auto_cancellation,
            payment_hold_capturing,
            payment_hold_double_capturing,
            payment_hold_capturing_cancelled,
            deadline_doesnt_affect_payment_capturing,
            invalid_currency_partial_capture,
            invalid_amount_partial_capture,
            payment_hold_partial_capturing,
            payment_hold_partial_capturing_with_cart,
            payment_hold_partial_capturing_with_cart_missing_cash,
            payment_hold_auto_capturing
        ]},

        {holds_management_with_custom_config, [], [
            invalid_permit_partial_capture_in_service,
            invalid_permit_partial_capture_in_provider
        ]},

        {offsite_preauth_payment, [], [
            payment_with_offsite_preauth_success,
            payment_with_offsite_preauth_failed
        ]},
        {adhoc_repairs, [], [
            adhoc_repair_working_failed,
            adhoc_repair_failed_succeeded,
            adhoc_repair_force_removal,
            adhoc_repair_invalid_changes_failed,
            adhoc_repair_force_invalid_transition
        ]},
        {repair_scenarios, [parallel], [
            repair_fail_pre_processing_succeeded,
            repair_skip_inspector_succeeded,
            repair_fail_session_on_processed_succeeded,
            repair_fail_suspended_session_succeeded,
            repair_fail_session_on_pre_processing,
            repair_fail_session_on_refund_succeeded,
            repair_complex_first_scenario_succeeded,
            repair_complex_second_scenario_succeeded,
            repair_fulfill_session_on_processed_succeeded,
            repair_fulfill_suspended_session_succeeded,
            repair_fulfill_session_on_pre_processing_failed,
            repair_fulfill_session_with_trx_succeeded,
            repair_fulfill_session_on_refund_succeeded,
            repair_fulfill_session_on_captured_succeeded
        ]},
        {allocation, [parallel], [
            allocation_create_invoice,
            allocation_capture_payment,
            allocation_refund_payment
        ]},
        {route_cascading, [], [
            payment_cascade_success,
            payment_cascade_fail_wo_available_attempt_limit,
            payment_cascade_failures,
            payment_cascade_no_route
        ]}
    ].

%% starting/stopping

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    % _ = dbg:tracer(),
    % _ = dbg:p(all, c),
    % _ = dbg:tpl({'hg_invoice_payment', 'p', '_'}, x),
    CowboySpec = hg_dummy_provider:get_http_cowboy_spec(),

    {Apps, Ret} = hg_ct_helper:start_apps([
        woody,
        scoper,
        dmt_client,
        bender_client,
        party_client,
        hg_proto,
        hellgate,
        snowflake,
        {cowboy, CowboySpec}
    ]),

    _ = hg_limiter_helper:init_per_suite(C),
    _ = hg_domain:insert(construct_domain_fixture()),

    RootUrl = maps:get(hellgate_root_url, Ret),

    PartyID = hg_utils:unique_id(),
    PartyClient = {party_client:create_client(), party_client:create_context()},
    CustomerClient = hg_client_customer:start(hg_ct_helper:create_client(RootUrl)),

    Party2ID = hg_utils:unique_id(),
    PartyClient2 = {party_client:create_client(), party_client:create_context()},
    CustomerClient2 = hg_client_customer:start(hg_ct_helper:create_client(RootUrl)),

    Party3ID = <<"bIg merch">>,
    _ = hg_ct_helper:create_party(Party3ID, PartyClient),
    _ = hg_ct_helper:create_party(?PARTYID_EXTERNAL, PartyClient),

    ShopID = hg_ct_helper:create_party_and_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Shop2ID = hg_ct_helper:create_party_and_shop(Party2ID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient2),

    {ok, SupPid} = supervisor:start_link(?MODULE, []),
    _ = unlink(SupPid),
    ok = start_kv_store(SupPid),
    NewC = [
        {party_id, PartyID},
        {party_client, PartyClient},
        {party_id_big_merch, Party3ID},
        {shop_id, ShopID},
        {customer_client, CustomerClient},
        {another_party_id, Party2ID},
        {another_shop_id, Shop2ID},
        {another_customer_client, CustomerClient2},
        {root_url, RootUrl},
        {apps, Apps},
        {test_sup, SupPid}
        | C
    ],

    ok = start_proxies([{hg_dummy_provider, 1, NewC}, {hg_dummy_inspector, 2, NewC}]),
    NewC.

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = hg_domain:cleanup(),
    _ = [application:stop(App) || App <- cfg(apps, C)],
    exit(cfg(test_sup, C), shutdown).

%% tests

-include("invoice_events.hrl").
-include("payment_events.hrl").
-include("customer_events.hrl").

-define(invoice(ID), #domain_Invoice{id = ID}).
-define(payment(ID), #domain_InvoicePayment{id = ID}).
-define(payment(ID, Revision), #domain_InvoicePayment{id = ID, party_revision = Revision}).
-define(adjustment(ID), #domain_InvoicePaymentAdjustment{id = ID}).
-define(adjustment(ID, Status), #domain_InvoicePaymentAdjustment{id = ID, status = Status}).
-define(adjustment_revision(Revision), #domain_InvoicePaymentAdjustment{party_revision = Revision}).
-define(adjustment_reason(Reason), #domain_InvoicePaymentAdjustment{reason = Reason}).
-define(invoice_state(Invoice), #payproc_Invoice{invoice = Invoice}).
-define(invoice_state(Invoice, Payments), #payproc_Invoice{invoice = Invoice, payments = Payments}).
-define(payment_state(Payment), #payproc_InvoicePayment{payment = Payment}).
-define(payment_state(Payment, Refunds), #payproc_InvoicePayment{payment = Payment, refunds = Refunds}).
-define(payment_route(Route), #payproc_InvoicePayment{route = Route}).
-define(refund_state(Refund), #payproc_InvoicePaymentRefund{refund = Refund}).
-define(payment_cashflow(CashFlow), #payproc_InvoicePayment{cash_flow = CashFlow}).
-define(payment_last_trx(Trx), #payproc_InvoicePayment{last_transaction_info = Trx}).
-define(invoice_w_status(Status), #domain_Invoice{status = Status}).
-define(invoice_w_revision(Revision), #domain_Invoice{party_revision = Revision}).
-define(payment_w_status(Status), #domain_InvoicePayment{status = Status}).
-define(payment_w_status(ID, Status), #domain_InvoicePayment{id = ID, status = Status}).
-define(invoice_payment_refund(Cash, Status), #domain_InvoicePaymentRefund{cash = Cash, status = Status}).
-define(trx_info(ID), #domain_TransactionInfo{id = ID}).
-define(trx_info(ID, Extra), #domain_TransactionInfo{id = ID, extra = Extra}).
-define(refund_id(RefundID), #domain_InvoicePaymentRefund{id = RefundID}).
-define(refund_id(RefundID, ExternalID), #domain_InvoicePaymentRefund{id = RefundID, external_id = ExternalID}).
-define(contact_info(), ?contact_info(undefined)).

-define(invalid_invoice_status(Status),
    {exception, #payproc_InvalidInvoiceStatus{status = Status}}
).

-define(invalid_payment_status(Status),
    {exception, #payproc_InvalidPaymentStatus{status = Status}}
).

-define(invalid_payment_target_status(Status),
    {exception, #payproc_InvalidPaymentTargetStatus{status = Status}}
).

-define(payment_already_has_status(Status),
    {exception, #payproc_InvoicePaymentAlreadyHasStatus{status = Status}}
).

-define(invalid_adjustment_status(Status),
    {exception, #payproc_InvalidPaymentAdjustmentStatus{status = Status}}
).

-define(invalid_adjustment_pending(ID),
    {exception, #payproc_InvoicePaymentAdjustmentPending{id = ID}}
).

-define(operation_not_permitted(),
    {exception, #payproc_OperationNotPermitted{}}
).

-define(chargeback_cannot_reopen_arbitration(),
    {exception, #payproc_InvoicePaymentChargebackCannotReopenAfterArbitration{}}
).

-define(chargeback_pending(),
    {exception, #payproc_InvoicePaymentChargebackPending{}}
).

-define(invalid_chargeback_status(Status),
    {exception, #payproc_InvoicePaymentChargebackInvalidStatus{status = Status}}
).

-define(invoice_payment_amount_exceeded(Maximum),
    {exception, #payproc_InvoicePaymentAmountExceeded{maximum = Maximum}}
).

-define(inconsistent_chargeback_currency(Currency),
    {exception, #payproc_InconsistentChargebackCurrency{currency = Currency}}
).

-define(inconsistent_refund_currency(Currency),
    {exception, #payproc_InconsistentRefundCurrency{currency = Currency}}
).

-define(inconsistent_capture_currency(Currency),
    {exception, #payproc_InconsistentCaptureCurrency{payment_currency = Currency}}
).

-define(amount_exceeded_capture_balance(Amount),
    {exception, #payproc_AmountExceededCaptureBalance{payment_amount = Amount}}
).

-define(CB_PROVIDER_LEVY, 50).
-define(merchant_to_system_share_1, ?share(45, 1000, operation_amount)).
-define(merchant_to_system_share_2, ?share(100, 1000, operation_amount)).
-define(merchant_to_system_share_3, ?share(40, 1000, operation_amount)).
-define(system_to_provider_share_initial, ?share(21, 1000, operation_amount)).
-define(system_to_provider_share_actual, ?share(16, 1000, operation_amount)).
-define(system_to_external_fixed, ?fixed(20, <<"RUB">>)).

-define(assertRouteNotFound(Failure, Sub, ReasonSubstring), begin
    ok = payproc_errors:match('PaymentFailure', Failure, fun({no_route_found, Sub}) -> ok end),
    Reason = Failure#domain_Failure.reason,
    ?assert(
        nomatch =/= binary:match(Reason, ReasonSubstring),
        <<"Failure reason '", Reason/binary, "' for 'no_route_found' doesn't match '", ReasonSubstring/binary, "'">>
    )
end).

-spec init_per_group(group_name(), config()) -> config().
init_per_group(route_cascading, C) ->
    init_operation_limits_group(C);
init_per_group(operation_limits, C) ->
    init_operation_limits_group(C);
init_per_group(allocation, C) ->
    init_allocation_group(C);
init_per_group(_, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, _C) ->
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) when
    Name == payment_adjustment_success;
    Name == payment_adjustment_refunded_success;
    Name == payment_adjustment_chargeback_success;
    Name == payment_adjustment_captured_partial;
    Name == payment_adjustment_captured_from_failed;
    Name == payment_adjustment_failed_from_captured;
    Name == registered_payment_adjustment_success
->
    Revision = hg_domain:head(),
    Fixture = get_payment_adjustment_fixture(Revision),
    _ = hg_domain:upsert(Fixture),
    [{original_domain_revision, Revision} | init_per_testcase(C)];
init_per_testcase(rounding_cashflow_volume, C) ->
    override_domain_fixture(fun get_cashflow_rounding_fixture/1, C);
init_per_testcase(payments_w_bank_card_issuer_conditions, C) ->
    override_domain_fixture(fun payments_w_bank_card_issuer_conditions_fixture/1, C);
init_per_testcase(payments_w_bank_conditions, C) ->
    override_domain_fixture(fun payments_w_bank_conditions_fixture/1, C);
init_per_testcase(payment_w_misconfigured_routing_failed, C) ->
    override_domain_fixture(fun payment_w_misconfigured_routing_failed_fixture/1, C);
init_per_testcase(ineligible_payment_partial_refund, C) ->
    override_domain_fixture(fun(_) -> construct_term_set_for_refund_eligibility_time(1) end, C);
init_per_testcase(invalid_permit_partial_capture_in_service, C) ->
    override_domain_fixture(fun construct_term_set_for_partial_capture_service_permit/1, C);
init_per_testcase(invalid_permit_partial_capture_in_provider, C) ->
    override_domain_fixture(fun construct_term_set_for_partial_capture_provider_permit/1, C);
init_per_testcase(payment_cascade_no_route, C) ->
    override_domain_fixture(fun routes_ruleset_w_one_failing_route_fixture/1, C);
init_per_testcase(payment_cascade_failures, C) ->
    override_domain_fixture(fun routes_ruleset_w_different_failing_providers_fixture/1, C);
init_per_testcase(payment_cascade_fail_wo_available_attempt_limit, C) ->
    override_domain_fixture(fun merchant_payments_service_terms_wo_attempt_limit/1, C);
init_per_testcase(payment_cascade_success, C) ->
    override_domain_fixture(fun routes_ruleset_w_failing_provider_fixture/1, C);
init_per_testcase(limit_hold_currency_error, C) ->
    override_domain_fixture(fun patch_limit_config_w_invalid_currency/1, C);
init_per_testcase(limit_hold_operation_not_supported, C) ->
    override_domain_fixture(fun patch_limit_config_for_withdrawal/1, C);
init_per_testcase(limit_hold_payment_tool_not_supported, C) ->
    override_domain_fixture(fun patch_with_unsupported_payment_tool/1, C);
init_per_testcase(limit_hold_two_routes_failure, C) ->
    override_domain_fixture(fun patch_providers_limits_to_fail_and_overflow/1, C);
init_per_testcase(_Name, C) ->
    init_per_testcase(C).

override_domain_fixture(Fixture, C) ->
    Revision = hg_domain:head(),
    _ = hg_domain:upsert(Fixture(Revision)),
    [{original_domain_revision, Revision} | init_per_testcase(C)].

init_per_testcase(C) ->
    ApiClient = hg_ct_helper:create_client(cfg(root_url, C)),
    Client = hg_client_invoicing:start_link(ApiClient),
    ClientTpl = hg_client_invoice_templating:start_link(ApiClient),
    ok = hg_context:save(hg_context:create()),
    [{client, Client}, {client_tpl, ClientTpl} | C].

-spec end_per_testcase(test_case_name(), config()) -> _.
end_per_testcase(_Name, C) ->
    ok = hg_context:cleanup(),
    _ =
        case cfg(original_domain_revision, C) of
            Revision when is_integer(Revision) ->
                _ = hg_domain:reset(Revision);
            undefined ->
                ok
        end.

-spec invoice_creation_idempotency(config()) -> _ | no_return().
invoice_creation_idempotency(C) ->
    Client = cfg(client, C),
    ShopID = cfg(shop_id, C),
    PartyID = cfg(party_id, C),
    InvoiceID = hg_utils:unique_id(),
    ExternalID = <<"123">>,
    InvoiceParams0 = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(100000, <<"RUB">>)),
    InvoiceParams1 = InvoiceParams0#payproc_InvoiceParams{
        id = InvoiceID,
        external_id = ExternalID
    },
    Invoice1 = hg_client_invoicing:create(InvoiceParams1, Client),
    #payproc_Invoice{invoice = DomainInvoice} = Invoice1,
    #domain_Invoice{
        id = InvoiceID,
        external_id = ExternalID
    } = DomainInvoice,
    Invoice2 = hg_client_invoicing:create(InvoiceParams1, Client),
    Invoice1 = Invoice2.

-spec invalid_invoice_shop(config()) -> _ | no_return().
invalid_invoice_shop(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = genlib:unique(),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(10000)),
    {exception, #payproc_ShopNotFound{}} = hg_client_invoicing:create(InvoiceParams, Client).

-spec invalid_invoice_amount(config()) -> test_return().
invalid_invoice_amount(C) ->
    Client = cfg(client, C),
    ShopID = cfg(shop_id, C),
    PartyID = cfg(party_id, C),
    InvoiceParams0 = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(-10000)),
    {exception, #base_InvalidRequest{
        errors = [<<"Invalid amount">>]
    }} = hg_client_invoicing:create(InvoiceParams0, Client),
    InvoiceParams1 = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(5)),
    {exception, #payproc_InvoiceTermsViolated{reason = {invoice_unpayable, _}}} =
        hg_client_invoicing:create(InvoiceParams1, Client),
    InvoiceParams2 = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(42000000000)),
    {exception, #payproc_InvoiceTermsViolated{reason = {invoice_unpayable, _}}} =
        hg_client_invoicing:create(InvoiceParams2, Client).

-spec invalid_invoice_currency(config()) -> test_return().
invalid_invoice_currency(C) ->
    Client = cfg(client, C),
    ShopID = cfg(shop_id, C),
    PartyID = cfg(party_id, C),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(100, <<"KEK">>)),
    {exception, #base_InvalidRequest{
        errors = [<<"Invalid currency">>]
    }} = hg_client_invoicing:create(InvoiceParams, Client).

-spec invalid_party_status(config()) -> test_return().
invalid_party_status(C) ->
    {PartyClient, Context} = cfg(party_client, C),
    Client = cfg(client, C),
    ShopID = cfg(shop_id, C),
    PartyID = cfg(party_id, C),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(100000)),
    TplID = create_invoice_tpl(C),
    InvoiceParamsWithTpl = hg_ct_helper:make_invoice_params_tpl(TplID),

    ok = party_client_thrift:suspend(PartyID, PartyClient, Context),
    {exception, #payproc_InvalidPartyStatus{
        status = {suspension, {suspended, _}}
    }} = hg_client_invoicing:create(InvoiceParams, Client),
    {exception, #payproc_InvalidPartyStatus{
        status = {suspension, {suspended, _}}
    }} = hg_client_invoicing:create_with_tpl(InvoiceParamsWithTpl, Client),
    ok = party_client_thrift:activate(PartyID, PartyClient, Context),

    ok = party_client_thrift:block(PartyID, <<"BLOOOOCK">>, PartyClient, Context),
    {exception, #payproc_InvalidPartyStatus{
        status = {blocking, {blocked, _}}
    }} = hg_client_invoicing:create(InvoiceParams, Client),
    {exception, #payproc_InvalidPartyStatus{
        status = {blocking, {blocked, _}}
    }} = hg_client_invoicing:create_with_tpl(InvoiceParamsWithTpl, Client),
    ok = party_client_thrift:unblock(PartyID, <<"UNBLOOOCK">>, PartyClient, Context).

-spec invalid_shop_status(config()) -> test_return().
invalid_shop_status(C) ->
    {PartyClient, Context} = cfg(party_client, C),
    Client = cfg(client, C),
    ShopID = cfg(shop_id, C),
    PartyID = cfg(party_id, C),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(100000)),
    TplID = create_invoice_tpl(C),
    InvoiceParamsWithTpl = hg_ct_helper:make_invoice_params_tpl(TplID),

    ok = party_client_thrift:suspend_shop(PartyID, ShopID, PartyClient, Context),
    {exception, #payproc_InvalidShopStatus{
        status = {suspension, {suspended, _}}
    }} = hg_client_invoicing:create(InvoiceParams, Client),
    {exception, #payproc_InvalidShopStatus{
        status = {suspension, {suspended, _}}
    }} = hg_client_invoicing:create_with_tpl(InvoiceParamsWithTpl, Client),
    ok = party_client_thrift:activate_shop(PartyID, ShopID, PartyClient, Context),

    ok = party_client_thrift:block_shop(PartyID, ShopID, <<"BLOOOOCK">>, PartyClient, Context),
    {exception, #payproc_InvalidShopStatus{
        status = {blocking, {blocked, _}}
    }} = hg_client_invoicing:create(InvoiceParams, Client),
    {exception, #payproc_InvalidShopStatus{
        status = {blocking, {blocked, _}}
    }} = hg_client_invoicing:create_with_tpl(InvoiceParamsWithTpl, Client),
    ok = party_client_thrift:unblock_shop(PartyID, ShopID, <<"UNBLOOOCK">>, PartyClient, Context).

-spec invalid_invoice_template_cost(config()) -> _ | no_return().
invalid_invoice_template_cost(C) ->
    Client = cfg(client, C),
    Context = hg_ct_helper:make_invoice_context(),

    Cost1 = make_tpl_cost(unlim, sale, "30%"),
    TplID = create_invoice_tpl(C, Cost1, Context),
    Params1 = hg_ct_helper:make_invoice_params_tpl(TplID),
    {exception, #base_InvalidRequest{
        errors = [?INVOICE_TPL_NO_COST]
    }} = hg_client_invoicing:create_with_tpl(Params1, Client),

    Cost2 = make_tpl_cost(fixed, 100, <<"RUB">>),
    _ = update_invoice_tpl(TplID, Cost2, C),
    Params2 = hg_ct_helper:make_invoice_params_tpl(TplID, make_cash(50, <<"RUB">>)),
    {exception, #base_InvalidRequest{
        errors = [?INVOICE_TPL_BAD_COST]
    }} = hg_client_invoicing:create_with_tpl(Params2, Client),
    Params3 = hg_ct_helper:make_invoice_params_tpl(TplID, make_cash(100, <<"KEK">>)),
    {exception, #base_InvalidRequest{
        errors = [?INVOICE_TPL_BAD_COST]
    }} = hg_client_invoicing:create_with_tpl(Params3, Client),

    Cost3 = make_tpl_cost(range, {inclusive, 100, <<"RUB">>}, {inclusive, 10000, <<"RUB">>}),
    _ = update_invoice_tpl(TplID, Cost3, C),
    Params4 = hg_ct_helper:make_invoice_params_tpl(TplID, make_cash(50, <<"RUB">>)),
    {exception, #base_InvalidRequest{
        errors = [?INVOICE_TPL_BAD_AMOUNT]
    }} = hg_client_invoicing:create_with_tpl(Params4, Client),
    Params5 = hg_ct_helper:make_invoice_params_tpl(TplID, make_cash(50000, <<"RUB">>)),
    {exception, #base_InvalidRequest{
        errors = [?INVOICE_TPL_BAD_AMOUNT]
    }} = hg_client_invoicing:create_with_tpl(Params5, Client),
    Params6 = hg_ct_helper:make_invoice_params_tpl(TplID, make_cash(500, <<"KEK">>)),
    {exception, #base_InvalidRequest{
        errors = [?INVOICE_TPL_BAD_CURRENCY]
    }} = hg_client_invoicing:create_with_tpl(Params6, Client),

    Cost4 = make_tpl_cost(fixed, 42000000000, <<"RUB">>),
    _ = update_invoice_tpl(TplID, Cost4, C),
    Params7 = hg_ct_helper:make_invoice_params_tpl(TplID, make_cash(42000000000, <<"RUB">>)),
    {exception, #payproc_InvoiceTermsViolated{reason = {invoice_unpayable, _}}} =
        hg_client_invoicing:create_with_tpl(Params7, Client).

-spec invalid_invoice_template_id(config()) -> _ | no_return().
invalid_invoice_template_id(C) ->
    Client = cfg(client, C),

    TplID1 = <<"Watsthat">>,
    Params1 = hg_ct_helper:make_invoice_params_tpl(TplID1),
    {exception, #payproc_InvoiceTemplateNotFound{}} = hg_client_invoicing:create_with_tpl(Params1, Client),

    TplID2 = create_invoice_tpl(C),
    _ = delete_invoice_tpl(TplID2, C),
    Params2 = hg_ct_helper:make_invoice_params_tpl(TplID2),
    {exception, #payproc_InvoiceTemplateRemoved{}} = hg_client_invoicing:create_with_tpl(Params2, Client).

-spec invoive_w_template_idempotency(config()) -> _ | no_return().
invoive_w_template_idempotency(C) ->
    Client = cfg(client, C),
    TplCost1 = {_, FixedCost} = make_tpl_cost(fixed, 10000, <<"RUB">>),
    TplContext1 = hg_ct_helper:make_invoice_context(<<"default context">>),
    TplID = create_invoice_tpl(C, TplCost1, TplContext1),
    #domain_InvoiceTemplate{
        owner_id = TplPartyID,
        shop_id = TplShopID,
        context = TplContext1
    } = get_invoice_tpl(TplID, C),
    InvoiceCost1 = FixedCost,
    InvoiceContext1 = hg_ct_helper:make_invoice_context(),
    InvoiceID = hg_utils:unique_id(),
    ExternalID = hg_utils:unique_id(),

    Params = hg_ct_helper:make_invoice_params_tpl(InvoiceID, TplID, InvoiceCost1, InvoiceContext1),
    Params1 = Params#payproc_InvoiceWithTemplateParams{
        external_id = ExternalID
    },
    ?invoice_state(#domain_Invoice{
        id = InvoiceID,
        owner_id = TplPartyID,
        shop_id = TplShopID,
        template_id = TplID,
        cost = InvoiceCost1,
        context = InvoiceContext1,
        external_id = ExternalID
    }) = hg_client_invoicing:create_with_tpl(Params1, Client),

    OtherParams = hg_ct_helper:make_invoice_params_tpl(InvoiceID, TplID, undefined, undefined),
    Params2 = OtherParams#payproc_InvoiceWithTemplateParams{
        external_id = hg_utils:unique_id()
    },
    ?invoice_state(#domain_Invoice{
        id = InvoiceID,
        owner_id = TplPartyID,
        shop_id = TplShopID,
        template_id = TplID,
        cost = InvoiceCost1,
        context = InvoiceContext1,
        external_id = ExternalID
    }) = hg_client_invoicing:create_with_tpl(Params2, Client).

-spec invoice_w_template(config()) -> _ | no_return().
invoice_w_template(C) ->
    Client = cfg(client, C),
    TplCost1 = {_, FixedCost} = make_tpl_cost(fixed, 10000, <<"RUB">>),
    TplContext1 = hg_ct_helper:make_invoice_context(<<"default context">>),
    TplID = create_invoice_tpl(C, TplCost1, TplContext1),
    #domain_InvoiceTemplate{
        owner_id = TplPartyID,
        shop_id = TplShopID,
        context = TplContext1
    } = get_invoice_tpl(TplID, C),
    InvoiceCost1 = FixedCost,
    InvoiceContext1 = hg_ct_helper:make_invoice_context(<<"invoice specific context">>),

    Params1 = hg_ct_helper:make_invoice_params_tpl(TplID, InvoiceCost1, InvoiceContext1),
    ?invoice_state(#domain_Invoice{
        owner_id = TplPartyID,
        shop_id = TplShopID,
        template_id = TplID,
        cost = InvoiceCost1,
        context = InvoiceContext1
    }) = hg_client_invoicing:create_with_tpl(Params1, Client),

    Params2 = hg_ct_helper:make_invoice_params_tpl(TplID),
    ?invoice_state(#domain_Invoice{
        owner_id = TplPartyID,
        shop_id = TplShopID,
        template_id = TplID,
        cost = InvoiceCost1,
        context = TplContext1
    }) = hg_client_invoicing:create_with_tpl(Params2, Client),

    TplCost2 = make_tpl_cost(range, {inclusive, 100, <<"RUB">>}, {inclusive, 10000, <<"RUB">>}),
    _ = update_invoice_tpl(TplID, TplCost2, C),
    ?invoice_state(#domain_Invoice{
        owner_id = TplPartyID,
        shop_id = TplShopID,
        template_id = TplID,
        cost = InvoiceCost1,
        context = InvoiceContext1
    }) = hg_client_invoicing:create_with_tpl(Params1, Client),

    TplCost3 = make_tpl_cost(unlim, sale, "146%"),
    _ = update_invoice_tpl(TplID, TplCost3, C),
    ?invoice_state(#domain_Invoice{
        owner_id = TplPartyID,
        shop_id = TplShopID,
        template_id = TplID,
        cost = InvoiceCost1,
        context = InvoiceContext1
    }) = hg_client_invoicing:create_with_tpl(Params1, Client).

-spec invoice_cancellation(config()) -> test_return().
invoice_cancellation(C) ->
    Client = cfg(client, C),
    ShopID = cfg(shop_id, C),
    PartyID = cfg(party_id, C),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_cash(10000)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invalid_invoice_status(_) = hg_client_invoicing:fulfill(InvoiceID, <<"perfect">>, Client),
    ok = hg_client_invoicing:rescind(InvoiceID, <<"whynot">>, Client).

-spec overdue_invoice_cancellation(config()) -> test_return().
overdue_invoice_cancellation(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(1), 10000, C),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

-spec invoice_cancellation_after_payment_timeout(config()) -> test_return().
invoice_cancellation_after_payment_timeout(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberdusk">>, make_due_date(3), 1000, C),
    PaymentParams = make_tds_payment_params(instant, ?pmt_sys(<<"visa-ref">>)),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    _UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    %% wait for payment timeout
    PaymentID = await_payment_process_timeout(InvoiceID, PaymentID, Client),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

-spec invalid_payment_amount(config()) -> test_return().
invalid_payment_amount(C) ->
    Client = cfg(client, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    InvoiceID2 = start_invoice(<<"rubberduck">>, make_due_date(10), 430000000, C),
    {exception, #base_InvalidRequest{
        errors = [<<"Invalid amount, more", _/binary>>]
    }} = hg_client_invoicing:start_payment(InvoiceID2, PaymentParams, Client).

-spec payment_start_idempotency(config()) -> test_return().
payment_start_idempotency(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams0 = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID1 = <<"1">>,
    ExternalID = <<"42">>,
    PaymentParams1 = PaymentParams0#payproc_InvoicePaymentParams{
        id = PaymentID1,
        external_id = ExternalID
    },
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID1,
        external_id = ExternalID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams1, Client),
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID1,
        external_id = ExternalID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams1, Client),
    PaymentParams2 = PaymentParams0#payproc_InvoicePaymentParams{id = <<"2">>},
    {exception, #payproc_InvoicePaymentPending{id = PaymentID1}} =
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams2, Client),
    PaymentID1 = execute_payment(InvoiceID, PaymentParams1, Client),
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID1,
        external_id = ExternalID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams1, Client).

-spec payment_success(config()) -> test_return().
payment_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Context = #base_Content{
        type = <<"application/x-erlang-binary">>,
        data = erlang:term_to_binary({you, 643, "not", [<<"welcome">>, here]})
    },
    PayerSessionInfo = #domain_PayerSessionInfo{
        redirect_url = RedirectURL = <<"https://redirectly.io/merchant">>
    },
    PaymentParams = (make_payment_params(?pmt_sys(<<"visa-ref">>)))#payproc_InvoicePaymentParams{
        payer_session_info = PayerSessionInfo,
        context = Context
    },
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [PaymentSt = ?payment_state(Payment)]
    ) = hg_client_invoicing:get(InvoiceID, Client),
    ?payment_w_status(PaymentID, ?captured()) = Payment,
    ?payment_last_trx(Trx) = PaymentSt,
    ?assertMatch(
        #domain_InvoicePayment{
            payer_session_info = PayerSessionInfo,
            context = Context
        },
        Payment
    ),
    ?assertMatch(
        #domain_TransactionInfo{
            extra = #{
                <<"payment.payer_session_info.redirect_url">> := RedirectURL
            }
        },
        Trx
    ).

-spec register_payment_success(config()) -> test_return().
register_payment_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Context = #base_Content{
        type = <<"application/x-erlang-binary">>,
        data = erlang:term_to_binary({you, 643, "not", [<<"welcome">>, here]})
    },
    PayerSessionInfo = #domain_PayerSessionInfo{},
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    Route = ?route(?prv(1), ?trm(1)),
    Cost = ?cash(41999, <<"RUB">>),
    ID = hg_utils:unique_id(),
    ExternalID = hg_utils:unique_id(),
    TransactionInfo = ?trx_info(<<"1">>, #{}),
    OccurredAt = hg_datetime:format_now(),
    PaymentParams = #payproc_RegisterInvoicePaymentParams{
        payer_params =
            {payment_resource, #payproc_PaymentResourcePayerParams{
                resource = #domain_DisposablePaymentResource{
                    payment_tool = PaymentTool,
                    payment_session_id = Session,
                    client_info = #domain_ClientInfo{}
                },
                contact_info = ?contact_info()
            }},
        route = Route,
        payer_session_info = PayerSessionInfo,
        context = Context,
        cost = Cost,
        id = ID,
        external_id = ExternalID,
        transaction_info = TransactionInfo,
        risk_score = high,
        occurred_at = OccurredAt
    },
    PaymentID = register_payment(InvoiceID, PaymentParams, true, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(?invoice_w_status(?invoice_paid())) =
        hg_client_invoicing:get(InvoiceID, Client),
    PaymentSt = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),

    ?payment_route(Route) = PaymentSt,
    ?payment_last_trx(TransactionInfo) = PaymentSt,
    ?payment_state(Payment) = PaymentSt,
    ?payment_w_status(PaymentID, ?captured()) = Payment,
    ?assertMatch(
        #domain_InvoicePayment{
            id = ID,
            payer_session_info = PayerSessionInfo,
            context = Context,
            flow = ?invoice_payment_flow_instant(),
            cost = Cost,
            external_id = ExternalID
        },
        Payment
    ).

-spec register_payment_customer_payer_success(config()) -> test_return().
register_payment_customer_payer_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    Route = ?route(?prv(1), ?trm(1)),
    CustomerID = make_customer_w_rec_tool(
        cfg(party_id, C), cfg(shop_id, C), cfg(customer_client, C), ?pmt_sys(<<"visa-ref">>)
    ),
    PaymentParams = #payproc_RegisterInvoicePaymentParams{
        payer_params =
            {customer, #payproc_CustomerPayerParams{
                customer_id = CustomerID
            }},
        route = Route,
        transaction_info = ?trx_info(<<"1">>, #{})
    },
    PaymentID = register_payment(InvoiceID, PaymentParams, false, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(?invoice_w_status(?invoice_paid())) =
        hg_client_invoicing:get(InvoiceID, Client).

%%=============================================================================
%% register_* cases helpers

register_invoice_payment(ShopID, Client, C) ->
    Route = ?route(?prv(1), ?trm(1)),
    register_invoice_payment(Route, ShopID, Client, C).

register_invoice_payment(Route, ShopID, Client, C) ->
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = #payproc_RegisterInvoicePaymentParams{
        payer_params =
            {payment_resource, #payproc_PaymentResourcePayerParams{
                resource = #domain_DisposablePaymentResource{
                    payment_tool = PaymentTool,
                    payment_session_id = Session,
                    client_info = #domain_ClientInfo{}
                },
                contact_info = ?contact_info()
            }},
        route = Route,
        transaction_info = ?trx_info(<<"1">>, #{})
    },
    PaymentID = register_payment(InvoiceID, PaymentParams, false, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    {InvoiceID, PaymentID}.

%%=============================================================================
%% operation_limits group

-spec init_operation_limits_group(config()) -> config().
init_operation_limits_group(C) ->
    PartyID1 = ?PARTY_ID_WITH_LIMIT,
    PartyID2 = ?PARTY_ID_WITH_SEVERAL_LIMITS,
    _ = hg_ct_helper:create_party(PartyID1, cfg(party_client, C)),
    _ = hg_ct_helper:create_party(PartyID2, cfg(party_client, C)),
    [{limits, #{party_id => PartyID1, party_id_w_several_limits => PartyID2}} | C].

-spec payment_limit_success(config()) -> test_return().
payment_limit_success(C) ->
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    #{party_id := PartyID} = cfg(limits, C),
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),

    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(_Payment)]
    ) = create_payment(PartyID, ShopID, 10000, Client, ?pmt_sys(<<"visa-ref">>)).

-spec register_payment_limit_success(config()) -> test_return().
register_payment_limit_success(C0) ->
    Client = cfg(client, C0),
    PartyClient = cfg(party_client, C0),
    #{party_id := PartyID} = cfg(limits, C0),
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    C1 = [{party_id, PartyID}, {shop_id, ShopID} | C0],
    Route = ?route(?prv(5), ?trm(12)),
    {InvoiceID, PaymentID} = register_invoice_payment(Route, ShopID, Client, C1),
    ?invoice_state(?invoice_w_status(?invoice_paid())) =
        hg_client_invoicing:get(InvoiceID, Client),
    ?payment_state(?payment_w_status(PaymentID, ?captured())) =
        hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client).

-spec payment_limit_other_shop_success(config()) -> test_return().
payment_limit_other_shop_success(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    #{party_id := PartyID} = cfg(limits, C),
    ShopID1 = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    ShopID2 = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),
    PaymentAmount = ?LIMIT_UPPER_BOUNDARY - 1,

    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(_Payment1)]
    ) = create_payment(PartyID, ShopID1, PaymentAmount, Client, PmtSys),

    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(_Payment2)]
    ) = create_payment(PartyID, ShopID2, PaymentAmount, Client, PmtSys).

-spec payment_limit_overflow(config()) -> test_return().
payment_limit_overflow(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    RootUrl = cfg(root_url, C),
    #{party_id := PartyID} = cfg(limits, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),
    PaymentAmount = ?LIMIT_UPPER_BOUNDARY - 1,
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()) = Invoice,
        [?payment_state(Payment)]
    ) = create_payment(PartyID, ShopID, PaymentAmount, Client, PmtSys),

    Failure = create_payment_limit_overflow(PartyID, ShopID, 1000, Client, PmtSys),
    ok = hg_limiter_helper:assert_payment_limit_amount(PaymentAmount, Payment, Invoice),
    ok = payproc_errors:match(
        'PaymentFailure',
        Failure,
        fun({no_route_found, {forbidden, _}}) -> ok end
    ).

-spec limit_hold_currency_error(config()) -> test_return().
limit_hold_currency_error(C) ->
    payment_route_not_found(C).

-spec limit_hold_operation_not_supported(config()) -> test_return().
limit_hold_operation_not_supported(C) ->
    payment_route_not_found(C).

-spec limit_hold_payment_tool_not_supported(config()) -> test_return().
limit_hold_payment_tool_not_supported(C) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
    payment_route_not_found(PaymentTool, Session, C).

-spec limit_hold_two_routes_failure(config()) -> test_return().
limit_hold_two_routes_failure(C) ->
    payment_route_not_found(C).

payment_route_not_found(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    payment_route_not_found(PaymentTool, Session, C).

payment_route_not_found(PaymentTool, Session, C) ->
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    #{party_id := PartyID} = cfg(limits, C),
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),

    Cash = make_cash(10000, <<"RUB">>),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_due_date(10), Cash),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),

    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    _ = start_payment_ev(InvoiceID, Client),
    ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})) =
        next_change(InvoiceID, Client),
    ?assertRouteNotFound(Failure, _, <<"{rejected_routes,[{">>).

-spec switch_provider_after_limit_overflow(config()) -> test_return().
switch_provider_after_limit_overflow(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    #{party_id_w_several_limits := PartyID} = cfg(limits, C),
    PaymentAmount = 69999,
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),

    ?invoice_state(
        ?invoice_w_status(?invoice_paid()) = Invoice,
        [?payment_state(Payment)]
    ) = create_payment(PartyID, ShopID, PaymentAmount, Client, PmtSys),

    ok = hg_limiter_helper:assert_payment_limit_amount(PaymentAmount, Payment, Invoice),

    #domain_InvoicePayment{id = PaymentID} = Payment,
    InvoiceID = start_invoice(PartyID, ShopID, <<"rubberduck">>, make_due_date(10), PaymentAmount, Client),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(
        InvoiceID,
        make_payment_params(PmtSys),
        Client
    ),
    Route = start_payment_ev(InvoiceID, Client),
    ?assertMatch(#domain_PaymentRoute{provider = #domain_ProviderRef{id = 6}}, Route),
    ?payment_ev(PaymentID2, ?cash_flow_changed(_)) = next_change(InvoiceID, Client),
    PaymentID2 = await_payment_session_started(InvoiceID, PaymentID2, Client, ?processed()),
    PaymentID2 = await_payment_process_finish(InvoiceID, PaymentID2, Client).

-spec limit_not_found(config()) -> test_return().
limit_not_found(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    #{party_id_w_several_limits := PartyID} = cfg(limits, C),
    PaymentAmount = 69999,
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),

    ?invoice_state(
        ?invoice_w_status(?invoice_paid()) = Invoice,
        [?payment_state(Payment)]
    ) = create_payment(PartyID, ShopID, PaymentAmount, Client, PmtSys),

    {exception, _} = hg_limiter_helper:get_payment_limit_amount(<<"WrongID">>, 0, Payment, Invoice).

-spec refund_limit_success(config()) -> test_return().
refund_limit_success(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    #{party_id := PartyID} = cfg(limits, C),
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),

    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(_Payment)]
    ) = create_payment(PartyID, ShopID, 50000, Client, PmtSys),

    ?invoice_state(
        ?invoice_w_status(?invoice_paid()) = Invoice,
        [?payment_state(Payment)]
    ) = create_payment(PartyID, ShopID, 40000, Client, PmtSys),
    ?invoice(InvoiceID) = Invoice,
    ?payment(PaymentID) = Payment,

    Failure = create_payment_limit_overflow(PartyID, ShopID, 50000, Client, PmtSys),
    ok = payproc_errors:match(
        'PaymentFailure',
        Failure,
        fun({no_route_found, {forbidden, _}}) -> ok end
    ),
    % create a refund finally
    RefundParams = make_refund_params(),
    RefundID = execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    #domain_InvoicePaymentRefund{status = ?refund_succeeded()} =
        hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client),
    % no more refunds for you
    ?invalid_payment_status(?refunded()) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    % try payment after refund(limit was decreased)
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(_)]
    ) = create_payment(PartyID, ShopID, 40000, Client, PmtSys).

-spec payment_partial_capture_limit_success(config()) -> test_return().
payment_partial_capture_limit_success(C) ->
    InitialCost = 1000 * 10,
    PartialCost = 700 * 10,
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),

    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    #{party_id := PartyID} = cfg(limits, C),
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(8), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),

    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_due_date(100), make_cash(InitialCost)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),

    % start payment
    ?payment_state(?payment(PaymentID)) =
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_started(InvoiceID, PaymentID, Client),
    {CF1, _} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    % do a partial capture
    Cash = ?cash(PartialCost, <<"RUB">>),
    Reason = <<"ok">>,
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client),
    PaymentID = await_payment_partial_capture(InvoiceID, PaymentID, Reason, Cash, Client),

    % let's check results
    InvoiceState = hg_client_invoicing:get(InvoiceID, Client),
    ?invoice_state(Invoice, [PaymentState]) = InvoiceState,
    ?assertMatch(?invoice_w_status(?invoice_paid()), Invoice),
    ?assertMatch(?payment_state(?payment_w_status(PaymentID, ?captured(Reason, Cash))), PaymentState),
    ?payment_cashflow(CF2) = PaymentState,
    ?assertNotEqual(undefined, CF2),
    ?assertNotEqual(CF1, CF2).

%%----------------- operation_limits helpers

create_payment(PartyID, ShopID, Amount, Client, PmtSys) ->
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_due_date(10), make_cash(Amount)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),

    PaymentParams = make_payment_params(PmtSys),
    _PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    hg_client_invoicing:get(InvoiceID, Client).

create_payment_limit_overflow(PartyID, ShopID, Amount, Client, PmtSys) ->
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_due_date(10), make_cash(Amount)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),
    PaymentParams = make_payment_params(PmtSys),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_started(InvoiceID, PaymentID, Client),
    await_payment_rollback(InvoiceID, PaymentID, Client).

%%----------------- operation_limits group end

-spec payment_success_ruleset(config()) -> test_return().
payment_success_ruleset(C) ->
    PartyID = cfg(party_id_big_merch, C),
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_due_date(10), make_cash(42000)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(Payment)]
    ) = hg_client_invoicing:get(InvoiceID, Client),
    ?payment_w_status(PaymentID, ?captured()) = Payment.

-spec processing_deadline_reached_test(config()) -> test_return().
processing_deadline_reached_test(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams0 = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    Deadline = hg_datetime:format_now(),
    PaymentParams = PaymentParams0#payproc_InvoicePaymentParams{processing_deadline = Deadline},
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_sessions_restarts(PaymentID, ?processed(), InvoiceID, Client, 0),
    [
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
    ] = next_changes(InvoiceID, 2, Client),
    ok = payproc_errors:match(
        'PaymentFailure',
        Failure,
        fun({authorization_failed, {processing_deadline_reached, _}}) -> ok end
    ).

-spec payment_success_empty_cvv(config()) -> test_return().
payment_success_empty_cvv(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(empty_cvv, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_success_additional_info(config()) -> test_return().
payment_success_additional_info(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(empty_cvv, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(Trx))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded())))
    ] = next_changes(InvoiceID, 2, Client),
    #domain_TransactionInfo{additional_info = AdditionalInfo} = Trx,
    AdditionalInfo = hg_ct_fixture:construct_dummy_additional_info(),
    ?payment_ev(PaymentID, ?payment_status_changed(?processed())) =
        next_change(InvoiceID, Client),

    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_has_optional_fields(config()) -> test_return().
payment_has_optional_fields(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    InvoicePayment = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ?payment_state(Payment) = InvoicePayment,
    ?payment_route(Route) = InvoicePayment,
    ?payment_cashflow(CashFlow) = InvoicePayment,
    ?payment_last_trx(TrxInfo) = InvoicePayment,
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    #domain_InvoicePayment{owner_id = PartyID, shop_id = ShopID} = Payment,
    false = Route =:= undefined,
    false = CashFlow =:= undefined,
    false = TrxInfo =:= undefined.

-spec payment_last_trx_correct(config()) -> _ | no_return().
payment_last_trx_correct(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = start_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(TrxInfo0))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?payment_last_trx(TrxInfo0) = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client).

-spec payment_w_misconfigured_routing_failed(config()) -> test_return().
payment_w_misconfigured_routing_failed(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))),
        ?payment_ev(PaymentID, ?risk_score_changed(_)),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
    ] = next_changes(InvoiceID, 3, Client),
    ?assertRouteNotFound(Failure, {unknown, _}, <<"{misconfiguration,{">>).

payment_w_misconfigured_routing_failed_fixture(_Revision) ->
    [
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(2),
            <<"Main">>,
            % NOTE
            % Both those delegates won't evaluate so the ruleset should compute to an empty
            % list of delegates.
            {delegates, [
                ?delegate(
                    <<"Inexistent merchant">>,
                    {condition, {party, #domain_PartyCondition{id = hg_utils:unique_id()}}},
                    ?ruleset(1)
                ),
                ?delegate(
                    <<"Common">>,
                    {constant, false},
                    ?ruleset(1)
                )
            ]}
        )
    ].

routes_ruleset_w_one_failing_route_fixture(Revision) ->
    #domain_Provider{abs_account = AbsAccount, accounts = Accounts, terms = Terms} =
        hg_domain:get(Revision, {provider, ?prv(1)}),
    [
        {provider, #domain_ProviderObject{
            ref = ?prv(999),
            data = #domain_Provider{
                name = <<"Duck Blocker">>,
                description = <<"No rubber ducks for you!">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
                        <<"override">> => <<"duckblocker">>
                    }
                },
                abs_account = AbsAccount,
                accounts = Accounts,
                terms = Terms
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(999),
            data = #domain_Terminal{
                name = <<"Not-Brominal">>,
                description = <<"Not-Brominal">>,
                provider_ref = ?prv(999)
            }
        }},
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(2),
            <<"Main with cascading one route">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(999))
            ]}
        )
    ].

routes_ruleset_w_different_failing_providers_fixture(Revision) ->
    #domain_Provider{abs_account = AbsAccount, accounts = Accounts, terms = Terms} =
        hg_domain:get(Revision, {provider, ?prv(1)}),
    [
        {provider, #domain_ProviderObject{
            ref = ?prv(999),
            data = #domain_Provider{
                name = <<"Duck Blocker">>,
                description = <<"No rubber ducks for you!">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
                        <<"override">> => <<"duckblocker">>
                    }
                },
                abs_account = AbsAccount,
                accounts = Accounts,
                terms = Terms
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(998),
            data = #domain_Provider{
                name = <<"Duck Blocker Younger">>,
                description = <<"No rubber ducks for you! Even smaller">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
                        <<"override">> => <<"duckblocker_younger">>
                    }
                },
                abs_account = AbsAccount,
                accounts = Accounts,
                terms = Terms
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(999),
            data = #domain_Terminal{
                name = <<"Not-Brominal">>,
                description = <<"Not-Brominal">>,
                provider_ref = ?prv(999)
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(998),
            data = #domain_Terminal{
                name = <<"Not-Brominal Younger">>,
                description = <<"Not-Brominal Younger">>,
                provider_ref = ?prv(998)
            }
        }},
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(2),
            <<"Main with cascading">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(999)),
                ?candidate({constant, true}, ?trm(998))
            ]}
        )
    ].

routes_ruleset_w_failing_provider_fixture(Revision) ->
    %% This setups a ruleset to resolve to two routes:
    %% - (not bro) One that leads to nasty provider that must fail;
    %%   see `proxy_provider_PaymentContext.options` with #{<<"override">> => <<"duckblocker">>},
    %% - (bro) And second one that successfully executes callbacks for happy "testcases"
    Brovider =
        #domain_Provider{abs_account = AbsAccount, accounts = Accounts, terms = Terms} =
        hg_domain:get(Revision, {provider, ?prv(1)}),
    Terms1 =
        Terms#domain_ProvisionTermSet{
            payments = Terms#domain_ProvisionTermSet.payments#domain_PaymentsProvisionTerms{
                turnover_limits =
                    {value, [
                        #domain_TurnoverLimit{
                            id = ?LIMIT_ID4,
                            upper_boundary = ?BIG_LIMIT_UPPER_BOUNDARY,
                            domain_revision = Revision
                        }
                    ]}
            }
        },
    [
        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = Brovider#domain_Provider{terms = Terms1}
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(999),
            data = #domain_Provider{
                name = <<"Duck Blocker">>,
                description = <<"No rubber ducks for you!">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"always_fail">> => <<"preauthorization_failed:card_blocked">>,
                        <<"override">> => <<"duckblocker">>
                    }
                },
                abs_account = AbsAccount,
                accounts = Accounts,
                terms = Terms1
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(999),
            data = #domain_Terminal{
                name = <<"Not-Brominal">>,
                description = <<"Not-Brominal">>,
                provider_ref = ?prv(999)
            }
        }},
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(2),
            <<"Main with cascading">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(999)),
                ?candidate({constant, true}, ?trm(1))
            ]}
        )
    ].

merchant_payments_service_terms_wo_attempt_limit(Revision) ->
    #domain_TermSetHierarchy{term_sets = [BaseTermSet0]} =
        hg_domain:get(Revision, {term_set_hierarchy, ?trms(1)}),
    #domain_TimedTermSet{terms = TermsSet} = BaseTermSet0,
    #domain_TermSet{payments = PaymentsTerms0} = TermsSet,
    PaymentsTerms1 = PaymentsTerms0#domain_PaymentsServiceTerms{
        attempt_limit = {value, #domain_AttemptLimit{attempts = 1}}
    },
    BaseTermSet1 = BaseTermSet0#domain_TimedTermSet{
        terms = TermsSet#domain_TermSet{payments = PaymentsTerms1}
    },
    lists:flatten([
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{term_sets = [BaseTermSet1]}
        }},
        routes_ruleset_w_failing_provider_fixture(Revision)
    ]).

patch_limit_config_w_invalid_currency(Revision) ->
    NewRevision = hg_domain:update({limit_config, hg_limiter_helper:mk_config_object(?LIMIT_ID, <<"KEK">>)}),
    [
        change_terms_limit_config_version(Revision, NewRevision)
    ].

patch_limit_config_for_withdrawal(Revision) ->
    NewRevision = hg_domain:update(
        {limit_config,
            hg_limiter_helper:mk_config_object(?LIMIT_ID, <<"RUB">>, hg_limiter_helper:mk_context_type(withdrawal))}
    ),
    [
        change_terms_limit_config_version(Revision, NewRevision)
    ].

patch_with_unsupported_payment_tool(Revision) ->
    NewRevision = hg_domain:update(
        {limit_config,
            hg_limiter_helper:mk_config_object(
                ?LIMIT_ID,
                <<"RUB">>,
                hg_limiter_helper:mk_context_type(payment),
                hg_limiter_helper:mk_scopes([shop, payment_tool])
            )}
    ),
    [
        change_provider_payments_provision_terms(?prv(5), Revision, fun(PaymentsProvisionTerms) ->
            PaymentsProvisionTerms#domain_PaymentsProvisionTerms{
                turnover_limits =
                    {value, [
                        #domain_TurnoverLimit{
                            id = ?LIMIT_ID,
                            upper_boundary = ?LIMIT_UPPER_BOUNDARY,
                            domain_revision = NewRevision
                        }
                    ]},
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>))
                        ])}
            }
        end)
    ].

patch_providers_limits_to_fail_and_overflow(Revision) ->
    %% 1. Must have two routes to different providers.
    %% 2. Each provider must have different turnover limit.
    %% 3. First of those turnover limits must fail on hold operation with business error.
    %% 4. Second must get rejected due limit overflow.
    NewRevision = hg_domain:update([
        {limit_config,
            hg_limiter_helper:mk_config_object(?LIMIT_ID, <<"RUB">>, hg_limiter_helper:mk_context_type(withdrawal))}
    ]),
    [
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(4),
            <<"SubMain">>,
            {candidates, [
                %% Provider = ?prv(5)
                ?candidate({constant, true}, ?trm(12)),
                %% Provider = ?prv(6)
                ?candidate({constant, true}, ?trm(13))
            ]}
        ),
        change_terms_limit_config_version(Revision, ?prv(5), [
            #domain_TurnoverLimit{
                id = ?LIMIT_ID,
                upper_boundary = ?LIMIT_UPPER_BOUNDARY,
                domain_revision = NewRevision
            }
        ]),
        change_terms_limit_config_version(Revision, ?prv(6), [
            #domain_TurnoverLimit{
                id = ?LIMIT_ID2,
                %% Every op will overflow!
                upper_boundary = 0,
                domain_revision = NewRevision
            }
        ])
    ].

change_terms_limit_config_version(Revision, LimitConfigRevision) ->
    change_terms_limit_config_version(Revision, ?prv(5), [
        #domain_TurnoverLimit{
            id = ?LIMIT_ID,
            upper_boundary = ?LIMIT_UPPER_BOUNDARY,
            domain_revision = LimitConfigRevision
        }
    ]).

change_terms_limit_config_version(Revision, ProviderRef, TurnoverLimits) ->
    change_provider_payments_provision_terms(ProviderRef, Revision, fun(PaymentsProvisionTerms) ->
        PaymentsProvisionTerms#domain_PaymentsProvisionTerms{turnover_limits = {value, TurnoverLimits}}
    end).

change_provider_payments_provision_terms(ProviderID, Revision, Changer) when is_function(Changer, 1) ->
    Provider = #domain_Provider{terms = Terms} = hg_domain:get(Revision, {provider, ProviderID}),
    Terms1 =
        Terms#domain_ProvisionTermSet{
            payments = Changer(Terms#domain_ProvisionTermSet.payments)
        },
    {provider, #domain_ProviderObject{
        ref = ProviderID,
        data = Provider#domain_Provider{terms = Terms1}
    }}.

-spec payment_capture_failed(config()) -> test_return().
payment_capture_failed(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    Cost = ?cash(Amount, <<"RUB">>),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    PaymentParams = make_scenario_payment_params([good, fail], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(_)),
        ?payment_ev(PaymentID, ?session_ev(?captured(), ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),
    timeout = next_change(InvoiceID, 5000, Client),
    ?assertException(
        error,
        {{woody_error, _}, _},
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client)
    ),
    PaymentID = repair_failed_capture(InvoiceID, PaymentID, ?timeout_reason(), Cost, Client).

-spec payment_capture_retries_exceeded(config()) -> test_return().
payment_capture_retries_exceeded(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    Cost = ?cash(Amount, <<"RUB">>),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    PaymentParams = make_scenario_payment_params([good, temp, temp, temp, temp], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Reason = ?timeout_reason(),
    Target = ?captured(Reason, Cost),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cost, _, _Allocation)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost), ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),
    PaymentID = await_sessions_restarts(PaymentID, Target, InvoiceID, Client, 3),
    timeout = next_change(InvoiceID, 5000, Client),
    ?assertException(
        error,
        {{woody_error, _}, _},
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client)
    ),
    PaymentID = repair_failed_capture(InvoiceID, PaymentID, Reason, Cost, Client).

-spec payment_partial_capture_success(config()) -> test_return().
payment_partial_capture_success(C) ->
    InitialCost = 1000 * 100,
    PartialCost = 700 * 100,
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, Context} = PartyPair = cfg(party_client, C),
    {ok, Shop} = party_client_thrift:get_shop(PartyID, cfg(shop_id, C), PartyClient, Context),
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(1), PartyPair),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(100), InitialCost, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    % start payment
    ?payment_state(?payment(PaymentID)) =
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_started(InvoiceID, PaymentID, Client),
    {CF1, _} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    % do a partial capture
    Cash = ?cash(PartialCost, <<"RUB">>),
    Reason = <<"ok">>,
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client),
    PaymentID = await_payment_partial_capture(InvoiceID, PaymentID, Reason, Cash, Client),
    % let's check results
    InvoiceState = hg_client_invoicing:get(InvoiceID, Client),
    ?invoice_state(Invoice, [PaymentState]) = InvoiceState,
    ?assertMatch(?invoice_w_status(?invoice_paid()), Invoice),
    ?assertMatch(?payment_state(?payment_w_status(PaymentID, ?captured(Reason, Cash))), PaymentState),
    ?payment_cashflow(CF2) = PaymentState,
    ?assertNotEqual(undefined, CF2),
    ?assertNotEqual(CF1, CF2).

-spec payment_error_in_cancel_session_does_not_cause_payment_failure(config()) -> test_return().
payment_error_in_cancel_session_does_not_cause_payment_failure(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, Context} = PartyPair = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(PartyID, ?cat(2), <<"RUB">>, ?tmpl(2), ?pinst(2), PartyPair),
    {ok, Party} = party_client_thrift:get(PartyID, PartyClient, Context),
    #domain_Shop{account = Account} = maps:get(ShopID, Party#domain_Party.shops),
    SettlementID = Account#domain_ShopAccount.settlement,
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(1000), 42000, C),
    PaymentParams = make_scenario_payment_params([good, fail, good], {hold, capture}, ?pmt_sys(<<"visa-ref">>)),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    ?assertMatch(#{max_available_amount := 40110}, hg_accounting:get_balance(SettlementID)),
    ok = hg_client_invoicing:cancel_payment(InvoiceID, PaymentID, <<"cancel">>, Client),
    ?payment_ev(PaymentID, ?session_ev(?cancelled_with_reason(Reason), ?session_started())) =
        next_change(InvoiceID, Client),
    timeout = next_change(InvoiceID, Client),
    ?assertMatch(#{min_available_amount := 0, max_available_amount := 40110}, hg_accounting:get_balance(SettlementID)),
    ?assertException(
        error,
        {{woody_error, _}, _},
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client)
    ),
    PaymentID = repair_failed_cancel(InvoiceID, PaymentID, Reason, Client).

-spec payment_error_in_capture_session_does_not_cause_payment_failure(config()) -> test_return().
payment_error_in_capture_session_does_not_cause_payment_failure(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, Context} = PartyPair = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(PartyID, ?cat(2), <<"RUB">>, ?tmpl(2), ?pinst(2), PartyPair),
    Amount = 42000,
    Cost = ?cash(Amount, <<"RUB">>),
    {ok, Party} = party_client_thrift:get(PartyID, PartyClient, Context),
    #domain_Shop{account = Account} = maps:get(ShopID, Party#domain_Party.shops),
    SettlementID = Account#domain_ShopAccount.settlement,
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(1000), Amount, C),
    PaymentParams = make_scenario_payment_params([good, fail, good], {hold, cancel}, ?pmt_sys(<<"visa-ref">>)),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    ?assertMatch(#{min_available_amount := 0, max_available_amount := 40110}, hg_accounting:get_balance(SettlementID)),
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"capture">>, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cost, _, _Allocation)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost), ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),
    timeout = next_change(InvoiceID, Client),
    ?assertMatch(#{min_available_amount := 0, max_available_amount := 40110}, hg_accounting:get_balance(SettlementID)),
    ?assertException(
        error,
        {{woody_error, _}, _},
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client)
    ),
    PaymentID = repair_failed_capture(InvoiceID, PaymentID, Reason, Cost, Client).

repair_failed_capture(InvoiceID, PaymentID, Reason, Cost, Client) ->
    Target = ?captured(Reason, Cost),
    Changes = [
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_finished(?session_succeeded())))
    ],
    ok = repair_invoice(InvoiceID, Changes, Client),
    PaymentID = await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client).

repair_failed_cancel(InvoiceID, PaymentID, Reason, Client) ->
    Target = ?cancelled_with_reason(Reason),
    Changes = [
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_finished(?session_succeeded())))
    ],
    ok = repair_invoice(InvoiceID, Changes, Client),
    [
        ?payment_ev(PaymentID, ?session_ev(?cancelled_with_reason(Reason), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?cancelled_with_reason(Reason)))
    ] = next_changes(InvoiceID, 2, Client),
    PaymentID.

-spec payment_w_terminal_w_payment_service_success(config()) -> _ | no_return().
payment_w_terminal_w_payment_service_success(C) ->
    Client = cfg(client, C),
    PaymentService = ?pmt_srv(<<"euroset-ref">>),
    #domain_PaymentService{
        name = PmtSrvName,
        brand_name = PmtSrvBrandName
    } = hg_domain:get({payment_service, PaymentService}),
    InvoiceID = start_invoice(<<"rubberruble">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(terminal, PaymentService),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    %% simulate user interaction
    {URL, GoodForm} = get_post_request(UserInteraction),
    BadForm = #{<<"tag">> => <<"666">>},
    _ = assert_invalid_post_request({URL, BadForm}),
    _ = assert_success_post_request({URL, GoodForm}),
    ok = await_payment_process_interaction_completion(InvoiceID, PaymentID, UserInteraction, Client),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [PaymentSt = ?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client),
    ?assertMatch(
        ?payment_last_trx(
            #domain_TransactionInfo{
                extra = #{
                    <<"payment.payment_service.name">> := PmtSrvName,
                    <<"payment.payment_service.brand_name">> := PmtSrvBrandName
                }
            }
        ),
        PaymentSt
    ).

-spec payment_w_crypto_currency_success(config()) -> _ | no_return().
payment_w_crypto_currency_success(C) ->
    Client = cfg(client, C),
    PayCash = 2000,
    InvoiceID = start_invoice(<<"cryptoduck">>, make_due_date(10), PayCash, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    ?payment_state(#domain_InvoicePayment{
        id = PaymentID,
        owner_id = PartyID,
        shop_id = ShopID
    }) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    {CF, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    CFContext = construct_ta_context(PartyID, ShopID, Route),
    ?cash(PayCash, <<"RUB">>) = get_cashflow_volume({provider, settlement}, {merchant, settlement}, CF, CFContext),
    ?cash(40, <<"RUB">>) = get_cashflow_volume({system, settlement}, {provider, settlement}, CF, CFContext),
    ?cash(90, <<"RUB">>) = get_cashflow_volume({merchant, settlement}, {system, settlement}, CF, CFContext).

-spec payment_bank_card_category_condition(config()) -> _ | no_return().
payment_bank_card_category_condition(C) ->
    Client = cfg(client, C),
    PayCash = 2000,
    InvoiceID = start_invoice(<<"cryptoduck">>, make_due_date(10), PayCash, C),
    {{bank_card, BC}, Session} = hg_dummy_provider:make_payment_tool(empty_cvv, ?pmt_sys(<<"visa-ref">>)),
    BankCard = BC#domain_BankCard{
        category = <<"CORPORATE CARD">>
    },
    PaymentTool = {bank_card, BankCard},
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    {CF, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    CFContext = construct_ta_context(cfg(party_id, C), cfg(shop_id, C), Route),
    ?cash(200, <<"RUB">>) = get_cashflow_volume({merchant, settlement}, {system, settlement}, CF, CFContext).

-spec payment_w_mobile_commerce(config()) -> _ | no_return().
payment_w_mobile_commerce(C) ->
    payment_w_mobile_commerce(C, success).

-spec payment_suspend_timeout_failure(config()) -> _ | no_return().
payment_suspend_timeout_failure(C) ->
    payment_w_mobile_commerce(C, failure).

payment_w_mobile_commerce(C, Expectation) ->
    Client = cfg(client, C),
    PayCash = 1001,
    InvoiceID = start_invoice(<<"oatmeal">>, make_due_date(10), PayCash, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool({mobile_commerce, Expectation}, ?mob(<<"mts-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    _ = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    case Expectation of
        success ->
            [
                ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
                ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
            ] =
                next_changes(InvoiceID, 2, Client);
        failure ->
            [
                ?payment_ev(
                    PaymentID,
                    ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))
                ),
                ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
                ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
            ] =
                next_changes(InvoiceID, 3, Client)
    end.

-spec payment_w_wallet_success(config()) -> _ | no_return().
payment_w_wallet_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"bubbleblob">>, make_due_date(10), 42000, C),
    PaymentParams = make_wallet_payment_params(?pmt_srv(<<"qiwi-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_w_customer_success(config()) -> test_return().
payment_w_customer_success(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(60), 42000, C),
    CustomerID = make_customer_w_rec_tool(PartyID, ShopID, cfg(customer_client, C), ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_customer_payment_params(CustomerID),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_w_another_shop_customer(config()) -> test_return().
payment_w_another_shop_customer(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    PartyClient = cfg(party_client, C),
    AnotherShopID = hg_ct_helper:create_battle_ready_shop(
        PartyID,
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(AnotherShopID, <<"rubberduck">>, make_due_date(60), 42000, C),
    CustomerID = make_customer_w_rec_tool(PartyID, ShopID, cfg(customer_client, C), ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_customer_payment_params(CustomerID),
    {exception, #base_InvalidRequest{}} = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client).

-spec payment_w_another_party_customer(config()) -> test_return().
payment_w_another_party_customer(C) ->
    Client = cfg(client, C),
    AnotherPartyID = cfg(another_party_id, C),
    ShopID = cfg(shop_id, C),
    AnotherShopID = cfg(another_shop_id, C),
    CustomerID = make_customer_w_rec_tool(
        AnotherPartyID, AnotherShopID, cfg(another_customer_client, C), ?pmt_sys(<<"visa-ref">>)
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(60), 42000, C),
    PaymentParams = make_customer_payment_params(CustomerID),
    {exception, #base_InvalidRequest{}} = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client).

-spec payment_w_deleted_customer(config()) -> test_return().
payment_w_deleted_customer(C) ->
    Client = cfg(client, C),
    CustomerClient = cfg(customer_client, C),
    PartyID = cfg(party_id, C),
    ShopID = cfg(shop_id, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(60), 42000, C),
    CustomerID = make_customer_w_rec_tool(PartyID, ShopID, CustomerClient, ?pmt_sys(<<"visa-ref">>)),
    ok = hg_client_customer:delete(CustomerID, CustomerClient),
    PaymentParams = make_customer_payment_params(CustomerID),
    {exception, #base_InvalidRequest{}} = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client).

-spec payment_success_on_second_try(config()) -> test_return().
payment_success_on_second_try(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberdick">>, make_due_date(20), 42000, C),
    PaymentParams = make_tds_payment_params(instant, ?pmt_sys(<<"visa-ref">>)),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    %% simulate user interaction
    {URL, GoodForm} = get_post_request(UserInteraction),
    BadForm = #{<<"tag">> => <<"666">>},
    _ = assert_invalid_post_request({URL, BadForm}),
    %% make noop callback call
    _ = assert_success_post_request({URL, hg_dummy_provider:construct_silent_callback(GoodForm)}),
    %% ensure that suspend is still holding up
    _ = assert_success_post_request({URL, GoodForm}),
    %% ensure that callback is now invalid̋
    _ = assert_invalid_post_request({URL, GoodForm}),
    ok = await_payment_process_interaction_completion(InvoiceID, PaymentID, UserInteraction, Client),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec payment_fail_after_silent_callback(config()) -> _ | no_return().
payment_fail_after_silent_callback(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberdick">>, make_due_date(20), 42000, C),
    PaymentID = start_payment(InvoiceID, make_tds_payment_params(instant, ?pmt_sys(<<"visa-ref">>)), Client),
    UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    {URL, Form} = get_post_request(UserInteraction),
    _ = assert_success_post_request({URL, hg_dummy_provider:construct_silent_callback(Form)}),
    PaymentID = await_payment_process_timeout(InvoiceID, PaymentID, Client).

-spec payments_w_bank_card_issuer_conditions(config()) -> test_return().
payments_w_bank_card_issuer_conditions(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(1),
        <<"RUB">>,
        ?tmpl(4),
        ?pinst(1),
        PartyClient
    ),
    %kaz success
    FirstInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1000, C),
    {{bank_card, BankCard}, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    KazBankCard = BankCard#domain_BankCard{
        issuer_country = kaz,
        metadata = #{<<?MODULE_STRING>> => {obj, #{{str, <<"vsn">>} => {i, 42}}}}
    },
    KazPaymentParams = make_payment_params({bank_card, KazBankCard}, Session, instant),
    _FirstPayment = execute_payment(FirstInvoice, KazPaymentParams, Client),
    %kaz fail
    SecondInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1001, C),
    ?assertEqual(
        {exception, #base_InvalidRequest{errors = [<<"Invalid amount, more than allowed maximum">>]}},
        hg_client_invoicing:start_payment(SecondInvoice, KazPaymentParams, Client)
    ),
    %rus success
    ThirdInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1001, C),
    {{bank_card, BankCard1}, Session1} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    RusBankCard = BankCard1#domain_BankCard{
        issuer_country = rus,
        metadata = #{<<?MODULE_STRING>> => {obj, #{{str, <<"vsn">>} => {i, 42}}}}
    },
    RusPaymentParams = make_payment_params({bank_card, RusBankCard}, Session1, instant),
    _SecondPayment = execute_payment(ThirdInvoice, RusPaymentParams, Client),
    %fail with undefined issuer_country
    FourthInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1001, C),
    {UndefBankCard, Session2} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    UndefPaymentParams = make_payment_params(UndefBankCard, Session2, instant),
    %fix me
    ?assertException(
        error,
        {{woody_error, _}, _},
        hg_client_invoicing:start_payment(FourthInvoice, UndefPaymentParams, Client)
    ).

-spec payments_w_bank_conditions(config()) -> test_return().
payments_w_bank_conditions(C) ->
    PmtSys = ?pmt_sys(<<"visa-ref">>),
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(1),
        <<"RUB">>,
        ?tmpl(4),
        ?pinst(1),
        PartyClient
    ),
    %bank 1 success
    FirstInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1000, C),
    {{bank_card, BankCard}, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    TestBankCard = BankCard#domain_BankCard{
        bank_name = <<"TEST BANK">>
    },
    TestPaymentParams = make_payment_params({bank_card, TestBankCard}, Session, instant),
    _FirstPayment = execute_payment(FirstInvoice, TestPaymentParams, Client),
    %bank 1 fail
    SecondInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1001, C),
    ?assertEqual(
        {exception, #base_InvalidRequest{errors = [<<"Invalid amount, more than allowed maximum">>]}},
        hg_client_invoicing:start_payment(SecondInvoice, TestPaymentParams, Client)
    ),
    %bank 1 /w different wildcard fail
    ThirdInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1001, C),
    {{bank_card, BankCard1}, Session1} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    WildBankCard = BankCard1#domain_BankCard{
        bank_name = <<"TESTBANK">>
    },
    WildPaymentParams = make_payment_params({bank_card, WildBankCard}, Session1, instant),
    ?assertEqual(
        {exception, #base_InvalidRequest{errors = [<<"Invalid amount, more than allowed maximum">>]}},
        hg_client_invoicing:start_payment(ThirdInvoice, WildPaymentParams, Client)
    ),
    %some other bank success
    FourthInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 10000, C),
    {{bank_card, BankCard2}, Session2} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    OthrBankCard = BankCard2#domain_BankCard{
        bank_name = <<"SOME OTHER BANK">>
    },
    OthrPaymentParams = make_payment_params({bank_card, OthrBankCard}, Session2, instant),
    _ThirdPayment = execute_payment(FourthInvoice, OthrPaymentParams, Client),
    %test fallback to bins with undefined bank_name
    FifthInvoice = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 1001, C),
    {{bank_card, BankCard3}, Session3} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    FallbackBankCard = BankCard3#domain_BankCard{
        bin = <<"42424242">>
    },
    FallbackPaymentParams = make_payment_params({bank_card, FallbackBankCard}, Session3, instant),
    ?assertEqual(
        {exception, #base_InvalidRequest{errors = [<<"Invalid amount, more than allowed maximum">>]}},
        hg_client_invoicing:start_payment(FifthInvoice, FallbackPaymentParams, Client)
    ).

-spec invoice_success_on_third_payment(config()) -> test_return().
invoice_success_on_third_payment(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberdock">>, make_due_date(60), 42000, C),
    PaymentParams = make_tds_payment_params(instant, ?pmt_sys(<<"visa-ref">>)),
    PaymentID1 = start_payment(InvoiceID, PaymentParams, Client),
    %% wait for payment timeout and start new one after
    _ = await_payment_process_interaction(InvoiceID, PaymentID1, Client),
    PaymentID1 = await_payment_process_timeout(InvoiceID, PaymentID1, Client),
    PaymentID2 = start_payment(InvoiceID, PaymentParams, Client),
    %% wait for payment timeout and start new one after
    _ = await_payment_process_interaction(InvoiceID, PaymentID2, Client),
    PaymentID2 = await_payment_process_timeout(InvoiceID, PaymentID2, Client),
    PaymentID3 = start_payment(InvoiceID, PaymentParams, Client),
    UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID3, Client),
    GoodPost = get_post_request(UserInteraction),
    %% simulate user interaction FTW!
    _ = assert_success_post_request(GoodPost),
    ok = await_payment_process_interaction_completion(InvoiceID, PaymentID3, UserInteraction, Client),
    PaymentID3 = await_payment_process_finish(InvoiceID, PaymentID3, Client),
    PaymentID3 = await_payment_capture(InvoiceID, PaymentID3, Client).

%% @TODO modify this test by failures of inspector in case of wrong terminal choice
-spec payment_risk_score_check(config()) -> test_return().
payment_risk_score_check(C) ->
    Client = cfg(client, C),
    % Invoice w/ cost < 500000
    InvoiceID1 = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID1)) = hg_client_invoicing:start_payment(InvoiceID1, PaymentParams, Client),
    ?payment_ev(PaymentID1, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID1, Client),
    % low risk score...
    % ...covered with high risk coverage terminal
    _ = await_payment_cash_flow(low, ?route(?prv(1), ?trm(1)), InvoiceID1, PaymentID1, Client),
    ?payment_ev(PaymentID1, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID1, Client),
    PaymentID1 = await_payment_process_finish(InvoiceID1, PaymentID1, Client),
    PaymentID1 = await_payment_capture(InvoiceID1, PaymentID1, Client),
    % Invoice w/ 500000 < cost < 100000000
    InvoiceID2 = start_invoice(<<"rubberbucks">>, make_due_date(10), 31337000, C),
    ?payment_state(?payment(PaymentID2)) = hg_client_invoicing:start_payment(InvoiceID2, PaymentParams, Client),
    ?payment_ev(PaymentID2, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID2, Client),
    % high risk score...
    % ...covered with the same terminal
    _ = await_payment_cash_flow(high, ?route(?prv(1), ?trm(1)), InvoiceID2, PaymentID2, Client),
    ?payment_ev(PaymentID2, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID2, Client),
    PaymentID2 = await_payment_process_finish(InvoiceID2, PaymentID2, Client),
    PaymentID2 = await_payment_capture(InvoiceID2, PaymentID2, Client),
    % Invoice w/ 100000000 =< cost
    InvoiceID3 = start_invoice(<<"rubbersocks">>, make_due_date(10), 100000000, C),
    ?payment_state(?payment(PaymentID3)) = hg_client_invoicing:start_payment(InvoiceID3, PaymentParams, Client),
    [
        ?payment_ev(PaymentID3, ?payment_started(?payment_w_status(?pending()))),
        % fatal risk score is not going to be covered
        ?payment_ev(PaymentID3, ?risk_score_changed(fatal)),
        ?payment_ev(PaymentID3, ?payment_status_changed(?failed({failure, Failure})))
    ] = next_changes(InvoiceID3, 3, Client),
    ok = payproc_errors:match(
        'PaymentFailure',
        Failure,
        fun({no_route_found, _}) -> ok end
    ).

-spec payment_risk_score_check_fail(config()) -> test_return().
payment_risk_score_check_fail(C) ->
    payment_risk_score_check(4, C, ?pmt_sys(<<"visa-ref">>)).

-spec payment_risk_score_check_timeout(config()) -> test_return().
payment_risk_score_check_timeout(C) ->
    payment_risk_score_check(5, C, ?pmt_sys(<<"visa-ref">>)).

-spec party_revision_check(config()) -> test_return().
party_revision_check(C) ->
    PartyID = <<"RevChecker2">>,
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    Client = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),
    ShopID = hg_ct_helper:create_party_and_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    {InvoiceRev, InvoiceID} = invoice_create_and_get_revision(PartyID, Client, ShopID),

    party_revision_increment(PartyID, ShopID, PartyClient),

    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    ?payment_state(?payment(PaymentID, PaymentRev)) = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    PaymentRev = InvoiceRev + 1,

    party_revision_increment(PartyID, ShopID, PartyClient),

    AdjustmentRev = make_payment_adjustment_and_get_revision(InvoiceID, PaymentID, Client),
    AdjustmentRev = PaymentRev + 1,

    party_revision_increment(PartyID, ShopID, PartyClient),

    % add some cash to make smooth refund after
    InvoiceParams2 = make_invoice_params(PartyID, ShopID, <<"rubbermoss">>, make_due_date(10), make_cash(200000)),
    InvoiceID2 = create_invoice(InvoiceParams2, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID2, Client),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),

    RefundRev = make_payment_refund_and_get_revision(InvoiceID, PaymentID, Client),
    RefundRev = AdjustmentRev + 1.

party_revision_increment(PartyID, ShopID, {Client, Context} = PartyPair) ->
    {ok, Shop} = party_client_thrift:get_shop(PartyID, ShopID, Client, Context),
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(1), PartyPair).

-spec invalid_payment_adjustment(config()) -> test_return().
invalid_payment_adjustment(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 100000, C),
    %% start a smoker's payment
    PaymentParams = make_tds_payment_params(instant, ?pmt_sys(<<"visa-ref">>)),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    %% no way to create adjustment for a payment not yet finished
    ?invalid_payment_status(?pending()) =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, make_adjustment_params(), Client),
    _UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_process_timeout(InvoiceID, PaymentID, Client),
    %% no way to create adjustment for a failed payment
    ?invalid_payment_status(?failed(_)) =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, make_adjustment_params(), Client).

-spec payment_adjustment_success(config()) -> test_return().
payment_adjustment_success(C) ->
    %% old cf :
    %% merch - 4500   -> syst
    %% prov  - 100000 -> merch
    %% syst  - 2100   -> prov
    %%
    %% new cf :
    %% merch - 4500   -> syst
    %% prov  - 100000 -> merch
    %% syst  - 1600   -> prov
    %% syst  - 20     -> ext
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 100000, C),
    %% start a healthy man's payment
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    {CF1, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    CFContext = construct_ta_context(cfg(party_id, C), cfg(shop_id, C), Route),
    PrvAccount1 = get_deprecated_cashflow_account({provider, settlement}, CF1, CFContext),
    SysAccount1 = get_deprecated_cashflow_account({system, settlement}, CF1, CFContext),
    MrcAccount1 = get_deprecated_cashflow_account({merchant, settlement}, CF1, CFContext),
    %% update terminal cashflow
    ok = update_payment_terms_cashflow(?prv(100), get_payment_adjustment_provider_cashflow(actual)),

    %% make an adjustment
    Params = make_adjustment_params(Reason = <<"imdrunk">>),
    ?adjustment(AdjustmentID, ?adjustment_pending()) =
        Adjustment =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, Params, Client),
    Adjustment =
        #domain_InvoicePaymentAdjustment{id = AdjustmentID, reason = Reason} =
        hg_client_invoicing:get_payment_adjustment(InvoiceID, PaymentID, AdjustmentID, Client),
    ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_created(Adjustment))) =
        next_change(InvoiceID, Client),
    %% no way to create another one yet
    ?invalid_adjustment_pending(AdjustmentID) =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, make_adjustment_params(), Client),
    [
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_processed()))),
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_captured(_))))
    ] = next_changes(InvoiceID, 2, Client),
    %% verify that cash deposited correctly everywhere
    #domain_InvoicePaymentAdjustment{new_cash_flow = DCF2} = Adjustment,
    PrvAccount2 = get_deprecated_cashflow_account({provider, settlement}, DCF2, CFContext),
    SysAccount2 = get_deprecated_cashflow_account({system, settlement}, DCF2, CFContext),
    MrcAccount2 = get_deprecated_cashflow_account({merchant, settlement}, DCF2, CFContext),
    0 = MrcDiff = maps:get(own_amount, MrcAccount2) - maps:get(own_amount, MrcAccount1),
    -500 = PrvDiff = maps:get(own_amount, PrvAccount2) - maps:get(own_amount, PrvAccount1),
    SysDiff = MrcDiff - PrvDiff - 20,
    SysDiff = maps:get(own_amount, SysAccount2) - maps:get(own_amount, SysAccount1).

-spec payment_adjustment_refunded_success(config()) -> test_return().
payment_adjustment_refunded_success(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_shop(cfg(party_id, C), ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 10000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    CashFlow = get_payment_cashflow_mapped(InvoiceID, PaymentID, Client),
    _RefundID = execute_payment_refund(InvoiceID, PaymentID, make_refund_params(1000, <<"RUB">>), Client),
    ok = update_payment_terms_cashflow(?prv(100), get_payment_adjustment_provider_cashflow(actual)),
    _AdjustmentID = execute_payment_adjustment(InvoiceID, PaymentID, make_adjustment_params(), Client),
    NewCashFlow = get_payment_cashflow_mapped(InvoiceID, PaymentID, Client),
    ?assertEqual(
        [
            % ?merchant_to_system_share_1 ?share(45, 1000, operation_amount)
            {{merchant, settlement}, {system, settlement}, 450},
            % ?share(1, 1, operation_amount)
            {{provider, settlement}, {merchant, settlement}, 10000},
            % ?system_to_provider_share_initial ?share(21, 1000, operation_amount)
            {{system, settlement}, {provider, settlement}, 210}
        ],
        CashFlow
    ),
    ?assertEqual(
        [
            % ?merchant_to_system_share_1 ?share(45, 1000, operation_amount)
            {{merchant, settlement}, {system, settlement}, 450},
            % ?share(1, 1, operation_amount)
            {{provider, settlement}, {merchant, settlement}, 10000},
            % ?system_to_provider_share_actual  ?share(16, 1000, operation_amount)
            {{system, settlement}, {provider, settlement}, 160},
            % ?system_to_external_fixed  ?fixed(20, <<"RUB">>)
            {{system, settlement}, {external, outcome}, 20}
        ],
        NewCashFlow
    ).

-spec payment_adjustment_chargeback_success(config()) -> test_return().
payment_adjustment_chargeback_success(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, Context} = PartyPair = cfg(party_client, C),
    % Контракт на основе шаблона ?tmpl(1)
    ShopID = hg_ct_helper:create_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyPair),
    {ok, Shop} = party_client_thrift:get_shop(PartyID, ShopID, PartyClient, Context),
    % Корректировка контракта на основе шаблона ?tmpl(3) в котором разрешены возвраты
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(3), PartyPair),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 10000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    CashFlow = get_payment_cashflow_mapped(InvoiceID, PaymentID, Client),
    Params = make_chargeback_params(?cash(10000, <<"RUB">>)),
    _ChargebackID = execute_payment_chargeback(InvoiceID, PaymentID, Params, Client),
    ok = update_payment_terms_cashflow(?prv(100), get_payment_adjustment_provider_cashflow(actual)),
    _AdjustmentID = execute_payment_adjustment(InvoiceID, PaymentID, make_adjustment_params(), Client),
    NewCashFlow = get_payment_cashflow_mapped(InvoiceID, PaymentID, Client),
    ?assertEqual(
        [
            % ?merchant_to_system_share_3 ?share(40, 1000, operation_amount)
            {{merchant, settlement}, {system, settlement}, 400},
            % ?share(1, 1, operation_amount)
            {{provider, settlement}, {merchant, settlement}, 10000},
            % ?system_to_provider_share_initial  ?share(21, 1000, operation_amount)
            {{system, settlement}, {provider, settlement}, 210}
        ],
        CashFlow
    ),
    ?assertEqual(
        [
            % ?merchant_to_system_share_3 ?share(40, 1000, operation_amount)
            {{merchant, settlement}, {system, settlement}, 400},
            % ?share(1, 1, operation_amount)
            {{provider, settlement}, {merchant, settlement}, 10000},
            % ?system_to_provider_share_actual  ?share(16, 1000, operation_amount)
            {{system, settlement}, {provider, settlement}, 160},
            % ?system_to_external_fixed  ?fixed(20, <<"RUB">>)
            {{system, settlement}, {external, outcome}, 20}
        ],
        NewCashFlow
    ).

-spec payment_adjustment_captured_partial(config()) -> test_return().
payment_adjustment_captured_partial(C) ->
    InitialCost = 1000 * 100,
    PartialCost = 700 * 100,
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, PartyCtx} = PartyPair = cfg(party_client, C),
    {ok, Shop} = party_client_thrift:get_shop(PartyID, cfg(shop_id, C), PartyClient, PartyCtx),
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(1), PartyPair),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), InitialCost, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    % start payment
    ?payment_state(?payment(PaymentID)) =
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_started(InvoiceID, PaymentID, Client),
    {CF1, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    % do a partial capture
    Cash = ?cash(PartialCost, <<"RUB">>),
    Reason = <<"ok">>,
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client),
    PaymentID = await_payment_partial_capture(InvoiceID, PaymentID, Reason, Cash, Client),
    % get balances
    CFContext = construct_ta_context(cfg(party_id, C), cfg(shop_id, C), Route),
    PrvAccount1 = get_deprecated_cashflow_account({provider, settlement}, CF1, CFContext),
    SysAccount1 = get_deprecated_cashflow_account({system, settlement}, CF1, CFContext),
    MrcAccount1 = get_deprecated_cashflow_account({merchant, settlement}, CF1, CFContext),
    % update terminal cashflow
    ok = update_payment_terms_cashflow(?prv(100), get_payment_adjustment_provider_cashflow(actual)),
    % update merchant fees
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(3), PartyPair),
    % make an adjustment
    Params = make_adjustment_params(AdjReason = <<"because punk you that's why">>),
    AdjustmentID = execute_payment_adjustment(InvoiceID, PaymentID, Params, Client),
    #domain_InvoicePaymentAdjustment{new_cash_flow = CF2} =
        ?adjustment_reason(AdjReason) =
        hg_client_invoicing:get_payment_adjustment(InvoiceID, PaymentID, AdjustmentID, Client),
    PrvAccount2 = get_deprecated_cashflow_account({provider, settlement}, CF2, CFContext),
    SysAccount2 = get_deprecated_cashflow_account({system, settlement}, CF2, CFContext),
    MrcAccount2 = get_deprecated_cashflow_account({merchant, settlement}, CF2, CFContext),
    Context = #{operation_amount => Cash},
    #domain_Cash{amount = MrcAmount1} = hg_cashflow:compute_volume(?merchant_to_system_share_1, Context),
    #domain_Cash{amount = MrcAmount2} = hg_cashflow:compute_volume(?merchant_to_system_share_3, Context),
    % fees after adjustment are less than before, so own amount is greater
    MrcDiff = MrcAmount1 - MrcAmount2,
    ?assertEqual(MrcDiff, maps:get(own_amount, MrcAccount2) - maps:get(own_amount, MrcAccount1)),
    #domain_Cash{amount = PrvAmount1} = hg_cashflow:compute_volume(?system_to_provider_share_initial, Context),
    #domain_Cash{amount = PrvAmount2} = hg_cashflow:compute_volume(?system_to_provider_share_actual, Context),
    % inversed in opposite of merchant fees
    PrvDiff = PrvAmount2 - PrvAmount1,
    ?assertEqual(PrvDiff, maps:get(own_amount, PrvAccount2) - maps:get(own_amount, PrvAccount1)),
    #domain_Cash{amount = SysAmount2} = hg_cashflow:compute_volume(?system_to_external_fixed, Context),
    SysDiff = MrcDiff + PrvDiff - SysAmount2,
    ?assertEqual(SysDiff, maps:get(own_amount, SysAccount2) - maps:get(own_amount, SysAccount1)).

-spec payment_adjustment_captured_from_failed(config()) -> test_return().
payment_adjustment_captured_from_failed(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, PartyCtx} = PartyPair = cfg(party_client, C),
    {ok, Shop} = party_client_thrift:get_shop(PartyID, cfg(shop_id, C), PartyClient, PartyCtx),
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(1), PartyPair),
    Amount = 42000,
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(3), Amount, C),
    PaymentParams = make_scenario_payment_params([temp, temp, temp, temp], ?pmt_sys(<<"visa-ref">>)),
    CaptureAmount = Amount div 2,
    CaptureCost = ?cash(CaptureAmount, <<"RUB">>),
    Captured = {captured, #domain_InvoicePaymentCaptured{cost = CaptureCost}},
    AdjustmentParams = make_status_adjustment_params(Captured, AdjReason = <<"manual">>),
    % start payment
    ?payment_state(?payment(PaymentID)) =
        hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?invalid_payment_status(?pending()) =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, AdjustmentParams, Client),
    PaymentID = await_payment_started(InvoiceID, PaymentID, Client),
    {CF1, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    {failed, PaymentID, {failure, _Failure}} =
        await_payment_process_failure(InvoiceID, PaymentID, Client, 3),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client),
    % get balances
    CFContext = construct_ta_context(cfg(party_id, C), cfg(shop_id, C), Route),
    PrvAccount1 = get_deprecated_cashflow_account({provider, settlement}, CF1, CFContext),
    SysAccount1 = get_deprecated_cashflow_account({system, settlement}, CF1, CFContext),
    MrcAccount1 = get_deprecated_cashflow_account({merchant, settlement}, CF1, CFContext),
    % update terminal cashflow
    ok = update_payment_terms_cashflow(?prv(100), get_payment_adjustment_provider_cashflow(actual)),
    % update merchant fees
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(3), PartyPair),

    InvalidAdjustmentParams1 = make_status_adjustment_params({processed, #domain_InvoicePaymentProcessed{}}),
    ?invalid_payment_target_status(?processed()) =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, InvalidAdjustmentParams1, Client),

    FailedTargetStatus = ?failed({failure, #domain_Failure{code = <<"404">>}}),
    FailedAdjustmentParams = make_status_adjustment_params(FailedTargetStatus),
    _FailedAdjustmentID = execute_payment_adjustment(InvoiceID, PaymentID, FailedAdjustmentParams, Client),

    ?assertMatch(
        ?payment_state(?payment_w_status(PaymentID, FailedTargetStatus)),
        hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client)
    ),

    ?payment_already_has_status(FailedTargetStatus) =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, FailedAdjustmentParams, Client),

    AdjustmentID = execute_payment_adjustment(InvoiceID, PaymentID, AdjustmentParams, Client),
    ?payment_state(Payment) = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ?assertMatch(#domain_InvoicePayment{status = Captured, cost = CaptureCost}, Payment),

    % verify that cash deposited correctly everywhere
    % new cash flow must be calculated using initial domain and party revisions
    #domain_InvoicePaymentAdjustment{new_cash_flow = DCF2} =
        ?adjustment_reason(AdjReason) =
        hg_client_invoicing:get_payment_adjustment(InvoiceID, PaymentID, AdjustmentID, Client),
    PrvAccount2 = get_deprecated_cashflow_account({provider, settlement}, DCF2, CFContext),
    SysAccount2 = get_deprecated_cashflow_account({system, settlement}, DCF2, CFContext),
    MrcAccount2 = get_deprecated_cashflow_account({merchant, settlement}, DCF2, CFContext),
    Context = #{operation_amount => CaptureCost},
    #domain_Cash{amount = MrcAmount1} = hg_cashflow:compute_volume(?merchant_to_system_share_1, Context),
    MrcDiff = CaptureAmount - MrcAmount1,
    ?assertEqual(MrcDiff, maps:get(own_amount, MrcAccount2) - maps:get(own_amount, MrcAccount1)),
    #domain_Cash{amount = PrvAmount1} = hg_cashflow:compute_volume(?system_to_provider_share_initial, Context),
    PrvDiff = PrvAmount1 - CaptureAmount,
    ?assertEqual(PrvDiff, maps:get(own_amount, PrvAccount2) - maps:get(own_amount, PrvAccount1)),
    SysDiff = MrcAmount1 - PrvAmount1,
    ?assertEqual(SysDiff, maps:get(own_amount, SysAccount2) - maps:get(own_amount, SysAccount1)).

-spec payment_adjustment_failed_from_captured(config()) -> test_return().
payment_adjustment_failed_from_captured(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, PartyCtx} = PartyPair = cfg(party_client, C),
    {ok, Shop} = party_client_thrift:get_shop(PartyID, cfg(shop_id, C), PartyClient, PartyCtx),
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(1), PartyPair),
    Amount = 100000,
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    %% start payment
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_started(InvoiceID, PaymentID, Client),
    {CF1, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    % get balances
    CFContext = construct_ta_context(cfg(party_id, C), cfg(shop_id, C), Route),
    PrvAccount1 = get_deprecated_cashflow_account({provider, settlement}, CF1, CFContext),
    SysAccount1 = get_deprecated_cashflow_account({system, settlement}, CF1, CFContext),
    MrcAccount1 = get_deprecated_cashflow_account({merchant, settlement}, CF1, CFContext),
    % update terminal cashflow
    ok = update_payment_terms_cashflow(?prv(100), get_payment_adjustment_provider_cashflow(actual)),
    % update merchant fees
    ok = hg_ct_helper:adjust_contract(PartyID, Shop#domain_Shop.contract_id, ?tmpl(3), PartyPair),
    % make an adjustment
    Failed = ?failed({failure, #domain_Failure{code = <<"404">>}}),
    AdjustmentParams = make_status_adjustment_params(Failed, AdjReason = <<"because i can">>),
    AdjustmentID = execute_payment_adjustment(InvoiceID, PaymentID, AdjustmentParams, Client),
    ?adjustment_reason(AdjReason) =
        hg_client_invoicing:get_payment_adjustment(InvoiceID, PaymentID, AdjustmentID, Client),
    ?assertMatch(
        ?payment_state(?payment_w_status(PaymentID, Failed)),
        hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client)
    ),
    % verify that cash deposited correctly everywhere
    % new cash flow must be calculated using initial domain and party revisions
    PrvAccount2 = get_deprecated_cashflow_account({provider, settlement}, CF1, CFContext),
    SysAccount2 = get_deprecated_cashflow_account({system, settlement}, CF1, CFContext),
    MrcAccount2 = get_deprecated_cashflow_account({merchant, settlement}, CF1, CFContext),
    Context = #{operation_amount => ?cash(Amount, <<"RUB">>)},
    #domain_Cash{amount = MrcAmount1} = hg_cashflow:compute_volume(?merchant_to_system_share_1, Context),
    MrcDiff = Amount - MrcAmount1,
    ?assertEqual(MrcDiff, maps:get(own_amount, MrcAccount1) - maps:get(own_amount, MrcAccount2)),
    #domain_Cash{amount = PrvAmount1} = hg_cashflow:compute_volume(?system_to_provider_share_initial, Context),
    PrvDiff = PrvAmount1 - Amount,
    ?assertEqual(PrvDiff, maps:get(own_amount, PrvAccount1) - maps:get(own_amount, PrvAccount2)),
    SysDiff = MrcAmount1 - PrvAmount1,
    ?assertEqual(SysDiff, maps:get(own_amount, SysAccount1) - maps:get(own_amount, SysAccount2)).

-spec status_adjustment_of_partial_refunded_payment(config()) -> test_return().
status_adjustment_of_partial_refunded_payment(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    RefundParams = make_refund_params(10000, <<"RUB">>),
    _RefundID = execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    FailedTargetStatus = ?failed({failure, #domain_Failure{code = <<"404">>}}),
    FailedAdjustmentParams = make_status_adjustment_params(FailedTargetStatus),
    {exception, #base_InvalidRequest{
        errors = [<<"Cannot change status of payment with refunds.">>]
    }} = hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, FailedAdjustmentParams, Client).

-spec registered_payment_adjustment_success(config()) -> _.
registered_payment_adjustment_success(C) ->
    %% old cf :
    %% merch - 4500   -> syst
    %% prov  - 100000 -> merch
    %% syst  - 2100   -> prov
    %%
    %% new cf :
    %% merch - 4500   -> syst
    %% prov  - 100000 -> merch
    %% syst  - 1600   -> prov
    %% syst  - 20     -> ext
    Client = cfg(client, C),

    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 100000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    Route = ?route(?prv(100), ?trm(1)),
    PaymentParams = #payproc_RegisterInvoicePaymentParams{
        payer_params =
            {payment_resource, #payproc_PaymentResourcePayerParams{
                resource = #domain_DisposablePaymentResource{
                    payment_tool = PaymentTool,
                    payment_session_id = Session,
                    client_info = #domain_ClientInfo{}
                },
                contact_info = ?contact_info()
            }},
        route = Route,
        transaction_info = ?trx_info(<<"1">>, #{})
    },
    ?payment_state(?payment(PaymentID)) =
        hg_client_invoicing:register_payment(InvoiceID, PaymentParams, Client),
    _ = start_payment_ev_no_risk_scoring(InvoiceID, Client),
    ?payment_ev(PaymentID, ?cash_flow_changed(CF1)) =
        next_change(InvoiceID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),

    CFContext = construct_ta_context(cfg(party_id, C), cfg(shop_id, C), Route),
    PrvAccount1 = get_deprecated_cashflow_account({provider, settlement}, CF1, CFContext),
    SysAccount1 = get_deprecated_cashflow_account({system, settlement}, CF1, CFContext),
    MrcAccount1 = get_deprecated_cashflow_account({merchant, settlement}, CF1, CFContext),
    %% update terminal cashflow
    ok = update_payment_terms_cashflow(?prv(100), get_payment_adjustment_provider_cashflow(actual)),

    %% make an adjustment
    Params = make_adjustment_params(Reason = <<"imdrunk">>),
    ?adjustment(AdjustmentID, ?adjustment_pending()) =
        Adjustment =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, Params, Client),
    Adjustment =
        #domain_InvoicePaymentAdjustment{id = AdjustmentID, reason = Reason} =
        hg_client_invoicing:get_payment_adjustment(InvoiceID, PaymentID, AdjustmentID, Client),
    ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_created(Adjustment))) =
        next_change(InvoiceID, Client),
    %% no way to create another one yet
    ?invalid_adjustment_pending(AdjustmentID) =
        hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, make_adjustment_params(), Client),
    [
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_processed()))),
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_captured(_))))
    ] = next_changes(InvoiceID, 2, Client),
    %% verify that cash deposited correctly everywhere
    #domain_InvoicePaymentAdjustment{new_cash_flow = DCF2} = Adjustment,
    PrvAccount2 = get_deprecated_cashflow_account({provider, settlement}, DCF2, CFContext),
    SysAccount2 = get_deprecated_cashflow_account({system, settlement}, DCF2, CFContext),
    MrcAccount2 = get_deprecated_cashflow_account({merchant, settlement}, DCF2, CFContext),
    0 = MrcDiff = maps:get(own_amount, MrcAccount2) - maps:get(own_amount, MrcAccount1),
    -500 = PrvDiff = maps:get(own_amount, PrvAccount2) - maps:get(own_amount, PrvAccount1),
    SysDiff = MrcDiff - PrvDiff - 20,
    SysDiff = maps:get(own_amount, SysAccount2) - maps:get(own_amount, SysAccount1).

-spec payment_temporary_unavailability_retry_success(config()) -> test_return().
payment_temporary_unavailability_retry_success(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    Cost = make_cash(Amount),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    PaymentParams = make_scenario_payment_params([temp, temp, good, temp, temp], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_sessions_restarts(PaymentID, ?processed(), InvoiceID, Client, 2),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cost, _, _)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost), ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),
    PaymentID = await_sessions_restarts(PaymentID, ?captured(Reason, Cost, undefined), InvoiceID, Client, 2),
    PaymentID = await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured(Reason, Cost)))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_temporary_unavailability_too_many_retries(config()) -> test_return().
payment_temporary_unavailability_too_many_retries(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_scenario_payment_params([temp, temp, temp, temp], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    {failed, PaymentID, {failure, Failure}} =
        await_payment_process_failure(InvoiceID, PaymentID, Client, 3),
    ok = payproc_errors:match(
        'PaymentFailure',
        Failure,
        fun({authorization_failed, {temporarily_unavailable, _}}) -> ok end
    ).

update_payment_terms_cashflow(ProviderRef, CashFlow) ->
    Provider = hg_domain:get({provider, ProviderRef}),
    ProviderTerms = Provider#domain_Provider.terms,
    PaymentTerms = ProviderTerms#domain_ProvisionTermSet.payments,
    NewProvider = Provider#domain_Provider{
        terms = ProviderTerms#domain_ProvisionTermSet{
            payments = PaymentTerms#domain_PaymentsProvisionTerms{
                cash_flow = {value, CashFlow}
            }
        }
    },
    _ = hg_domain:upsert(
        {provider, #domain_ProviderObject{
            ref = ProviderRef,
            data = NewProvider
        }}
    ),
    ok.

construct_ta_context(Party, Shop, Route) ->
    #{
        party => Party,
        shop => Shop,
        route => Route
    }.

get_deprecated_cashflow_account(Type, CF, CFContext) ->
    ID = get_deprecated_cashflow_account_id(Type, CF, CFContext),
    hg_accounting:get_balance(ID).

get_deprecated_cashflow_account_id(Type, CF, CFContext) ->
    Account = convert_transaction_account(Type, CFContext),
    [ID] = [
        V
     || #domain_FinalCashFlowPosting{
            destination = #domain_FinalCashFlowAccount{
                account_id = V,
                account_type = T,
                transaction_account = A
            }
        } <- CF,
        T == Type,
        A == Account
    ],
    ID.

-spec invalid_payment_w_deprived_party(config()) -> test_return().
invalid_payment_w_deprived_party(C) ->
    PartyID = <<"DEPRIVED ONE-II">>,
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    InvoicingClient = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),
    ShopID = hg_ct_helper:create_party_and_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubberduck">>, make_due_date(10), make_cash(42000)),
    InvoiceID = create_invoice(InvoiceParams, InvoicingClient),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, InvoicingClient),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    Exception = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, InvoicingClient),
    {exception, #base_InvalidRequest{}} = Exception.

-spec external_account_posting(config()) -> test_return().
external_account_posting(C) ->
    % Party создается в инициализации suite
    PartyID = ?PARTYID_EXTERNAL,
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    InvoicingClient = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),
    ShopID = hg_ct_helper:create_battle_ready_shop(PartyID, ?cat(2), <<"RUB">>, ?tmpl(2), ?pinst(2), PartyClient),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubbermoss">>, make_due_date(10), make_cash(42000)),
    InvoiceID = create_invoice(InvoiceParams, InvoicingClient),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, InvoicingClient),
    ?payment_state(
        ?payment(PaymentID)
    ) = hg_client_invoicing:start_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), InvoicingClient),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, InvoicingClient),
    {CF, Route} = await_payment_cash_flow(InvoiceID, PaymentID, InvoicingClient),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, InvoicingClient),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, InvoicingClient),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, InvoicingClient),
    [AssistAccountID] = [
        AccountID
     || #domain_FinalCashFlowPosting{
            destination = #domain_FinalCashFlowAccount{
                account_type = {external, outcome},
                account_id = AccountID
            },
            details = <<"Kek">>
        } <- CF
    ],
    CFContext = construct_ta_context(PartyID, ShopID, Route),
    AssistAccountID = get_deprecated_cashflow_account_id({external, outcome}, CF, CFContext),
    #domain_ExternalAccountSet{
        accounts = #{?cur(<<"RUB">>) := #domain_ExternalAccount{outcome = AssistAccountID}}
    } = hg_domain:get({external_account_set, ?eas(2)}).

-spec terminal_cashflow_overrides_provider(config()) -> test_return().
terminal_cashflow_overrides_provider(C) ->
    % Party создается в инициализации suite
    PartyID = ?PARTYID_EXTERNAL,
    RootUrl = cfg(root_url, C),
    PartyClient = cfg(party_client, C),
    InvoicingClient = hg_client_invoicing:start_link(hg_ct_helper:create_client(RootUrl)),
    ShopID = hg_ct_helper:create_battle_ready_shop(PartyID, ?cat(4), <<"RUB">>, ?tmpl(2), ?pinst(2), PartyClient),
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"rubbermoss">>, make_due_date(10), make_cash(42000)),
    InvoiceID = create_invoice(InvoiceParams, InvoicingClient),
    _ = next_change(InvoiceID, InvoicingClient),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(
        InvoiceID,
        make_payment_params(?pmt_sys(<<"visa-ref">>)),
        InvoicingClient
    ),
    _ = next_change(InvoiceID, InvoicingClient),
    {CF, Route} = await_payment_cash_flow(InvoiceID, PaymentID, InvoicingClient),
    _ = next_change(InvoiceID, InvoicingClient),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, InvoicingClient),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, InvoicingClient),
    [AssistAccountID] = [
        AccountID
     || #domain_FinalCashFlowPosting{
            destination = #domain_FinalCashFlowAccount{
                account_type = {external, outcome},
                account_id = AccountID
            },
            details = <<"Kek">>
        } <- CF
    ],
    CFContext = construct_ta_context(PartyID, ShopID, Route),
    AssistAccountID = get_deprecated_cashflow_account_id({external, outcome}, CF, CFContext),
    #domain_ExternalAccountSet{
        accounts = #{?cur(<<"RUB">>) := #domain_ExternalAccount{outcome = AssistAccountID}}
    } = hg_domain:get({external_account_set, ?eas(2)}).

%%  CHARGEBACKS

-spec create_chargeback_not_allowed(config()) -> _ | no_return().
create_chargeback_not_allowed(C) ->
    Cost = 42000,
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(1),
        <<"RUB">>,
        ?tmpl(1),
        ?pinst(1),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), Cost, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    CBParams = make_chargeback_params(?cash(1000, <<"RUB">>)),
    Result = hg_client_invoicing:create_chargeback(InvoiceID, PaymentID, CBParams, Client),
    ?assertMatch({exception, #payproc_OperationNotPermitted{}}, Result).

-spec create_chargeback_inconsistent(config()) -> _ | no_return().
create_chargeback_inconsistent(C) ->
    Cost = 42000,
    InconsistentLevy = make_chargeback_params(?cash(10, <<"USD">>)),
    InconsistentBody = make_chargeback_params(?cash(10, <<"RUB">>), ?cash(10, <<"USD">>)),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?assertMatch(
        {_, _, _, ?inconsistent_chargeback_currency(_)},
        start_chargeback(C, Cost, InconsistentLevy, PaymentParams)
    ),
    ?assertMatch(
        {_, _, _, ?inconsistent_chargeback_currency(_)},
        start_chargeback(C, Cost, InconsistentBody, PaymentParams)
    ).

-spec create_chargeback_exceeded(config()) -> _ | no_return().
create_chargeback_exceeded(C) ->
    Cost = 42000,
    ExceededBody = make_chargeback_params(?cash(100, <<"RUB">>), ?cash(100000, <<"RUB">>)),
    ?assertMatch(
        {_, _, _, ?invoice_payment_amount_exceeded(_)},
        start_chargeback(C, Cost, ExceededBody, make_payment_params(?pmt_sys(<<"visa-ref">>)))
    ).

-spec create_chargeback_idempotency(config()) -> _ | no_return().
create_chargeback_idempotency(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    ?assertMatch(CB, hg_client_invoicing:create_chargeback(IID, PID, CBParams, Client)),
    NewCBParams = make_chargeback_params(Levy),
    ?assertMatch(?chargeback_pending(), hg_client_invoicing:create_chargeback(IID, PID, NewCBParams, Client)),
    Settlement0 = hg_accounting:get_balance(SID),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement1)).

-spec cancel_payment_chargeback(config()) -> _ | no_return().
cancel_payment_chargeback(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement1)).

-spec cancel_partial_payment_chargeback(config()) -> _ | no_return().
cancel_partial_payment_chargeback(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 450,
    LevyAmount = 4000,
    Partial = 10000,
    Paid = Partial - Fee,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback_partial_capture(C, Cost, Partial, CBParams, ?pmt_sys(<<"mastercard-ref">>)),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Partial - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement1)).

-spec cancel_partial_payment_chargeback_exceeded(config()) -> _ | no_return().
cancel_partial_payment_chargeback_exceeded(C) ->
    Cost = 42000,
    LevyAmount = 4000,
    Partial = 10000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    Body = ?cash(Cost, <<"RUB">>),
    CBParams = make_chargeback_params(Levy, Body),
    {_IID, _PID, _SID, CB} = start_chargeback_partial_capture(
        C, Cost, Partial, CBParams, ?pmt_sys(<<"mastercard-ref">>)
    ),
    ?assertMatch(?invoice_payment_amount_exceeded(?cash(10000, <<"RUB">>)), CB).

-spec cancel_payment_chargeback_refund(config()) -> _ | no_return().
cancel_payment_chargeback_refund(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, _SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    RefundParams = make_refund_params(),
    RefundError = hg_client_invoicing:refund_payment(IID, PID, RefundParams, Client),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    RefundOk = hg_client_invoicing:refund_payment(IID, PID, RefundParams, Client),
    ?assertMatch(?chargeback_pending(), RefundError),
    ?assertMatch(#domain_InvoicePaymentRefund{}, RefundOk).

-spec reject_payment_chargeback_inconsistent(config()) -> _ | no_return().
reject_payment_chargeback_inconsistent(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, _SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    InconsistentParams = make_chargeback_reject_params(?cash(10, <<"USD">>)),
    Inconsistent = hg_client_invoicing:reject_chargeback(IID, PID, CBID, InconsistentParams, Client),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    ?assertMatch(?inconsistent_chargeback_currency(_), Inconsistent).

-spec reject_payment_chargeback(config()) -> _ | no_return().
reject_payment_chargeback(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)).

-spec reject_payment_chargeback_no_fees(config()) -> _ | no_return().
reject_payment_chargeback_no_fees(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_wallet_payment_params(?pmt_srv(<<"qiwi-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)).

-spec reject_payment_chargeback_new_levy(config()) -> _ | no_return().
reject_payment_chargeback_new_levy(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(CF0)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectAmount = 5000,
    RejectLevy = ?cash(RejectAmount, <<"RUB">>),
    RejectParams = make_chargeback_reject_params(RejectLevy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(RejectLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(CF1))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 4, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertNotEqual(CF0, CF1),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - RejectAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - RejectAmount, maps:get(max_available_amount, Settlement1)).

-spec accept_payment_chargeback_inconsistent(config()) -> _ | no_return().
accept_payment_chargeback_inconsistent(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, _SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    InconsistentLevyParams = make_chargeback_accept_params(?cash(10, <<"USD">>), undefined),
    InconsistentBodyParams = make_chargeback_accept_params(undefined, ?cash(10, <<"USD">>)),
    InconsistentLevy = hg_client_invoicing:accept_chargeback(IID, PID, CBID, InconsistentLevyParams, Client),
    InconsistentBody = hg_client_invoicing:accept_chargeback(IID, PID, CBID, InconsistentBodyParams, Client),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    ?assertMatch(?inconsistent_chargeback_currency(_), InconsistentLevy),
    ?assertMatch(?inconsistent_chargeback_currency(_), InconsistentBody).

-spec accept_payment_chargeback_exceeded(config()) -> _ | no_return().
accept_payment_chargeback_exceeded(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, _SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    ExceedBody = 200000,
    ExceedParams = make_chargeback_accept_params(?cash(LevyAmount, <<"RUB">>), ?cash(ExceedBody, <<"RUB">>)),
    Exceeded = hg_client_invoicing:accept_chargeback(IID, PID, CBID, ExceedParams, Client),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    ?assertMatch(?invoice_payment_amount_exceeded(_), Exceeded).

-spec accept_payment_chargeback_empty_params(config()) -> _ | no_return().
accept_payment_chargeback_empty_params(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(max_available_amount, Settlement1)).

-spec accept_payment_chargeback_twice(config()) -> _ | no_return().
accept_payment_chargeback_twice(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    BodyAmount = 20000,
    Body = ?cash(BodyAmount, <<"RUB">>),
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams1 = make_chargeback_params(Levy, Body),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams1, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted())))
    ] = next_changes(IID, 2, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    CBParams2 = make_chargeback_params(Levy),
    Chargeback = hg_client_invoicing:create_chargeback(IID, PID, CBParams2, Client),
    CBID2 = Chargeback#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID2, ?chargeback_created(Chargeback))),
        ?payment_ev(PID, ?chargeback_ev(CBID2, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID2, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID2, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID2, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 3, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - BodyAmount - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - BodyAmount - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - BodyAmount - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - LevyAmount * 2, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - BodyAmount - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid - Cost - LevyAmount * 2, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid - Cost - LevyAmount * 2, maps:get(max_available_amount, Settlement3)).

-spec accept_payment_chargeback_new_body(config()) -> _ | no_return().
accept_payment_chargeback_new_body(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 5000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    Body = 40000,
    AcceptParams = make_chargeback_accept_params(undefined, ?cash(Body, <<"RUB">>)),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_body_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted())))
    ] = next_changes(IID, 4, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - Body - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - Body - LevyAmount, maps:get(max_available_amount, Settlement1)).

-spec accept_payment_chargeback_new_levy(config()) -> _ | no_return().
accept_payment_chargeback_new_levy(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 5000,
    NewLevyAmount = 4000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(?cash(NewLevyAmount, <<"RUB">>), undefined),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(?cash(NewLevyAmount, <<"RUB">>)))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 5, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - Cost - NewLevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - NewLevyAmount, maps:get(max_available_amount, Settlement1)).

-spec reopen_accepted_payment_chargeback_fails(config()) -> _ | no_return().
reopen_accepted_payment_chargeback_fails(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    LevyAmount = 5000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, _SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 3, Client),
    ReopenParams = make_chargeback_reopen_params(Levy),
    Error = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    ?assertMatch(?invalid_chargeback_status(_), Error).

-spec reopen_payment_chargeback_inconsistent(config()) -> _ | no_return().
reopen_payment_chargeback_inconsistent(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    LevyAmount = 5000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, _SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    InconsistentLevyParams = make_chargeback_reopen_params(?cash(10, <<"USD">>), undefined),
    InconsistentBodyParams = make_chargeback_reopen_params(Levy, ?cash(10, <<"USD">>)),
    InconsistentLevy = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, InconsistentLevyParams, Client),
    InconsistentBody = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, InconsistentBodyParams, Client),
    ?assertMatch(?inconsistent_chargeback_currency(_), InconsistentLevy),
    ?assertMatch(?inconsistent_chargeback_currency(_), InconsistentBody).

-spec reopen_payment_chargeback_exceeded(config()) -> _ | no_return().
reopen_payment_chargeback_exceeded(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    LevyAmount = 5000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, _SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    ExceededParams = make_chargeback_reopen_params(Levy, ?cash(50000, <<"RUB">>)),
    Exceeded = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ExceededParams, Client),
    ?assertMatch(?invoice_payment_amount_exceeded(_), Exceeded).

-spec reopen_payment_chargeback_cancel(config()) -> _ | no_return().
reopen_payment_chargeback_cancel(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 5000,
    ReopenLevyAmount = 10000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    ReopenLevy = ?cash(ReopenLevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ReopenParams = make_chargeback_reopen_params(ReopenLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(?chargeback_stage_pre_arbitration()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(ReopenLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    CancelParams = make_chargeback_cancel_params(),
    ok = hg_client_invoicing:cancel_chargeback(IID, PID, CBID, CancelParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_cancelled()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_cancelled())))
    ] = next_changes(IID, 3, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement3)).

-spec reopen_payment_chargeback_reject(config()) -> _ | no_return().
reopen_payment_chargeback_reject(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 5000,
    ReopenLevyAmount = 10000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    ReopenLevy = ?cash(ReopenLevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ReopenParams = make_chargeback_reopen_params(ReopenLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(?chargeback_stage_pre_arbitration()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(ReopenLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(Levy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 4, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement3)).

-spec reopen_payment_chargeback_accept(config()) -> _ | no_return().
reopen_payment_chargeback_accept(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    ReopenLevyAmount = 4500,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    ReopenLevy = ?cash(ReopenLevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ReopenParams = make_chargeback_reopen_params(ReopenLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(ReopenLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 3, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(max_available_amount, Settlement3)).

-spec reopen_payment_chargeback_skip_stage_accept(config()) -> _ | no_return().
reopen_payment_chargeback_skip_stage_accept(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    ReopenLevyAmount = 4500,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    ReopenLevy = ?cash(ReopenLevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    NextStage = ?chargeback_stage_arbitration(),
    ReopenParams = make_chargeback_reopen_params_move_to_stage(ReopenLevy, NextStage),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(NextStage))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(ReopenLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 3, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(max_available_amount, Settlement3)).

-spec reopen_payment_chargeback_accept_new_levy(config()) -> _ | no_return().
reopen_payment_chargeback_accept_new_levy(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 4000,
    ReopenLevyAmount = 4500,
    AcceptLevyAmount = 5000,
    Body = ?cash(Cost, <<"RUB">>),
    Levy = ?cash(LevyAmount, <<"RUB">>),
    ReopenLevy = ?cash(ReopenLevyAmount, <<"RUB">>),
    AcceptLevy = ?cash(AcceptLevyAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ReopenParams = make_chargeback_reopen_params(ReopenLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(ReopenLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(AcceptLevy, Body),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 5, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid - Cost - AcceptLevyAmount, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid - Cost - AcceptLevyAmount, maps:get(max_available_amount, Settlement3)).

-spec reopen_payment_chargeback_arbitration(config()) -> _ | no_return().
reopen_payment_chargeback_arbitration(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 5000,
    ReopenLevyAmount = 10000,
    ReopenArbAmount = 15000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    ReopenLevy = ?cash(ReopenLevyAmount, <<"RUB">>),
    ReopenArbLevy = ?cash(ReopenArbAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ReopenParams = make_chargeback_reopen_params(ReopenLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(ReopenLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 4, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ReopenArbParams = make_chargeback_reopen_params(ReopenArbLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenArbParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement4 = hg_accounting:get_balance(SID),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(IID, PID, CBID, AcceptParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PID, ?payment_status_changed(?charged_back()))
    ] = next_changes(IID, 3, Client),
    Settlement5 = hg_accounting:get_balance(SID),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement3)),
    ?assertEqual(Paid - Cost - ReopenArbAmount, maps:get(min_available_amount, Settlement4)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement4)),
    ?assertEqual(Paid - Cost - ReopenArbAmount, maps:get(min_available_amount, Settlement5)),
    ?assertEqual(Paid - Cost - ReopenArbAmount, maps:get(max_available_amount, Settlement5)).

-spec reopen_payment_chargeback_arbitration_reopen_fails(config()) -> _ | no_return().
reopen_payment_chargeback_arbitration_reopen_fails(C) ->
    Client = cfg(client, C),
    Cost = 42000,
    Fee = 1890,
    Paid = Cost - Fee,
    LevyAmount = 5000,
    ReopenLevyAmount = 10000,
    ReopenArbAmount = 15000,
    Levy = ?cash(LevyAmount, <<"RUB">>),
    ReopenLevy = ?cash(ReopenLevyAmount, <<"RUB">>),
    ReopenArbLevy = ?cash(ReopenArbAmount, <<"RUB">>),
    CBParams = make_chargeback_params(Levy),
    {IID, PID, SID, CB} = start_chargeback(C, Cost, CBParams, make_payment_params(?pmt_sys(<<"visa-ref">>))),
    CBID = CB#domain_InvoicePaymentChargeback.id,
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_created(CB))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(IID, 2, Client),
    Settlement0 = hg_accounting:get_balance(SID),
    RejectParams = make_chargeback_reject_params(Levy),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 3, Client),
    Settlement1 = hg_accounting:get_balance(SID),
    ReopenParams = make_chargeback_reopen_params(ReopenLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(ReopenLevy))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement2 = hg_accounting:get_balance(SID),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 4, Client),
    Settlement3 = hg_accounting:get_balance(SID),
    ReopenArbParams = make_chargeback_reopen_params(ReopenArbLevy),
    ok = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenArbParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_stage_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_pending()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_pending())))
    ] = next_changes(IID, 5, Client),
    Settlement4 = hg_accounting:get_balance(SID),
    ok = hg_client_invoicing:reject_chargeback(IID, PID, CBID, RejectParams, Client),
    [
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_levy_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_target_status_changed(?chargeback_status_rejected()))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_cash_flow_changed(_))),
        ?payment_ev(PID, ?chargeback_ev(CBID, ?chargeback_status_changed(?chargeback_status_rejected())))
    ] = next_changes(IID, 4, Client),
    Settlement5 = hg_accounting:get_balance(SID),
    Error = hg_client_invoicing:reopen_chargeback(IID, PID, CBID, ReopenArbParams, Client),
    ?assertEqual(Paid - Cost - LevyAmount, maps:get(min_available_amount, Settlement0)),
    ?assertEqual(Paid, maps:get(max_available_amount, Settlement0)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement1)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement1)),
    ?assertEqual(Paid - Cost - ReopenLevyAmount, maps:get(min_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement2)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement3)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement3)),
    ?assertEqual(Paid - Cost - ReopenArbAmount, maps:get(min_available_amount, Settlement4)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement4)),
    ?assertEqual(Paid - LevyAmount, maps:get(min_available_amount, Settlement5)),
    ?assertEqual(Paid - LevyAmount, maps:get(max_available_amount, Settlement5)),
    ?assertMatch(?chargeback_cannot_reopen_arbitration(), Error).

%% CHARGEBACK HELPERS

start_chargeback(C, Cost, CBParams, PaymentParams) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, Context} = PartyPair = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(PartyID, ?cat(2), <<"RUB">>, ?tmpl(2), ?pinst(2), PartyPair),
    {ok, Party} = party_client_thrift:get(PartyID, PartyClient, Context),
    Shop = maps:get(ShopID, Party#domain_Party.shops),
    Account = Shop#domain_Shop.account,
    SettlementID = Account#domain_ShopAccount.settlement,
    Settlement0 = hg_accounting:get_balance(SettlementID),
    % 0.045
    Fee = 1890,
    ?assertEqual(0, maps:get(min_available_amount, Settlement0)),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), Cost, C),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    Settlement1 = hg_accounting:get_balance(SettlementID),
    ?assertEqual(Cost - Fee, maps:get(min_available_amount, Settlement1)),
    Chargeback = hg_client_invoicing:create_chargeback(InvoiceID, PaymentID, CBParams, Client),
    {InvoiceID, PaymentID, SettlementID, Chargeback}.

start_chargeback_partial_capture(C, Cost, Partial, CBParams, PmtSys) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    Cash = ?cash(Partial, <<"RUB">>),
    {PartyClient, Context} = PartyPair = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(PartyID, ?cat(2), <<"RUB">>, ?tmpl(2), ?pinst(2), PartyPair),
    {ok, Party} = party_client_thrift:get(PartyID, PartyClient, Context),
    Shop = maps:get(ShopID, Party#domain_Party.shops),
    Account = Shop#domain_Shop.account,
    SettlementID = Account#domain_ShopAccount.settlement,
    Settlement0 = hg_accounting:get_balance(SettlementID),
    % Fee          = 450, % 0.045
    ?assertEqual(0, maps:get(min_available_amount, Settlement0)),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), Cost, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    PaymentParams = make_payment_params(PaymentTool, Session, {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Cash, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cash, _, _Allocation)),
        ?payment_ev(PaymentID, ?cash_flow_changed(_)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cash), ?session_started()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cash, Client),
    % Settlement1  = hg_accounting:get_balance(SettlementID),
    % ?assertEqual(Partial - Fee, maps:get(min_available_amount, Settlement1)),
    Chargeback = hg_client_invoicing:create_chargeback(InvoiceID, PaymentID, CBParams, Client),
    {InvoiceID, PaymentID, SettlementID, Chargeback}.

%% CHARGEBACKS

%%=============================================================================
%% refunds group

-spec invalid_refund_party_status(config()) -> _ | no_return().
invalid_refund_party_status(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    {PartyClient, Context} = cfg(party_client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    ok = party_client_thrift:suspend(PartyID, PartyClient, Context),
    {exception, #payproc_InvalidPartyStatus{
        status = {suspension, {suspended, _}}
    }} = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, make_refund_params(), Client),
    ok = party_client_thrift:activate(PartyID, PartyClient, Context),
    ok = party_client_thrift:block(PartyID, <<"BLOOOOCK">>, PartyClient, Context),
    {exception, #payproc_InvalidPartyStatus{
        status = {blocking, {blocked, _}}
    }} = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, make_refund_params(), Client),
    ok = party_client_thrift:unblock(PartyID, <<"UNBLOOOCK">>, PartyClient, Context).

-spec invalid_refund_shop_status(config()) -> _ | no_return().
invalid_refund_shop_status(C) ->
    Client = cfg(client, C),
    ShopID = cfg(shop_id, C),
    PartyID = cfg(party_id, C),
    {PartyClient, Context} = cfg(party_client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    ok = party_client_thrift:suspend_shop(PartyID, ShopID, PartyClient, Context),
    {exception, #payproc_InvalidShopStatus{
        status = {suspension, {suspended, _}}
    }} = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, make_refund_params(), Client),
    ok = party_client_thrift:activate_shop(PartyID, ShopID, PartyClient, Context),
    ok = party_client_thrift:block_shop(PartyID, ShopID, <<"BLOOOOCK">>, PartyClient, Context),
    {exception, #payproc_InvalidShopStatus{
        status = {blocking, {blocked, _}}
    }} = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, make_refund_params(), Client),
    ok = party_client_thrift:unblock_shop(PartyID, ShopID, <<"UNBLOOOCK">>, PartyClient, Context).

-spec payment_refund_idempotency(config()) -> _ | no_return().
payment_refund_idempotency(C) ->
    Client = cfg(client, C),
    RefundParams0 = make_refund_params(),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    InvoiceID2 = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    RefundID = <<"1">>,
    ExternalID = <<"42">>,
    RefundParams1 = RefundParams0#payproc_InvoicePaymentRefundParams{
        id = RefundID,
        external_id = ExternalID
    },
    % try starting the same refund twice
    Refund0 =
        ?refund_id(RefundID, ExternalID) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client),
    Refund0 =
        ?refund_id(RefundID, ExternalID) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client),
    RefundParams2 = RefundParams0#payproc_InvoicePaymentRefundParams{id = <<"2">>},
    % can't start a different refund
    case hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams2, Client) of
        ?operation_not_permitted() ->
            % the first refund is still in process
            ok;
        ?invalid_payment_status(?refunded()) ->
            % the first refund has already finished
            ok
    end,
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_payment_complete(InvoiceID, PaymentID, Client),

    % check refund completed
    Refund1 = Refund0#domain_InvoicePaymentRefund{status = ?refund_succeeded()},
    Refund1 = hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client),
    % get back a completed refund when trying to start a new one
    Refund1 = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client).

-spec payment_refund_success(config()) -> _ | no_return().
payment_refund_success(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, capture}), Client),
    RefundParams = make_refund_params(),
    % not finished yet
    ?invalid_payment_status(?processed()) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    % not enough funds on the merchant account
    Failure =
        {failure,
            payproc_errors:construct(
                'RefundFailure',
                {terms_violated, {insufficient_merchant_funds, ?err_gen_failure()}}
            )},
    ?refund_id(RefundID0) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID0, Client),
    [
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_rollback_started(Failure))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_status_changed(?refund_failed(Failure))))
    ] = next_changes(InvoiceID, 2, Client),
    % top up merchant account
    InvoiceID2 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    % create a refund finally
    RefundID = execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    #domain_InvoicePaymentRefund{status = ?refund_succeeded()} =
        hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client),
    % no more refunds for you
    ?invalid_payment_status(?refunded()) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client).

-spec payment_refund_failure(config()) -> _ | no_return().
payment_refund_failure(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_scenario_payment_params([good, good, fail], {hold, capture}, ?pmt_sys(<<"visa-ref">>)),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    RefundParams = make_refund_params(),
    % not finished yet
    ?invalid_payment_status(?processed()) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    % not enough funds on the merchant account
    NoFunds =
        {failure,
            payproc_errors:construct(
                'RefundFailure',
                {terms_violated, {insufficient_merchant_funds, ?err_gen_failure()}}
            )},
    ?refund_id(RefundID0) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID0, Client),
    [
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_rollback_started(NoFunds))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_status_changed(?refund_failed(NoFunds))))
    ] = next_changes(InvoiceID, 2, Client),
    % top up merchant account
    InvoiceID2 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    % create a refund finally
    ?refund_id(RefundID) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID, Client),
    [
        ?payment_ev(PaymentID, ?refund_ev(ID, ?session_ev(?refunded(), ?session_finished(?session_failed(Failure))))),
        ?payment_ev(PaymentID, ?refund_ev(ID, ?refund_rollback_started(Failure))),
        ?payment_ev(PaymentID, ?refund_ev(ID, ?refund_status_changed(?refund_failed(Failure))))
    ] = next_changes(InvoiceID, 3, Client),
    #domain_InvoicePaymentRefund{status = ?refund_failed(Failure)} =
        hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client).

-spec deadline_doesnt_affect_payment_refund(config()) -> _ | no_return().
deadline_doesnt_affect_payment_refund(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    % ms
    ProcessingDeadline = 4000,
    PaymentParams = set_processing_deadline(
        ProcessingDeadline, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, capture})
    ),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    RefundParams = make_refund_params(),
    % not finished yet
    ?invalid_payment_status(?processed()) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    timer:sleep(ProcessingDeadline),
    % not enough funds on the merchant account
    NoFunds =
        {failure,
            payproc_errors:construct(
                'RefundFailure',
                {terms_violated, {insufficient_merchant_funds, ?err_gen_failure()}}
            )},
    ?refund_id(RefundID0) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID0, Client),
    [
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_rollback_started(NoFunds))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_status_changed(?refund_failed(NoFunds))))
    ] = next_changes(InvoiceID, 2, Client),
    % top up merchant account
    InvoiceID2 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    % create a refund finally
    RefundID = execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    #domain_InvoicePaymentRefund{status = ?refund_succeeded()} =
        hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client).

-spec payment_manual_refund(config()) -> _ | no_return().
payment_manual_refund(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    TrxInfo = ?trx_info(<<"test">>, #{}),
    RefundParams = #payproc_InvoicePaymentRefundParams{
        reason = <<"manual">>,
        transaction_info = TrxInfo
    },
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    % not enough funds on the merchant account
    NoFunds =
        {failure,
            payproc_errors:construct(
                'RefundFailure',
                {terms_violated, {insufficient_merchant_funds, ?err_gen_failure()}}
            )},
    Refund0 =
        ?refund_id(RefundID0) =
        hg_client_invoicing:refund_payment_manual(InvoiceID, PaymentID, RefundParams, Client),
    [
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_created(Refund0, _, TrxInfo))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_rollback_started(NoFunds))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID0, ?refund_status_changed(?refund_failed(NoFunds))))
    ] = next_changes(InvoiceID, 3, Client),
    % top up merchant account
    InvoiceID2 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    % prevent proxy access
    OriginalRevision = hg_domain:head(),
    Fixture = payment_manual_refund_fixture(OriginalRevision),
    _ = hg_domain:upsert(Fixture),
    % create refund
    RefundID = execute_payment_manual_refund(InvoiceID, PaymentID, RefundParams, Client),
    #domain_InvoicePaymentRefund{status = ?refund_succeeded()} =
        hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client),
    ?invalid_payment_status(?refunded()) =
        hg_client_invoicing:refund_payment_manual(InvoiceID, PaymentID, RefundParams, Client),
    % reenable proxy
    _ = hg_domain:reset(OriginalRevision).

-spec payment_partial_refunds_success(config()) -> _ | no_return().
payment_partial_refunds_success(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    RefundParams0 = make_refund_params(43000, <<"RUB">>),
    % top up merchant account
    InvoiceID2 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 3000, C),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    % refund amount exceeds payment amount
    ?invoice_payment_amount_exceeded(_) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams0, Client),
    % first refund
    RefundParams1 = make_refund_params(10000, <<"RUB">>),
    RefundID1 = execute_payment_refund(InvoiceID, PaymentID, RefundParams1, Client),
    % refund amount exceeds payment amount
    RefundParams2 = make_refund_params(33000, <<"RUB">>),
    ?invoice_payment_amount_exceeded(?cash(32000, _)) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams2, Client),
    % second refund
    RefundParams3 = make_refund_params(30000, <<"RUB">>),
    RefundID3 = execute_payment_refund(InvoiceID, PaymentID, RefundParams3, Client),
    % check payment status = captured
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{status = ?captured()},
        refunds = [
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(10000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            },
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(30000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            }
        ]
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    % last refund
    RefundParams4 = make_refund_params(),
    RefundID4 = execute_payment_refund(InvoiceID, PaymentID, RefundParams4, Client),
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{status = ?refunded()},
        refunds = [
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(10000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            },
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(30000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            },
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(2000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            }
        ]
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    % no more refunds for you
    RefundParams5 = make_refund_params(1000, <<"RUB">>),
    ?invalid_payment_status(?refunded()) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams5, Client),
    % Check sequence
    ?assertEqual(<<"1">>, RefundID1),
    ?assertEqual(<<"2">>, RefundID3),
    ?assertEqual(<<"3">>, RefundID4).

-spec invalid_currency_payment_partial_refund(config()) -> _ | no_return().
invalid_currency_payment_partial_refund(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    RefundParams1 = make_refund_params(50, <<"EUR">>),
    ?inconsistent_refund_currency(<<"EUR">>) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client).

-spec invalid_amount_payment_partial_refund(config()) -> _ | no_return().
invalid_amount_payment_partial_refund(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    InvoiceAmount = 42000,
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), InvoiceAmount, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    RefundParams1 = make_refund_params(50, <<"RUB">>),
    {exception, #base_InvalidRequest{
        errors = [<<"Invalid amount, less than allowed minumum">>]
    }} =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client),
    RefundParams2 = make_refund_params(40001, <<"RUB">>),
    {exception, #base_InvalidRequest{
        errors = [<<"Invalid amount, more than allowed maximum">>]
    }} =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams2, Client),
    RefundAmount = 10000,
    %% make cart cost not equal to remaining invoice cost
    Cash = ?cash(InvoiceAmount - RefundAmount - 1, <<"RUB">>),
    Cart = ?cart(Cash, #{}),
    RefundParams3 = make_refund_params(RefundAmount, <<"RUB">>, Cart),
    {exception, #base_InvalidRequest{
        errors = [<<"Remaining payment amount not equal cart cost">>]
    }} =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams3, Client),
    %% miss cash in refund params
    RefundParams4 = #payproc_InvoicePaymentRefundParams{
        reason = <<"ZANOZED">>,
        cart = Cart
    },
    {exception, #base_InvalidRequest{
        errors = [<<"Refund amount does not match with the cart total amount">>]
    }} =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams4, Client).

-spec invalid_amount_partial_capture_and_refund(config()) -> _ | no_return().
invalid_amount_partial_capture_and_refund(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    % do a partial capture
    Cash = ?cash(21000, <<"RUB">>),
    Reason = <<"ok">>,
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client),
    PaymentID = await_payment_partial_capture(InvoiceID, PaymentID, Reason, Cash, Client),
    % try to refund an amount that exceeds capture amount
    RefundParams = make_refund_params(42000, <<"RUB">>),
    ?invoice_payment_amount_exceeded(?cash(21000, _)) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client).

-spec cant_start_simultaneous_partial_refunds(config()) -> _ | no_return().
cant_start_simultaneous_partial_refunds(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    RefundParams = make_refund_params(10000, <<"RUB">>),
    ?refund_id(RefundID1) = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    ?operation_not_permitted() =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID1, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID1, Client),
    PaymentID = await_refund_payment_process_finish(InvoiceID, PaymentID, Client),
    _RefundID2 = execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{status = ?captured()},
        refunds = [
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(10000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            },
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(10000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            }
        ]
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client).

-spec ineligible_payment_partial_refund(config()) -> _ | no_return().
ineligible_payment_partial_refund(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(100),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = execute_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    RefundParams = make_refund_params(5000, <<"RUB">>),
    ?operation_not_permitted() =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams, Client).

-spec retry_temporary_unavailability_refund(config()) -> _ | no_return().
retry_temporary_unavailability_refund(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_scenario_payment_params([good, good, temp, temp], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    RefundParams1 = make_refund_params(1000, <<"RUB">>),
    ?refund_id(RefundID1) = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID1, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID1, Client),
    PaymentID = await_refund_payment_process_finish(InvoiceID, PaymentID, Client, 2),
    % check payment status still captured and all refunds
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{status = ?captured()},
        refunds = [
            #payproc_InvoicePaymentRefund{
                refund = #domain_InvoicePaymentRefund{
                    cash = ?cash(1000, <<"RUB">>),
                    status = ?refund_succeeded()
                }
            }
        ]
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_refund_id_types(config()) -> _ | no_return().
payment_refund_id_types(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    TrxInfo = ?trx_info(<<"test">>, #{}),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    % top up merchant account
    InvoiceID2 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    _PaymentID2 = execute_payment(InvoiceID2, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),
    % create refund
    RefundParams = #payproc_InvoicePaymentRefundParams{
        reason = <<"42">>,
        cash = ?cash(5000, <<"RUB">>)
    },
    % 0
    ManualRefundParams = RefundParams#payproc_InvoicePaymentRefundParams{transaction_info = TrxInfo},
    ?refund_id(RefundID0) = hg_client_invoicing:refund_payment_manual(InvoiceID, PaymentID, ManualRefundParams, Client),
    PaymentID = await_partial_manual_refund_succeeded(InvoiceID, PaymentID, RefundID0, TrxInfo, Client),
    % 1
    RefundID1 = execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    % 2
    CustomIdManualParams = ManualRefundParams#payproc_InvoicePaymentRefundParams{id = <<"2">>},
    ?refund_id(RefundID2) = hg_client_invoicing:refund_payment_manual(
        InvoiceID,
        PaymentID,
        CustomIdManualParams,
        Client
    ),
    PaymentID = await_partial_manual_refund_succeeded(InvoiceID, PaymentID, RefundID2, TrxInfo, Client),
    % 3
    CustomIdParams = RefundParams#payproc_InvoicePaymentRefundParams{id = <<"m3">>},
    {exception, #base_InvalidRequest{}} =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, CustomIdParams, Client),
    RefundID3 = execute_payment_refund(InvoiceID, PaymentID, RefundParams, Client),
    % Check ids
    ?assertEqual(<<"m1">>, RefundID0),
    ?assertEqual(<<"2">>, RefundID1),
    ?assertEqual(<<"m2">>, RefundID2),
    ?assertEqual(<<"3">>, RefundID3).

-spec registered_payment_manual_refund_success(config()) -> test_return().
registered_payment_manual_refund_success(C) ->
    Client = cfg(client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(2),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        cfg(party_client, C)
    ),

    %% create balance
    InvoiceID1 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 50000, C),
    _PaymentID1 = execute_payment(InvoiceID1, make_payment_params(?pmt_sys(<<"visa-ref">>)), Client),

    %% register_payment
    {InvoiceID, PaymentID} = register_invoice_payment(ShopID, Client, C),

    RefundParams = make_manual_refund_params(),
    RefundID = execute_payment_manual_refund(InvoiceID, PaymentID, RefundParams, Client),
    #domain_InvoicePaymentRefund{status = ?refund_succeeded()} =
        hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client).

%%----------------- refunds group end

-spec payment_hold_cancellation(config()) -> _ | no_return().
payment_hold_cancellation(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 10000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, capture}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    ok = hg_client_invoicing:cancel_payment(InvoiceID, PaymentID, <<"whynot">>, Client),
    PaymentID = await_payment_cancel(InvoiceID, PaymentID, <<"whynot">>, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_unpaid()),
        [?payment_state(?payment_w_status(PaymentID, ?cancelled()))]
    ) = hg_client_invoicing:get(InvoiceID, Client),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

-spec payment_hold_double_cancellation(config()) -> _ | no_return().
payment_hold_double_cancellation(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 10000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, capture}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    ?assertEqual(ok, hg_client_invoicing:cancel_payment(InvoiceID, PaymentID, <<"whynot">>, Client)),
    Result = hg_client_invoicing:cancel_payment(InvoiceID, PaymentID, <<"whynot">>, Client),
    ?assertMatch({exception, #payproc_InvalidPaymentStatus{}}, Result).

-spec payment_hold_cancellation_captured(config()) -> _ | no_return().
payment_hold_cancellation_captured(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}), Client),
    ?assertEqual(ok, hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client)),
    Result = hg_client_invoicing:cancel_payment(InvoiceID, PaymentID, <<"whynot">>, Client),
    ?assertMatch({exception, #payproc_InvalidPaymentStatus{}}, Result).

-spec payment_hold_auto_cancellation(config()) -> _ | no_return().
payment_hold_auto_cancellation(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(20), 10000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_cancel(InvoiceID, PaymentID, undefined, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_unpaid()),
        [?payment_state(?payment_w_status(PaymentID, ?cancelled()))]
    ) = hg_client_invoicing:get(InvoiceID, Client),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

-spec payment_hold_capturing(config()) -> _ | no_return().
payment_hold_capturing(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}), Client),
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, <<"ok">>, Client).

-spec payment_hold_double_capturing(config()) -> _ | no_return().
payment_hold_double_capturing(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}), Client),
    ?assertEqual(ok, hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client)),
    Result = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client),
    ?assertMatch({exception, #payproc_InvalidPaymentStatus{}}, Result).

-spec payment_hold_capturing_cancelled(config()) -> _ | no_return().
payment_hold_capturing_cancelled(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}), Client),
    ?assertEqual(ok, hg_client_invoicing:cancel_payment(InvoiceID, PaymentID, <<"whynot">>, Client)),
    Result = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client),
    ?assertMatch({exception, #payproc_InvalidPaymentStatus{}}, Result).

-spec deadline_doesnt_affect_payment_capturing(config()) -> _ | no_return().
deadline_doesnt_affect_payment_capturing(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    % ms
    ProcessingDeadline = 4000,
    PaymentParams = set_processing_deadline(
        ProcessingDeadline, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel})
    ),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    timer:sleep(ProcessingDeadline),
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, <<"ok">>, Client).

-spec payment_hold_partial_capturing(config()) -> _ | no_return().
payment_hold_partial_capturing(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Cash = ?cash(10000, <<"RUB">>),
    Reason = <<"ok">>,
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cash, _, _Allocation)),
        ?payment_ev(PaymentID, ?cash_flow_changed(_)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cash), ?session_started()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cash, Client).

-spec payment_hold_partial_capturing_with_cart(config()) -> _ | no_return().
payment_hold_partial_capturing_with_cart(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Cash = ?cash(10000, <<"RUB">>),
    Cart = ?cart(Cash, #{}),
    Reason = <<"ok">>,
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Cart, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cash, _, _Allocation)),
        ?payment_ev(PaymentID, ?cash_flow_changed(_)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cash, Cart), ?session_started()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cash, Cart, Client).

-spec payment_hold_partial_capturing_with_cart_missing_cash(config()) -> _ | no_return().
payment_hold_partial_capturing_with_cart_missing_cash(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Cash = ?cash(10000, <<"RUB">>),
    Cart = ?cart(Cash, #{}),
    Reason = <<"ok">>,
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, undefined, Cart, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cash, _, _Allocation)),
        ?payment_ev(PaymentID, ?cash_flow_changed(_)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cash, Cart), ?session_started()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cash, Cart, Client).

-spec invalid_currency_partial_capture(config()) -> _ | no_return().
invalid_currency_partial_capture(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Cash = ?cash(10000, <<"USD">>),
    Reason = <<"ok">>,
    ?inconsistent_capture_currency(<<"RUB">>) =
        hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client).

-spec invalid_amount_partial_capture(config()) -> _ | no_return().
invalid_amount_partial_capture(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Cash = ?cash(100000, <<"RUB">>),
    Reason = <<"ok">>,
    ?amount_exceeded_capture_balance(42000) =
        hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client).

-spec invalid_permit_partial_capture_in_service(config()) -> _ | no_return().
invalid_permit_partial_capture_in_service(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(1),
        <<"RUB">>,
        ?tmpl(6),
        ?pinst(1),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Cash = ?cash(10000, <<"RUB">>),
    Reason = <<"ok">>,
    ?operation_not_permitted() = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client).

-spec invalid_permit_partial_capture_in_provider(config()) -> _ | no_return().
invalid_permit_partial_capture_in_provider(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    Cash = ?cash(10000, <<"RUB">>),
    Reason = <<"ok">>,
    ?operation_not_permitted() = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, Reason, Cash, Client).

-spec payment_hold_auto_capturing(config()) -> _ | no_return().
payment_hold_auto_capturing(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_tds_payment_params({hold, capture}, ?pmt_sys(<<"visa-ref">>)),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    _ = assert_success_post_request(get_post_request(UserInteraction)),
    ok = await_payment_process_interaction_completion(InvoiceID, PaymentID, UserInteraction, Client),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    _ = assert_invalid_post_request(get_post_request(UserInteraction)),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, ?timeout_reason(), Client).

-spec rounding_cashflow_volume(config()) -> _ | no_return().
rounding_cashflow_volume(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 100000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    {CF, Route} = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    CFContext = construct_ta_context(cfg(party_id, C), cfg(shop_id, C), Route),
    ?cash(0, <<"RUB">>) = get_cashflow_volume({provider, settlement}, {merchant, settlement}, CF, CFContext),
    ?cash(1, <<"RUB">>) = get_cashflow_volume({system, settlement}, {provider, settlement}, CF, CFContext),
    ?cash(1, <<"RUB">>) = get_cashflow_volume({system, settlement}, {system, subagent}, CF, CFContext),
    ?cash(1, <<"RUB">>) = get_cashflow_volume({system, settlement}, {external, outcome}, CF, CFContext),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

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

%%

-spec terms_retrieval(config()) -> _ | no_return().
terms_retrieval(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 1500, C),
    Timestamp = hg_datetime:format_now(),
    TermSet1 = hg_client_invoicing:compute_terms(InvoiceID, {timestamp, Timestamp}, Client),
    #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            payment_methods =
                {value, [
                    ?pmt(bank_card, ?bank_card(<<"jcb-ref">>)),
                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>)),
                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                    ?pmt(bank_card, ?token_bank_card(<<"visa-ref">>, <<"applepay-ref">>)),
                    ?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>)),
                    ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
                    ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                    ?pmt(mobile, ?mob(<<"mts-ref">>)),
                    ?pmt(payment_terminal, ?pmt_srv(<<"euroset-ref">>))
                ]}
        }
    } = TermSet1,
    Revision = hg_domain:head(),
    _ = hg_domain:update(construct_term_set_for_cost(1000, 2000)),
    Timestamp2 = hg_datetime:format_now(),
    TermSet2 = hg_client_invoicing:compute_terms(InvoiceID, {timestamp, Timestamp2}, Client),
    #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            payment_methods = {value, [?pmt(bank_card, ?bank_card(<<"visa-ref">>))]}
        }
    } = TermSet2,
    _ = hg_domain:reset(Revision).

%%

-define(repair_set_timer(T), #repair_ComplexAction{timer = {set_timer, #repair_SetTimerAction{timer = T}}}).
-define(repair_mark_removal(), #repair_ComplexAction{remove = #repair_RemoveAction{}}).

-spec adhoc_repair_working_failed(config()) -> _ | no_return().
adhoc_repair_working_failed(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    {exception, #base_InvalidRequest{}} = repair_invoice(InvoiceID, [], Client),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec adhoc_repair_failed_succeeded(config()) -> _ | no_return().
adhoc_repair_failed_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(unexpected_failure, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(PaymentID))))
    ] = next_changes(InvoiceID, 2, Client),
    % assume no more events here since machine is FUBAR already
    timeout = next_change(InvoiceID, 2000, Client),
    Change = ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
    ok = repair_invoice(InvoiceID, [Change], ?repair_set_timer({timeout, 0}), undefined, Client),
    Change = next_change(InvoiceID, Client),
    ?payment_ev(PaymentID, ?payment_status_changed(?processed())) =
        next_change(InvoiceID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec adhoc_repair_force_removal(config()) -> _ | no_return().
adhoc_repair_force_removal(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    _PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    timeout = next_change(InvoiceID, 1000, Client),
    _ = ?assertEqual(ok, hg_invoice:fail(InvoiceID)),
    ?assertException(
        error,
        {{woody_error, {external, result_unexpected, _}}, _},
        hg_client_invoicing:rescind(InvoiceID, <<"LOL NO">>, Client)
    ),
    ok = repair_invoice(InvoiceID, [], ?repair_mark_removal(), undefined, Client),
    {exception, #payproc_InvoiceNotFound{}} = hg_client_invoicing:get(InvoiceID, Client).

-spec adhoc_repair_invalid_changes_failed(config()) -> _ | no_return().
adhoc_repair_invalid_changes_failed(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(unexpected_failure, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(PaymentID))))
    ] = next_changes(InvoiceID, 2, Client),
    timeout = next_change(InvoiceID, 5000, Client),
    InvalidChanges1 = [
        ?payment_ev(PaymentID, ?refund_ev(<<"42">>, ?refund_status_changed(?refund_succeeded())))
    ],
    ?assertException(
        error,
        {{woody_error, {external, result_unexpected, _}}, _},
        repair_invoice(InvoiceID, InvalidChanges1, Client)
    ),
    InvalidChanges2 = [
        ?payment_ev(PaymentID, ?payment_status_changed(?captured())),
        ?invoice_status_changed(?invoice_paid())
    ],
    ?assertException(
        error,
        {{woody_error, {external, result_unexpected, _}}, _},
        repair_invoice(InvoiceID, InvalidChanges2, Client)
    ),
    Change = ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
    ?assertEqual(
        ok,
        repair_invoice(InvoiceID, [Change], Client)
    ),
    Change = next_change(InvoiceID, Client),
    ?payment_ev(PaymentID, ?payment_status_changed(?processed())) =
        next_change(InvoiceID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec adhoc_repair_force_invalid_transition(config()) -> _ | no_return().
adhoc_repair_force_invalid_transition(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberdank">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    _ = ?assertEqual(ok, hg_invoice:fail(InvoiceID)),
    Failure = payproc_errors:construct(
        'PaymentFailure',
        {authorization_failed, {unknown, ?err_gen_failure()}}
    ),
    InvalidChanges = [
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure}))),
        ?invoice_status_changed(?invoice_unpaid())
    ],
    ?assertException(
        error,
        {{woody_error, {external, result_unexpected, _}}, _},
        repair_invoice(InvoiceID, InvalidChanges, Client)
    ),
    Params = #payproc_InvoiceRepairParams{validate_transitions = false},
    ?assertEqual(
        ok,
        repair_invoice(InvoiceID, InvalidChanges, #repair_ComplexAction{}, Params, Client)
    ),
    ?invoice_state(
        ?invoice_w_status(?invoice_unpaid()),
        [?payment_state(?payment_w_status(PaymentID, ?failed({failure, Failure})))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_with_offsite_preauth_success(config()) -> test_return().
payment_with_offsite_preauth_success(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(preauth_3ds_offsite, ?pmt_sys(<<"jcb-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    timer:sleep(2000),
    {URL, Form} = get_post_request(UserInteraction),
    _ = assert_success_post_request({URL, Form}),
    [
        ?payment_ev(
            PaymentID,
            ?session_ev(?processed(), ?trx_bound(?trx_info(_)))
        ),
        ?payment_ev(
            PaymentID,
            ?session_ev(?processed(), ?session_finished(?session_succeeded()))
        ),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec payment_with_offsite_preauth_failed(config()) -> test_return().
payment_with_offsite_preauth_failed(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(3), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(preauth_3ds_offsite, ?pmt_sys(<<"jcb-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    _UserInteraction = await_payment_process_interaction(InvoiceID, PaymentID, Client),
    ?payment_ev(
        PaymentID,
        ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))
    ) =
        next_change(InvoiceID, 8000, Client),
    ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})) =
        next_change(InvoiceID, 8000, Client),
    ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure}))) =
        next_change(InvoiceID, 8000, Client),
    ok = payproc_errors:match('PaymentFailure', Failure, fun({authorization_failed, _}) -> ok end),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

-spec payment_with_tokenized_bank_card(config()) -> test_return().
payment_with_tokenized_bank_card(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(
        tokenized_bank_card,
        {?pmt_sys(<<"visa-ref">>), ?token_srv(<<"applepay-ref">>), dpan}
    ),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    ?invoice_state(
        ?invoice_w_status(?invoice_paid()),
        [?payment_state(?payment_w_status(PaymentID, ?captured()))]
    ) = hg_client_invoicing:get(InvoiceID, Client).

-spec repair_fail_pre_processing_succeeded(config()) -> test_return().
repair_fail_pre_processing_succeeded(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(6),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    % Invoice
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, fail_pre_processing, Client),
    ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, _Failure}))) =
        next_change(InvoiceID, Client).

-spec repair_skip_inspector_succeeded(config()) -> test_return().
repair_skip_inspector_succeeded(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(6),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    % Invoice
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, skip_inspector, Client),
    _ = await_payment_cash_flow(low, ?route(?prv(2), ?trm(7)), InvoiceID, PaymentID, Client),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec repair_fail_session_on_processed_succeeded(config()) -> test_return().
repair_fail_session_on_processed_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(unexpected_failure, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(PaymentID))))
    ] = next_changes(InvoiceID, 2, Client),

    timeout = next_change(InvoiceID, 2000, Client),

    Failure = payproc_errors:construct(
        'PaymentFailure',
        {authorization_failed, {security_policy_violated, ?err_gen_failure()}},
        genlib:unique()
    ),
    ok = repair_invoice_with_scenario(InvoiceID, {fail_session, Failure}, Client),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
    ] = next_changes(InvoiceID, 3, Client).

-spec repair_fail_suspended_session_succeeded(config()) -> test_return().
repair_fail_suspended_session_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(
        unexpected_failure_when_suspended,
        ?pmt_sys(<<"visa-ref">>)
    ),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    Failure = construct_authorization_failure(),
    ok = repair_invoice_with_scenario(InvoiceID, {fail_session, Failure}, Client),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
    ] = next_changes(InvoiceID, 3, Client).

-spec repair_fail_session_on_pre_processing(config()) -> test_return().
repair_fail_session_on_pre_processing(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(7),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ?assertException(
        error,
        {{woody_error, {external, result_unexpected, _}}, _},
        repair_invoice_with_scenario(InvoiceID, {fail_session, construct_authorization_failure()}, Client)
    ),
    ok = repair_invoice_with_scenario(InvoiceID, fail_pre_processing, Client),
    ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, _Failure}))) =
        next_change(InvoiceID, Client).

-spec repair_complex_first_scenario_succeeded(config()) -> test_return().
repair_complex_first_scenario_succeeded(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(6),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    % Invoice
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),

    Scenarios = [
        skip_inspector,
        {fail_session, construct_authorization_failure()}
    ],
    ok = repair_invoice_with_scenario(InvoiceID, Scenarios, Client),

    _ = await_payment_cash_flow(low, ?route(?prv(2), ?trm(7)), InvoiceID, PaymentID, Client),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec repair_complex_second_scenario_succeeded(config()) -> test_return().
repair_complex_second_scenario_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(unexpected_failure, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(PaymentID))))
    ] = next_changes(InvoiceID, 2, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    Scenarios = [
        skip_inspector,
        {fail_session, Failure = construct_authorization_failure()}
    ],
    ok = repair_invoice_with_scenario(InvoiceID, Scenarios, Client),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
    ] = next_changes(InvoiceID, 3, Client).

-spec repair_fulfill_session_on_refund_succeeded(config()) -> _ | no_return().
repair_fulfill_session_on_refund_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_scenario_payment_params([good, good, error], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    RefundParams1 = make_refund_params(1000, <<"RUB">>),
    ?refund_id(RefundID1) = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID1, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID1, Client),
    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, {fulfill_session, ?trx_info(PaymentID, #{})}, Client),
    PaymentID = await_refund_payment_process_finish(InvoiceID, PaymentID, Client),
    ?payment_state(
        ?payment_w_status(?captured()),
        [?refund_state(?invoice_payment_refund(_, ?refund_succeeded()))]
    ) = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client).

-spec repair_fail_session_on_refund_succeeded(config()) -> _ | no_return().
repair_fail_session_on_refund_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_scenario_payment_params([good, good, error], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = execute_payment(InvoiceID, PaymentParams, Client),
    RefundParams1 = make_refund_params(1000, <<"RUB">>),
    ?refund_id(RefundID1) = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID1, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID1, Client),
    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, {fail_session, construct_authorization_failure()}, Client),
    [
        ?payment_ev(PaymentID, ?refund_ev(ID, ?session_ev(?refunded(), ?session_finished(?session_failed(Failure))))),
        ?payment_ev(PaymentID, ?refund_ev(ID, ?refund_rollback_started(Failure))),
        ?payment_ev(PaymentID, ?refund_ev(ID, ?refund_status_changed(?refund_failed(Failure))))
    ] = next_changes(InvoiceID, 3, Client),
    ?payment_state(
        ?payment_w_status(?captured()),
        [?refund_state(?invoice_payment_refund(_, ?refund_failed(Failure)))]
    ) = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client).

-spec repair_fulfill_session_on_processed_succeeded(config()) -> test_return().
repair_fulfill_session_on_processed_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(unexpected_failure_no_trx, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, fulfill_session, Client),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 2, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec repair_fulfill_suspended_session_succeeded(config()) -> test_return().
repair_fulfill_suspended_session_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(
        unexpected_failure_when_suspended,
        ?pmt_sys(<<"visa-ref">>)
    ),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, fulfill_session, Client),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 2, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

-spec repair_fulfill_session_on_captured_succeeded(config()) -> test_return().
repair_fulfill_session_on_captured_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    PaymentParams = make_scenario_payment_params([good, error], ?pmt_sys(<<"visa-ref">>)),
    PaymentID = process_payment(InvoiceID, PaymentParams, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, _, _, _)),
        ?payment_ev(PaymentID, ?session_ev(?captured(), ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, fulfill_session, Client),

    PaymentID = await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client).

-spec repair_fulfill_session_on_pre_processing_failed(config()) -> test_return().
repair_fulfill_session_on_pre_processing_failed(C) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(7),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    PaymentParams = make_payment_params(?pmt_sys(<<"visa-ref">>)),
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ?assertException(
        error,
        {{woody_error, {external, result_unexpected, _}}, _},
        repair_invoice_with_scenario(InvoiceID, fulfill_session, Client)
    ),
    ok = repair_invoice_with_scenario(InvoiceID, fail_pre_processing, Client),
    ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, _Failure}))) =
        next_change(InvoiceID, Client).

-spec repair_fulfill_session_with_trx_succeeded(config()) -> test_return().
repair_fulfill_session_with_trx_succeeded(C) ->
    Client = cfg(client, C),
    InvoiceID = start_invoice(<<"rubbercrack">>, make_due_date(10), 42000, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(unexpected_failure_no_trx, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),

    timeout = next_change(InvoiceID, 2000, Client),
    ok = repair_invoice_with_scenario(InvoiceID, {fulfill_session, ?trx_info(PaymentID, #{})}, Client),

    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(PaymentID)))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client).

construct_authorization_failure() ->
    payproc_errors:construct(
        'PaymentFailure',
        {authorization_failed, {unknown, ?err_gen_failure()}}
    ).

%%

init_allocation_group(C) ->
    PartyID = cfg(party_id, C),
    PartyClient = cfg(party_client, C),
    ShopID1 = hg_ct_helper:create_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    ShopID2 = hg_ct_helper:create_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    ShopID3 = hg_ct_helper:create_shop(PartyID, ?cat(1), <<"RUB">>, ?tmpl(1), ?pinst(1), PartyClient),
    [
        {shop_id_1, ShopID1},
        {shop_id_2, ShopID2},
        {shop_id_3, ShopID3}
        | C
    ].

-spec allocation_create_invoice(config()) -> _ | no_return().
allocation_create_invoice(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID0 = cfg(shop_id, C),
    ShopID1 = cfg(shop_id_1, C),
    ShopID2 = cfg(shop_id_2, C),
    ShopID3 = cfg(shop_id_3, C),
    InvoiceID = hg_utils:unique_id(),
    Cart = ?invoice_cart([?invoice_line(<<"STRING">>, 1, ?cash(30, <<"RUB">>))]),
    AllocationPrototype = ?allocation_prototype([
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID1),
            ?allocation_trx_prototype_body_amount(?cash(30, <<"RUB">>)),
            ?allocation_trx_details(Cart)
        ),
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID2),
            ?allocation_trx_prototype_body_total(
                ?cash(30, <<"RUB">>),
                ?allocation_trx_prototype_fee_fixed(?cash(10, <<"RUB">>))
            ),
            ?allocation_trx_details(Cart)
        ),
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID3),
            ?allocation_trx_prototype_body_total(
                ?cash(30, <<"RUB">>),
                ?allocation_trx_prototype_fee_share(15, 100)
            ),
            ?allocation_trx_details(Cart)
        )
    ]),
    InvoiceParams0 = make_invoice_params(
        PartyID,
        ShopID0,
        <<"rubberduck">>,
        make_due_date(10),
        make_cash(90, <<"RUB">>),
        AllocationPrototype
    ),
    InvoiceParams1 = InvoiceParams0#payproc_InvoiceParams{
        id = InvoiceID
    },
    Invoice1 = hg_client_invoicing:create(InvoiceParams1, Client),
    #payproc_Invoice{invoice = DomainInvoice} = Invoice1,
    #domain_Invoice{
        id = InvoiceID,
        allocation = ?allocation(AllocationTrxs)
    } = DomainInvoice,
    [
        ?allocation_trx(
            <<"1">>,
            ?allocation_trx_target_shop(PartyID, ShopID1),
            ?cash(30, <<"RUB">>),
            ?allocation_trx_details(Cart)
        ),
        ?allocation_trx(
            <<"2">>,
            ?allocation_trx_target_shop(PartyID, ShopID2),
            ?cash(20, <<"RUB">>),
            ?allocation_trx_details(Cart),
            ?allocation_trx_body_total(
                ?allocation_trx_target_shop(PartyID, ShopID0),
                ?cash(30, <<"RUB">>),
                ?cash(10, <<"RUB">>)
            )
        ),
        ?allocation_trx(
            <<"3">>,
            ?allocation_trx_target_shop(PartyID, ShopID3),
            ?cash(25, <<"RUB">>),
            ?allocation_trx_details(Cart),
            ?allocation_trx_body_total(
                ?allocation_trx_target_shop(PartyID, ShopID0),
                ?cash(30, <<"RUB">>),
                ?cash(5, <<"RUB">>),
                ?allocation_trx_fee_share(15, 100)
            )
        ),
        ?allocation_trx(
            <<"4">>,
            ?allocation_trx_target_shop(PartyID, ShopID0),
            ?cash(15, <<"RUB">>)
        )
    ] = lists:sort(AllocationTrxs).

-spec allocation_capture_payment(config()) -> _ | no_return().
allocation_capture_payment(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID0 = cfg(shop_id, C),
    ShopID1 = cfg(shop_id_1, C),
    ShopID2 = cfg(shop_id_2, C),
    ShopID3 = cfg(shop_id_3, C),
    InvoiceID = hg_utils:unique_id(),
    Cart = ?invoice_cart([?invoice_line(<<"STRING">>, 1, ?cash(30, <<"RUB">>))]),
    AllocationPrototype = ?allocation_prototype([
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID1),
            ?allocation_trx_prototype_body_amount(?cash(3000, <<"RUB">>)),
            ?allocation_trx_details(Cart)
        ),
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID2),
            ?allocation_trx_prototype_body_total(
                ?cash(3000, <<"RUB">>),
                ?allocation_trx_prototype_fee_fixed(?cash(1000, <<"RUB">>))
            ),
            ?allocation_trx_details(Cart)
        ),
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID3),
            ?allocation_trx_prototype_body_total(
                ?cash(3000, <<"RUB">>),
                ?allocation_trx_prototype_fee_share(15, 100)
            ),
            ?allocation_trx_details(Cart)
        )
    ]),
    InvoiceParams0 = make_invoice_params(
        PartyID,
        ShopID0,
        <<"rubberduck">>,
        make_due_date(10),
        make_cash(9000, <<"RUB">>),
        AllocationPrototype
    ),
    InvoiceParams1 = InvoiceParams0#payproc_InvoiceParams{
        id = InvoiceID
    },
    InvoiceID = create_invoice(InvoiceParams1, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}), Client),
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, <<"ok">>, Client),
    #payproc_InvoicePayment{
        allocation = ?allocation(FinalAllocationTrxs)
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ?assertMatch(
        [
            ?allocation_trx(
                <<"1">>,
                ?allocation_trx_target_shop(PartyID, ShopID1),
                ?cash(3000, <<"RUB">>),
                ?allocation_trx_details(Cart)
            ),
            ?allocation_trx(
                <<"2">>,
                ?allocation_trx_target_shop(PartyID, ShopID2),
                ?cash(2000, <<"RUB">>),
                ?allocation_trx_details(Cart),
                ?allocation_trx_body_total(
                    ?allocation_trx_target_shop(PartyID, ShopID0),
                    ?cash(3000, <<"RUB">>),
                    ?cash(1000, <<"RUB">>)
                )
            ),
            ?allocation_trx(
                <<"3">>,
                ?allocation_trx_target_shop(PartyID, ShopID3),
                ?cash(2550, <<"RUB">>),
                ?allocation_trx_details(Cart),
                ?allocation_trx_body_total(
                    ?allocation_trx_target_shop(PartyID, ShopID0),
                    ?cash(3000, <<"RUB">>),
                    ?cash(450, <<"RUB">>),
                    ?allocation_trx_fee_share(15, 100)
                )
            ),
            ?allocation_trx(
                <<"4">>,
                ?allocation_trx_target_shop(PartyID, ShopID0),
                ?cash(1450, <<"RUB">>)
            )
        ],
        lists:sort(FinalAllocationTrxs)
    ).

-spec allocation_refund_payment(config()) -> _ | no_return().
allocation_refund_payment(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    ShopID0 = cfg(shop_id, C),
    ShopID1 = cfg(shop_id_1, C),
    ShopID2 = cfg(shop_id_2, C),
    ShopID3 = cfg(shop_id_3, C),
    InvoiceID = hg_utils:unique_id(),
    Cart = ?invoice_cart([?invoice_line(<<"STRING">>, 1, ?cash(30, <<"RUB">>))]),
    AllocationPrototype = ?allocation_prototype([
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID1),
            ?allocation_trx_prototype_body_amount(?cash(3000, <<"RUB">>)),
            ?allocation_trx_details(Cart)
        ),
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID2),
            ?allocation_trx_prototype_body_total(
                ?cash(3000, <<"RUB">>),
                ?allocation_trx_prototype_fee_fixed(?cash(1000, <<"RUB">>))
            ),
            ?allocation_trx_details(Cart)
        ),
        ?allocation_trx_prototype(
            ?allocation_trx_target_shop(PartyID, ShopID3),
            ?allocation_trx_prototype_body_total(
                ?cash(3000, <<"RUB">>),
                ?allocation_trx_prototype_fee_share(15, 100)
            ),
            ?allocation_trx_details(Cart)
        )
    ]),
    InvoiceParams0 = make_invoice_params(
        PartyID,
        ShopID0,
        <<"rubberduck">>,
        make_due_date(10),
        make_cash(9000, <<"RUB">>),
        AllocationPrototype
    ),
    InvoiceParams1 = InvoiceParams0#payproc_InvoiceParams{
        id = InvoiceID
    },
    InvoiceID = create_invoice(InvoiceParams1, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),
    PaymentID = process_payment(InvoiceID, make_payment_params(?pmt_sys(<<"visa-ref">>), {hold, cancel}), Client),
    ok = hg_client_invoicing:capture_payment(InvoiceID, PaymentID, <<"ok">>, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, <<"ok">>, Client),
    #payproc_InvoicePayment{
        allocation = ?allocation(CapturedAllocationTrxs)
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    ?assertMatch(
        [
            ?allocation_trx(
                <<"1">>,
                ?allocation_trx_target_shop(PartyID, ShopID1),
                ?cash(3000, <<"RUB">>),
                ?allocation_trx_details(Cart)
            ),
            ?allocation_trx(
                <<"2">>,
                ?allocation_trx_target_shop(PartyID, ShopID2),
                ?cash(2000, <<"RUB">>),
                ?allocation_trx_details(Cart),
                ?allocation_trx_body_total(
                    ?allocation_trx_target_shop(PartyID, ShopID0),
                    ?cash(3000, <<"RUB">>),
                    ?cash(1000, <<"RUB">>)
                )
            ),
            ?allocation_trx(
                <<"3">>,
                ?allocation_trx_target_shop(PartyID, ShopID3),
                ?cash(2550, <<"RUB">>),
                ?allocation_trx_details(Cart),
                ?allocation_trx_body_total(
                    ?allocation_trx_target_shop(PartyID, ShopID0),
                    ?cash(3000, <<"RUB">>),
                    ?cash(450, <<"RUB">>),
                    ?allocation_trx_fee_share(15, 100)
                )
            ),
            ?allocation_trx(
                <<"4">>,
                ?allocation_trx_target_shop(PartyID, ShopID0),
                ?cash(1450, <<"RUB">>)
            )
        ],
        lists:sort(CapturedAllocationTrxs)
    ),

    RefundAllocationPrototype =
        ?allocation_prototype([
            ?allocation_trx_prototype(
                ?allocation_trx_target_shop(PartyID, ShopID1),
                ?allocation_trx_prototype_body_amount(?cash(3000, <<"RUB">>))
            )
        ]),
    RefundParams0 = make_refund_params(
        3000,
        <<"RUB">>,
        undefined,
        RefundAllocationPrototype
    ),
    RefundID = <<"1">>,
    RefundParams1 = RefundParams0#payproc_InvoicePaymentRefundParams{
        id = RefundID
    },
    Refund0 =
        ?refund_id(RefundID) =
        hg_client_invoicing:refund_payment(InvoiceID, PaymentID, RefundParams1, Client),

    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_payment_process_finish(InvoiceID, PaymentID, Client),
    % check refund completed
    Refund1 = Refund0#domain_InvoicePaymentRefund{status = ?refund_succeeded()},
    Refund1 = hg_client_invoicing:get_payment_refund(InvoiceID, PaymentID, RefundID, Client),
    #domain_InvoicePaymentRefund{
        allocation = ?allocation([
            ?allocation_trx(
                <<"1">>,
                ?allocation_trx_target_shop(PartyID, ShopID1),
                ?cash(3000, <<"RUB">>)
            )
        ])
    } = Refund1,
    #payproc_InvoicePayment{
        allocation = ?allocation(FinalAllocationTrxs)
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    [
        ?allocation_trx(
            <<"2">>,
            ?allocation_trx_target_shop(PartyID, ShopID2),
            ?cash(2000, <<"RUB">>),
            ?allocation_trx_details(Cart),
            ?allocation_trx_body_total(
                ?allocation_trx_target_shop(PartyID, ShopID0),
                ?cash(3000, <<"RUB">>),
                ?cash(1000, <<"RUB">>)
            )
        ),
        ?allocation_trx(
            <<"3">>,
            ?allocation_trx_target_shop(PartyID, ShopID3),
            ?cash(2550, <<"RUB">>),
            ?allocation_trx_details(Cart),
            ?allocation_trx_body_total(
                ?allocation_trx_target_shop(PartyID, ShopID0),
                ?cash(3000, <<"RUB">>),
                ?cash(450, <<"RUB">>),
                ?allocation_trx_fee_share(15, 100)
            )
        ),
        ?allocation_trx(
            <<"4">>,
            ?allocation_trx_target_shop(PartyID, ShopID0),
            ?cash(1450, <<"RUB">>)
        )
    ] = lists:sort(FinalAllocationTrxs).

%%

-spec consistent_account_balances(config()) -> test_return().
consistent_account_balances(C) ->
    Fun = fun(AccountID, Comment) ->
        case hg_accounting:get_balance(AccountID) of
            #{own_amount := V, min_available_amount := V, max_available_amount := V} ->
                ok;
            #{} = Account ->
                erlang:error({"Inconsistent account balance", Account, Comment})
        end
    end,

    {PartyClient, Context} = cfg(party_client, C),
    {ok, Party} = party_client_thrift:get(cfg(party_id, C), PartyClient, Context),
    Shops = maps:values(Party#domain_Party.shops),
    _ = [
        Fun(AccountID, Shop)
     || #domain_Shop{account = #domain_ShopAccount{settlement = ID1, guarantee = ID2}} = Shop <- Shops,
        AccountID <- [ID1, ID2]
    ],
    ok.

-spec payment_cascade_success(config()) -> test_return().
payment_cascade_success(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    InvoiceParams = make_invoice_params(
        cfg(party_id, C),
        cfg(shop_id, C),
        <<"rubberduck">>,
        make_due_date(10),
        make_cash(Amount)
    ),
    ?invoice_state(Invoice = ?invoice(InvoiceID)) = hg_client_invoicing:create(InvoiceParams, Client),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    Context = #base_Content{
        type = <<"application/x-erlang-binary">>,
        data = erlang:term_to_binary({you, 643, "not", [<<"welcome">>, here]})
    },
    PayerSessionInfo = #domain_PayerSessionInfo{
        redirect_url = RedirectURL = <<"https://redirectly.io/merchant">>
    },
    PaymentParams = (make_payment_params(PaymentTool, Session, instant))#payproc_InvoicePaymentParams{
        payer_session_info = PayerSessionInfo,
        context = Context
    },
    #payproc_InvoicePayment{payment = Payment} = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),
    {ok, Limit} = hg_limiter_helper:get_payment_limit_amount(?LIMIT_ID4, hg_domain:head(), Payment, Invoice),
    InitialAccountedAmount = hg_limiter_helper:get_amount(Limit),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    _ = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(
            PaymentID,
            ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))
        ),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
    ] =
        next_changes(InvoiceID, 3, Client),
    ok = payproc_errors:match('PaymentFailure', Failure, fun({preauthorization_failed, {card_blocked, _}}) -> ok end),
    %% Assert payment status IS NOT failed
    ?invoice_state(?invoice_w_status(_), [?payment_state(PaymentInterim)]) =
        hg_client_invoicing:get(InvoiceID, Client),
    ?assertNotMatch(#domain_InvoicePayment{status = {failed, _}}, PaymentInterim),
    ?payment_ev(PaymentID, ?route_changed(Route)) = next_change(InvoiceID, Client),
    ?assertMatch(#domain_PaymentRoute{provider = ?prv(1)}, Route),
    %% And again
    ?payment_ev(PaymentID, ?cash_flow_changed(_CashFlow)) = next_change(InvoiceID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    ?invoice_state(?invoice_w_status(?invoice_paid()), [PaymentSt = ?payment_state(PaymentFinal)]) =
        hg_client_invoicing:get(InvoiceID, Client),
    ?payment_w_status(PaymentID, ?captured()) = PaymentFinal,
    ?payment_last_trx(Trx) = PaymentSt,
    ?assertMatch(
        #domain_InvoicePayment{
            payer_session_info = PayerSessionInfo,
            context = Context
        },
        PaymentFinal
    ),
    ?assertMatch(
        #domain_TransactionInfo{
            extra = #{
                <<"payment.payer_session_info.redirect_url">> := RedirectURL
            }
        },
        Trx
    ),
    %% At the end of this scenario limit must be accounted only once.
    hg_limiter_helper:assert_payment_limit_amount(?LIMIT_ID4, InitialAccountedAmount + Amount, PaymentFinal, Invoice).

-spec payment_cascade_fail_wo_available_attempt_limit(config()) -> test_return().
payment_cascade_fail_wo_available_attempt_limit(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    _ = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(
            PaymentID,
            ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure})))
        ),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure})))
    ] =
        next_changes(InvoiceID, 3, Client),
    ok = payproc_errors:match('PaymentFailure', Failure, fun({preauthorization_failed, {card_blocked, _}}) -> ok end),
    %% Assert payment status IS failed
    ?invoice_state(?invoice_w_status(_), [?payment_state(Payment)]) =
        hg_client_invoicing:get(InvoiceID, Client),
    ?assertMatch(#domain_InvoicePayment{status = {failed, _}}, Payment),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

-spec payment_cascade_failures(config()) -> test_return().
payment_cascade_failures(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    _ = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(
            PaymentID,
            ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure1})))
        ),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure1})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure1})))
    ] =
        next_changes(InvoiceID, 3, Client),
    ok = payproc_errors:match('PaymentFailure', Failure1, fun({preauthorization_failed, {card_blocked, _}}) -> ok end),
    ?payment_ev(PaymentID, ?route_changed(_Route)) = next_change(InvoiceID, Client),
    %% And again
    ?payment_ev(PaymentID, ?cash_flow_changed(_CashFlow)) = next_change(InvoiceID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(
            PaymentID,
            ?session_ev(?processed(), ?session_finished(?session_failed({failure, Failure2})))
        ),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure2})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, Failure2})))
    ] =
        next_changes(InvoiceID, 3, Client),
    ok = payproc_errors:match('PaymentFailure', Failure2, fun({preauthorization_failed, {card_blocked, _}}) -> ok end),
    %% Assert payment status IS failed
    ?invoice_state(?invoice_w_status(_), [?payment_state(Payment)]) =
        hg_client_invoicing:get(InvoiceID, Client),
    ?assertMatch(#domain_InvoicePayment{status = {failed, _}}, Payment),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

-spec payment_cascade_no_route(config()) -> test_return().
payment_cascade_no_route(C) ->
    Client = cfg(client, C),
    Amount = 42000,
    InvoiceID = start_invoice(<<"rubberduck">>, make_due_date(10), Amount, C),
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_payment_params(PaymentTool, Session, instant),
    hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    _ = await_payment_cash_flow(InvoiceID, PaymentID, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    [
        ?payment_ev(
            PaymentID,
            ?session_ev(?processed(), ?session_finished(?session_failed({failure, CardBlockedFailure})))
        ),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, CardBlockedFailure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, CardBlockedFailure})))
    ] =
        next_changes(InvoiceID, 3, Client),
    ok = payproc_errors:match(
        'PaymentFailure',
        CardBlockedFailure,
        fun({preauthorization_failed, {card_blocked, _}}) -> ok end
    ),
    [
        ?payment_ev(PaymentID, ?route_changed(_Route)),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, CardBlockedFailure})),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed({failure, _Failure})))
    ] = next_changes(InvoiceID, 3, Client),
    %% Assert payment status IS failed
    ?invoice_state(?invoice_w_status(_), [?payment_state(Payment)]) =
        hg_client_invoicing:get(InvoiceID, Client),
    ?assertMatch(#domain_InvoicePayment{status = {failed, _}}, Payment),
    ?invoice_status_changed(?invoice_cancelled(<<"overdue">>)) = next_change(InvoiceID, Client).

%%

next_changes(InvoiceID, Amount, Client) ->
    next_changes(InvoiceID, Amount, ?DEFAULT_NEXT_CHANGE_TIMEOUT, Client).

next_changes(InvoiceID, Amount, Timeout, Client) ->
    TimeoutTime = erlang:monotonic_time(millisecond) + Timeout,
    next_changes_(InvoiceID, Amount, TimeoutTime, Client).

next_changes_(InvoiceID, Amount, Timeout, Client) ->
    Result = lists:foldl(
        fun(_N, Acc) ->
            case erlang:monotonic_time(millisecond) of
                Time when Time < Timeout ->
                    [next_change(InvoiceID, Client) | Acc];
                _ ->
                    [{error, timeout} | Acc]
            end
        end,
        [],
        lists:seq(1, Amount)
    ),
    lists:reverse(Result).

next_change(InvoiceID, Client) ->
    %% timeout should be at least as large as hold expiration in construct_domain_fixture/0
    next_change(InvoiceID, ?DEFAULT_NEXT_CHANGE_TIMEOUT, Client).

next_change(InvoiceID, Timeout, Client) ->
    hg_client_invoicing:pull_change(InvoiceID, fun filter_change/1, Timeout, Client).

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

%%

start_service_handler(Module, C, HandlerOpts) ->
    start_service_handler(Module, Module, C, HandlerOpts).

start_service_handler(Name, Module, C, HandlerOpts) ->
    IP = "127.0.0.1",
    Port = get_random_port(),
    Opts = maps:merge(HandlerOpts, #{hellgate_root_url => cfg(root_url, C)}),
    ChildSpec = hg_test_proxy:get_child_spec(Name, Module, IP, Port, Opts),
    {ok, _} = supervisor:start_child(cfg(test_sup, C), ChildSpec),
    hg_test_proxy:get_url(Module, IP, Port).

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

start_kv_store(SupPid) ->
    ChildSpec = #{
        id => hg_kv_store,
        start => {hg_kv_store, start_link, [[]]},
        restart => permanent,
        shutdown => 2000,
        type => worker,
        modules => [hg_kv_store]
    },
    {ok, _} = supervisor:start_child(SupPid, ChildSpec),
    ok.

get_random_port() ->
    rand:uniform(32768) + 32767.

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

%%
make_invoice_params(PartyID, ShopID, Product, Cost) ->
    hg_ct_helper:make_invoice_params(PartyID, ShopID, Product, Cost).

make_invoice_params(PartyID, ShopID, Product, Due, Cost) ->
    hg_ct_helper:make_invoice_params(PartyID, ShopID, Product, Due, Cost).

make_invoice_params(PartyID, ShopID, Product, Due, Cost, AllocationPrototype) ->
    InvoiceID = hg_utils:unique_id(),
    hg_ct_helper:make_invoice_params(InvoiceID, PartyID, ShopID, Product, Due, Cost, AllocationPrototype).

make_cash(Amount) ->
    make_cash(Amount, <<"RUB">>).

make_cash(Amount, Currency) ->
    hg_ct_helper:make_cash(Amount, Currency).

make_tpl_cost(Type, P1, P2) ->
    hg_ct_helper:make_invoice_tpl_cost(Type, P1, P2).

create_invoice_tpl(Config) ->
    Cost = hg_ct_helper:make_invoice_tpl_cost(fixed, 100, <<"RUB">>),
    Context = hg_ct_helper:make_invoice_context(),
    create_invoice_tpl(Config, Cost, Context).

create_invoice_tpl(Config, Cost, Context) ->
    Client = cfg(client_tpl, Config),
    PartyID = cfg(party_id, Config),
    ShopID = cfg(shop_id, Config),
    Lifetime = hg_ct_helper:make_lifetime(0, 1, 0),
    Product = <<"rubberduck">>,
    Details = hg_ct_helper:make_invoice_tpl_details(Product, Cost),
    Params = hg_ct_helper:make_invoice_tpl_create_params(PartyID, ShopID, Lifetime, Product, Details, Context),
    #domain_InvoiceTemplate{id = TplID} = hg_client_invoice_templating:create(Params, Client),
    TplID.

get_invoice_tpl(TplID, Config) ->
    hg_client_invoice_templating:get(TplID, cfg(client_tpl, Config)).

update_invoice_tpl(TplID, Cost, Config) ->
    Client = cfg(client_tpl, Config),
    Product = <<"rubberduck">>,
    Details = hg_ct_helper:make_invoice_tpl_details(Product, Cost),
    Params = hg_ct_helper:make_invoice_tpl_update_params(#{details => Details}),
    hg_client_invoice_templating:update(TplID, Params, Client).

delete_invoice_tpl(TplID, Config) ->
    hg_client_invoice_templating:delete(TplID, cfg(client_tpl, Config)).

make_wallet_payment_params(PmtSrv) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(digital_wallet, PmtSrv),
    make_payment_params(PaymentTool, Session, instant).

make_tds_payment_params(FlowType, PmtSys) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(preauth_3ds, PmtSys),
    make_payment_params(PaymentTool, Session, FlowType).

make_customer_payment_params(CustomerID) ->
    #payproc_InvoicePaymentParams{
        payer =
            {customer, #payproc_CustomerPayerParams{
                customer_id = CustomerID
            }},
        flow = {instant, #payproc_InvoicePaymentParamsFlowInstant{}}
    }.

make_scenario_payment_params(Scenario, PmtSys) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool({scenario, Scenario}, PmtSys),
    make_payment_params(PaymentTool, Session, instant).

make_scenario_payment_params(Scenario, FlowType, PmtSys) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool({scenario, Scenario}, PmtSys),
    make_payment_params(PaymentTool, Session, FlowType).

make_payment_params(PmtSys) ->
    make_payment_params(PmtSys, instant).

make_payment_params(PmtSys, FlowType) ->
    {PaymentTool, Session} = hg_dummy_provider:make_payment_tool(no_preauth, PmtSys),
    make_payment_params(PaymentTool, Session, FlowType).

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
                contact_info = ?contact_info()
            }},
        flow = Flow
    }.

make_chargeback_cancel_params() ->
    #payproc_InvoicePaymentChargebackCancelParams{}.

make_chargeback_reject_params(Levy) ->
    #payproc_InvoicePaymentChargebackRejectParams{
        levy = Levy
    }.

make_chargeback_accept_params() ->
    #payproc_InvoicePaymentChargebackAcceptParams{}.

make_chargeback_accept_params(Levy, Body) ->
    #payproc_InvoicePaymentChargebackAcceptParams{
        body = Body,
        levy = Levy
    }.

make_chargeback_reopen_params(Levy) ->
    #payproc_InvoicePaymentChargebackReopenParams{
        levy = Levy
    }.

make_chargeback_reopen_params(Levy, Body) ->
    #payproc_InvoicePaymentChargebackReopenParams{
        body = Body,
        levy = Levy
    }.

make_chargeback_reopen_params_move_to_stage(Levy, Stage) ->
    #payproc_InvoicePaymentChargebackReopenParams{
        levy = Levy,
        move_to_stage = Stage
    }.

make_chargeback_params(Levy) ->
    #payproc_InvoicePaymentChargebackParams{
        id = hg_utils:unique_id(),
        reason = #domain_InvoicePaymentChargebackReason{
            code = <<"CB.C0DE">>,
            category = {fraud, #domain_InvoicePaymentChargebackCategoryFraud{}}
        },
        levy = Levy,
        occurred_at = hg_datetime:format_now()
    }.

make_chargeback_params(Levy, Body) ->
    #payproc_InvoicePaymentChargebackParams{
        id = hg_utils:unique_id(),
        reason = #domain_InvoicePaymentChargebackReason{
            code = <<"CB.C0DE">>,
            category = {fraud, #domain_InvoicePaymentChargebackCategoryFraud{}}
        },
        body = Body,
        levy = Levy,
        occurred_at = hg_datetime:format_now()
    }.

make_manual_refund_params() ->
    make_manual_refund_params(?trx_info(<<"test">>, #{})).

make_manual_refund_params(TrxInfo) ->
    #payproc_InvoicePaymentRefundParams{
        reason = <<"manual">>,
        transaction_info = TrxInfo
    }.

make_refund_params() ->
    #payproc_InvoicePaymentRefundParams{
        reason = <<"ZANOZED">>
    }.

make_refund_params(Amount, Currency) ->
    #payproc_InvoicePaymentRefundParams{
        reason = <<"ZANOZED">>,
        cash = make_cash(Amount, Currency)
    }.

make_refund_params(Amount, Currency, Cart) ->
    #payproc_InvoicePaymentRefundParams{
        reason = <<"ZANOZED">>,
        cash = make_cash(Amount, Currency),
        cart = Cart
    }.

make_refund_params(Amount, Currency, Cart, Allocation) ->
    #payproc_InvoicePaymentRefundParams{
        reason = <<"ZANOZED">>,
        cash = make_cash(Amount, Currency),
        cart = Cart,
        allocation = Allocation
    }.

make_adjustment_params() ->
    make_adjustment_params(<<>>).

make_adjustment_params(Reason) ->
    make_adjustment_params(Reason, undefined).

make_adjustment_params(Reason, Revision) ->
    #payproc_InvoicePaymentAdjustmentParams{
        reason = Reason,
        scenario =
            {cash_flow, #domain_InvoicePaymentAdjustmentCashFlow{
                domain_revision = Revision
            }}
    }.

make_status_adjustment_params(Status) ->
    make_status_adjustment_params(Status, <<>>).

make_status_adjustment_params(Status, Reason) ->
    #payproc_InvoicePaymentAdjustmentParams{
        reason = Reason,
        scenario =
            {status_change, #domain_InvoicePaymentAdjustmentStatusChange{
                target_status = Status
            }}
    }.

make_due_date(LifetimeSeconds) ->
    genlib_time:unow() + LifetimeSeconds.

create_invoice(InvoiceParams, Client) ->
    ?invoice_state(?invoice(InvoiceID)) = hg_client_invoicing:create(InvoiceParams, Client),
    InvoiceID.

repair_invoice(InvoiceID, Changes, Client) ->
    repair_invoice(InvoiceID, Changes, undefined, undefined, Client).

repair_invoice(InvoiceID, Changes, Action, Params, Client) ->
    hg_client_invoicing:repair(InvoiceID, Changes, Action, Params, Client).

create_repair_scenario(fail_pre_processing) ->
    Failure = payproc_errors:construct('PaymentFailure', {no_route_found, {unknown, ?err_gen_failure()}}),
    {'fail_pre_processing', #'payproc_InvoiceRepairFailPreProcessing'{failure = Failure}};
create_repair_scenario(skip_inspector) ->
    {'skip_inspector', #'payproc_InvoiceRepairSkipInspector'{risk_score = low}};
create_repair_scenario({fail_session, Failure}) ->
    {'fail_session', #'payproc_InvoiceRepairFailSession'{failure = Failure}};
create_repair_scenario(fulfill_session) ->
    {'fulfill_session', #'payproc_InvoiceRepairFulfillSession'{}};
create_repair_scenario({fulfill_session, Trx}) ->
    {'fulfill_session', #'payproc_InvoiceRepairFulfillSession'{trx = Trx}};
create_repair_scenario(Scenarios) when is_list(Scenarios) ->
    {'complex', #'payproc_InvoiceRepairComplex'{scenarios = [create_repair_scenario(S) || S <- Scenarios]}}.

repair_invoice_with_scenario(InvoiceID, Scenario, Client) ->
    hg_client_invoicing:repair_scenario(InvoiceID, create_repair_scenario(Scenario), Client).

start_invoice(Product, Due, Amount, C) ->
    start_invoice(cfg(shop_id, C), Product, Due, Amount, C).

start_invoice(ShopID, Product, Due, Amount, C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    start_invoice(PartyID, ShopID, Product, Due, Amount, Client).

start_invoice(PartyID, ShopID, Product, Due, Amount, Client) ->
    InvoiceParams = make_invoice_params(PartyID, ShopID, Product, Due, make_cash(Amount)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid())) = next_change(InvoiceID, Client),
    InvoiceID.

start_payment(InvoiceID, PaymentParams, Client) ->
    ?payment_state(?payment(PaymentID)) = hg_client_invoicing:start_payment(InvoiceID, PaymentParams, Client),
    _ = start_payment_ev(InvoiceID, Client),
    ?payment_ev(PaymentID, ?cash_flow_changed(_)) =
        next_change(InvoiceID, Client),
    PaymentID.

register_payment(InvoiceID, RegisterPaymentParams, WithRiskScoring, Client) ->
    ?payment_state(?payment(PaymentID)) =
        hg_client_invoicing:register_payment(InvoiceID, RegisterPaymentParams, Client),
    _ =
        case WithRiskScoring of
            true ->
                start_payment_ev(InvoiceID, Client);
            false ->
                start_payment_ev_no_risk_scoring(InvoiceID, Client)
        end,
    ?payment_ev(PaymentID, ?cash_flow_changed(_)) =
        next_change(InvoiceID, Client),
    PaymentID.

start_payment_ev(InvoiceID, Client) ->
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))),
        ?payment_ev(PaymentID, ?risk_score_changed(_RiskScore)),
        ?payment_ev(PaymentID, ?route_changed(Route))
    ] = next_changes(InvoiceID, 3, Client),
    Route.

start_payment_ev_no_risk_scoring(InvoiceID, Client) ->
    [
        ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))),
        ?payment_ev(PaymentID, ?route_changed(Route))
    ] = next_changes(InvoiceID, 2, Client),
    Route.

process_payment(InvoiceID, PaymentParams, Client) ->
    PaymentID = start_payment(InvoiceID, PaymentParams, Client),
    PaymentID = await_payment_session_started(InvoiceID, PaymentID, Client, ?processed()),
    PaymentID = await_payment_process_finish(InvoiceID, PaymentID, Client).

await_payment_started(InvoiceID, PaymentID, Client) ->
    ?payment_ev(PaymentID, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID, Client),
    PaymentID.

await_payment_cash_flow(InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?risk_score_changed(_)),
        ?payment_ev(PaymentID, ?route_changed(Route)),
        ?payment_ev(PaymentID, ?cash_flow_changed(CashFlow))
    ] = next_changes(InvoiceID, 3, Client),
    {CashFlow, Route}.

await_payment_cash_flow(RS, Route, InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?risk_score_changed(RS)),
        ?payment_ev(PaymentID, ?route_changed(Route)),
        ?payment_ev(PaymentID, ?cash_flow_changed(CashFlow))
    ] = next_changes(InvoiceID, 3, Client),
    CashFlow.

await_payment_rollback(InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?risk_score_changed(_)),
        ?payment_ev(PaymentID, ?route_changed(_, _)),
        ?payment_ev(PaymentID, ?payment_rollback_started({failure, Failure}))
    ] = next_changes(InvoiceID, 3, Client),
    Failure.

await_payment_session_started(InvoiceID, PaymentID, Client, Target) ->
    ?payment_ev(PaymentID, ?session_ev(Target, ?session_started())) =
        next_change(InvoiceID, Client),
    PaymentID.

await_payment_process_interaction(InvoiceID, PaymentID, Client) ->
    ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID, Client),
    ?payment_ev(
        PaymentID,
        ?session_ev(?processed(), ?interaction_changed(UserInteraction, ?interaction_requested))
    ) =
        next_change(InvoiceID, Client),
    UserInteraction.

await_payment_process_finish(InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?trx_bound(?trx_info(_)))),
        ?payment_ev(PaymentID, ?session_ev(?processed(), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?processed()))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID.

await_payment_process_interaction_completion(InvoiceID, PaymentID, UserInteraction, Client) ->
    ?payment_ev(
        PaymentID,
        ?session_ev(
            ?processed(),
            ?interaction_changed(UserInteraction, ?interaction_completed)
        )
    ) = next_change(InvoiceID, Client),
    ok.

await_payment_capture(InvoiceID, PaymentID, Client) ->
    await_payment_capture(InvoiceID, PaymentID, ?timeout_reason(), Client).

await_payment_capture(InvoiceID, PaymentID, Reason, Client) ->
    Cost = get_payment_cost(InvoiceID, PaymentID, Client),
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cost, _, _)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost), ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client).

await_payment_partial_capture(InvoiceID, PaymentID, Reason, Cash, Client) ->
    [
        ?payment_ev(PaymentID, ?payment_capture_started(Reason, Cash, _, _Allocation)),
        ?payment_ev(PaymentID, ?cash_flow_changed(_)),
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cash), ?session_started()))
    ] = next_changes(InvoiceID, 3, Client),
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cash, Client).

await_payment_capture_finish(InvoiceID, PaymentID, Reason, Client) ->
    Cost = get_payment_cost(InvoiceID, PaymentID, Client),
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, Client).

await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, Client) ->
    await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, undefined, Client).

await_payment_capture_finish(InvoiceID, PaymentID, Reason, Cost, Cart, Client) ->
    [
        ?payment_ev(PaymentID, ?session_ev(?captured(Reason, Cost, Cart, _), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?captured(Reason, Cost, Cart, _))),
        ?invoice_status_changed(?invoice_paid())
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID.

await_payment_cancel(InvoiceID, PaymentID, Reason, Client) ->
    [
        ?payment_ev(PaymentID, ?session_ev(?cancelled_with_reason(Reason), ?session_started())),
        ?payment_ev(PaymentID, ?session_ev(?cancelled_with_reason(Reason), ?session_finished(?session_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?cancelled_with_reason(Reason)))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID.

await_payment_process_timeout(InvoiceID, PaymentID, Client) ->
    {failed, PaymentID, ?operation_timeout()} = await_payment_process_failure(InvoiceID, PaymentID, Client),
    PaymentID.

await_payment_process_failure(InvoiceID, PaymentID, Client) ->
    await_payment_process_failure(InvoiceID, PaymentID, Client, 0).

await_payment_process_failure(InvoiceID, PaymentID, Client, Restarts) ->
    await_payment_process_failure(InvoiceID, PaymentID, Client, Restarts, ?processed()).

await_payment_process_failure(InvoiceID, PaymentID, Client, Restarts, Target) ->
    PaymentID = await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts),
    [
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_finished(?session_failed(Failure)))),
        ?payment_ev(PaymentID, ?payment_rollback_started(Failure)),
        ?payment_ev(PaymentID, ?payment_status_changed(?failed(Failure)))
    ] = next_changes(InvoiceID, 3, Client),
    {failed, PaymentID, Failure}.

await_refund_created(InvoiceID, PaymentID, RefundID, Client) ->
    ?payment_ev(PaymentID, ?refund_ev(RefundID, ?refund_created(_Refund, _))) =
        next_change(InvoiceID, Client),
    PaymentID.

await_partial_manual_refund_succeeded(InvoiceID, PaymentID, RefundID, TrxInfo, Client) ->
    [
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?refund_created(_Refund, _, TrxInfo))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?session_ev(?refunded(), ?session_started()))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?session_ev(?refunded(), ?trx_bound(TrxInfo)))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?session_ev(?refunded(), ?session_finished(?session_succeeded())))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?refund_status_changed(?refund_succeeded())))
    ] = next_changes(InvoiceID, 5, Client),
    PaymentID.

await_refund_session_started(InvoiceID, PaymentID, RefundID, Client) ->
    ?payment_ev(PaymentID, ?refund_ev(RefundID, ?session_ev(?refunded(), ?session_started()))) =
        next_change(InvoiceID, Client),
    PaymentID.

await_refund_succeeded(InvoiceID, PaymentID, Client) ->
    [
        ?payment_ev(PaymentID, ?refund_ev(_, ?refund_status_changed(?refund_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?refunded()))
    ] = next_changes(InvoiceID, 2, Client),
    PaymentID.

await_refund_payment_process_finish(InvoiceID, PaymentID, Client) ->
    await_refund_payment_process_finish(InvoiceID, PaymentID, Client, 0).

await_refund_payment_process_finish(InvoiceID, PaymentID, Client, Restarts) ->
    PaymentID = await_sessions_restarts(PaymentID, ?refunded(), InvoiceID, Client, Restarts),
    [
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(?refunded(), ?trx_bound(_)))),
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(?refunded(), ?session_finished(?session_succeeded())))),
        ?payment_ev(PaymentID, ?refund_ev(_, ?refund_status_changed(?refund_succeeded())))
    ] = next_changes(InvoiceID, 3, Client),
    PaymentID.

await_refund_payment_complete(InvoiceID, PaymentID, Client) ->
    PaymentID = await_sessions_restarts(PaymentID, ?refunded(), InvoiceID, Client, 0),
    [
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(?refunded(), ?trx_bound(_)))),
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(?refunded(), ?session_finished(?session_succeeded())))),
        ?payment_ev(PaymentID, ?refund_ev(_, ?refund_status_changed(?refund_succeeded()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?refunded()))
    ] = next_changes(InvoiceID, 4, Client),
    PaymentID.

await_sessions_restarts(PaymentID, _Target, _InvoiceID, _Client, 0) ->
    PaymentID;
await_sessions_restarts(PaymentID, ?refunded() = Target, InvoiceID, Client, Restarts) when Restarts > 0 ->
    [
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(Target, ?session_finished(?session_failed(_))))),
        ?payment_ev(PaymentID, ?refund_ev(_, ?session_ev(Target, ?session_started())))
    ] = next_changes(InvoiceID, 2, Client),
    await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts - 1);
await_sessions_restarts(
    PaymentID,
    ?captured(Reason, Cost, Cart, _) = Target,
    InvoiceID,
    Client,
    Restarts
) when Restarts > 0 ->
    ?payment_ev(
        PaymentID,
        ?session_ev(
            ?captured(Reason, Cost, Cart, _),
            ?session_finished(?session_failed(_))
        )
    ) =
        next_change(InvoiceID, Client),
    ?payment_ev(
        PaymentID,
        ?session_ev(?captured(Reason, Cost, Cart, _), ?session_started())
    ) =
        next_change(InvoiceID, Client),
    await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts - 1);
await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts) when Restarts > 0 ->
    [
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_finished(?session_failed(_)))),
        ?payment_ev(PaymentID, ?session_ev(Target, ?session_started()))
    ] = next_changes(InvoiceID, 2, Client),
    await_sessions_restarts(PaymentID, Target, InvoiceID, Client, Restarts - 1).

assert_success_post_request(Req) ->
    {ok, 200, _RespHeaders, _RespBody} = post_request(Req).

assert_invalid_post_request(Req) ->
    {ok, 400, _RespHeaders, _RespBody} = post_request(Req).

post_request({URL, Form}) ->
    Method = post,
    Headers = [],
    Body = {form, maps:to_list(Form)},
    hackney:request(Method, URL, Headers, Body, [{with_body, true}]).

get_post_request(?redirect(URL, Form)) ->
    {URL, Form};
get_post_request(?payterm_receipt(SPID)) ->
    URL = hg_dummy_provider:get_callback_url(),
    {URL, #{<<"tag">> => SPID}}.

make_customer_w_rec_tool(PartyID, ShopID, Client, PmtSys) ->
    CustomerParams = hg_ct_helper:make_customer_params(PartyID, ShopID, <<"InvoicingTests">>),
    #payproc_Customer{id = CustomerID} =
        hg_client_customer:create(CustomerParams, Client),
    #payproc_CustomerBinding{id = BindingID} =
        hg_client_customer:start_binding(
            CustomerID,
            hg_ct_helper:make_customer_binding_params(hg_dummy_provider:make_payment_tool(no_preauth, PmtSys)),
            Client
        ),
    ok = wait_for_binding_success(CustomerID, BindingID, Client),
    CustomerID.

wait_for_binding_success(CustomerID, BindingID, Client) ->
    wait_for_binding_success(CustomerID, BindingID, 20000, Client).

wait_for_binding_success(CustomerID, BindingID, TimeLeft, Client) when TimeLeft > 0 ->
    Target = ?customer_binding_changed(BindingID, ?customer_binding_status_changed(?customer_binding_succeeded())),
    Started = genlib_time:ticks(),
    Event = hg_client_customer:pull_event(CustomerID, Client),
    R =
        case Event of
            {ok, ?customer_event(Changes)} ->
                lists:member(Target, Changes);
            _ ->
                false
        end,
    case R of
        true ->
            ok;
        false ->
            timer:sleep(200),
            Now = genlib_time:ticks(),
            TimeLeftNext = TimeLeft - (Now - Started) div 1000,
            wait_for_binding_success(CustomerID, BindingID, TimeLeftNext, Client)
    end;
wait_for_binding_success(_, _, _, _) ->
    timeout.

invoice_create_and_get_revision(PartyID, Client, ShopID) ->
    InvoiceParams = make_invoice_params(PartyID, ShopID, <<"somePlace">>, make_due_date(10), make_cash(5000)),
    InvoiceID = create_invoice(InvoiceParams, Client),
    ?invoice_created(?invoice_w_status(?invoice_unpaid()) = ?invoice_w_revision(InvoiceRev)) =
        next_change(InvoiceID, Client),
    {InvoiceRev, InvoiceID}.

execute_payment(InvoiceID, Params, Client) ->
    PaymentID = process_payment(InvoiceID, Params, Client),
    PaymentID = await_payment_capture(InvoiceID, PaymentID, Client),
    PaymentID.

execute_payment_adjustment(InvoiceID, PaymentID, Params, Client) ->
    ?adjustment(AdjustmentID, ?adjustment_pending()) =
        Adjustment = hg_client_invoicing:create_payment_adjustment(InvoiceID, PaymentID, Params, Client),
    [
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_created(Adjustment))),
        ?payment_ev(PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_processed()))),
        ?payment_ev(
            PaymentID, ?adjustment_ev(AdjustmentID, ?adjustment_status_changed(?adjustment_captured(_)))
        )
    ] = next_changes(InvoiceID, 3, Client),
    AdjustmentID.

execute_payment_refund(InvoiceID, PaymentID, #payproc_InvoicePaymentRefundParams{cash = undefined} = Params, Client) ->
    execute_payment_refund_complete(InvoiceID, PaymentID, Params, Client);
execute_payment_refund(InvoiceID, PaymentID, Params, Client) ->
    ?refund_id(RefundID) = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, Params, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_payment_process_finish(InvoiceID, PaymentID, Client),
    RefundID.

execute_payment_manual_refund(InvoiceID, PaymentID, Params, Client) ->
    ?refund_id(RefundID) = hg_client_invoicing:refund_payment_manual(InvoiceID, PaymentID, Params, Client),
    [
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?refund_created(_Refund, _, TrxInfo))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?session_ev(?refunded(), ?session_started()))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?session_ev(?refunded(), ?trx_bound(TrxInfo)))),
        ?payment_ev(PaymentID, ?refund_ev(RefundID, ?session_ev(?refunded(), ?session_finished(?session_succeeded()))))
    ] = next_changes(InvoiceID, 4, Client),
    _ = await_refund_succeeded(InvoiceID, PaymentID, Client),
    RefundID.

execute_payment_refund_complete(InvoiceID, PaymentID, Params, Client) ->
    ?refund_id(RefundID) = hg_client_invoicing:refund_payment(InvoiceID, PaymentID, Params, Client),
    PaymentID = await_refund_created(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_session_started(InvoiceID, PaymentID, RefundID, Client),
    PaymentID = await_refund_payment_complete(InvoiceID, PaymentID, Client),
    RefundID.

execute_payment_chargeback(InvoiceID, PaymentID, Params, Client) ->
    Chargeback =
        #domain_InvoicePaymentChargeback{id = ChargebackID} =
        hg_client_invoicing:create_chargeback(InvoiceID, PaymentID, Params, Client),
    [
        ?payment_ev(PaymentID, ?chargeback_ev(ChargebackID, ?chargeback_created(Chargeback))),
        ?payment_ev(PaymentID, ?chargeback_ev(ChargebackID, ?chargeback_cash_flow_changed(_)))
    ] = next_changes(InvoiceID, 2, Client),
    AcceptParams = make_chargeback_accept_params(),
    ok = hg_client_invoicing:accept_chargeback(InvoiceID, PaymentID, ChargebackID, AcceptParams, Client),
    [
        ?payment_ev(
            PaymentID,
            ?chargeback_ev(ChargebackID, ?chargeback_target_status_changed(?chargeback_status_accepted()))
        ),
        ?payment_ev(PaymentID, ?chargeback_ev(ChargebackID, ?chargeback_status_changed(?chargeback_status_accepted()))),
        ?payment_ev(PaymentID, ?payment_status_changed(?charged_back()))
    ] = next_changes(InvoiceID, 3, Client),
    ChargebackID.

make_payment_adjustment_and_get_revision(InvoiceID, PaymentID, Client) ->
    Params = make_adjustment_params(Reason = <<"imdrunk">>),
    AdjustmentID = execute_payment_adjustment(InvoiceID, PaymentID, Params, Client),
    ?adjustment_revision(AdjustmentRev) =
        ?adjustment_reason(Reason) =
        ?adjustment(AdjustmentID) = hg_client_invoicing:get_payment_adjustment(
            InvoiceID,
            PaymentID,
            AdjustmentID,
            Client
        ),
    AdjustmentRev.

make_payment_refund_and_get_revision(InvoiceID, PaymentID, Client) ->
    RefundID = execute_payment_refund(InvoiceID, PaymentID, make_refund_params(), Client),
    #domain_InvoicePaymentRefund{party_revision = RefundRev} = hg_client_invoicing:get_payment_refund(
        InvoiceID,
        PaymentID,
        RefundID,
        Client
    ),
    RefundRev.

payment_risk_score_check(Cat, C, PmtSys) ->
    Client = cfg(client, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(Cat),
        <<"RUB">>,
        ?tmpl(2),
        ?pinst(2),
        PartyClient
    ),
    InvoiceID1 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 42000, C),
    % Invoice
    PaymentParams = make_payment_params(PmtSys),
    ?payment_state(?payment(PaymentID1)) = hg_client_invoicing:start_payment(InvoiceID1, PaymentParams, Client),
    ?payment_ev(PaymentID1, ?payment_started(?payment_w_status(?pending()))) =
        next_change(InvoiceID1, Client),
    % default low risk score...
    _ = await_payment_cash_flow(low, ?route(?prv(2), ?trm(7)), InvoiceID1, PaymentID1, Client),
    ?payment_ev(PaymentID1, ?session_ev(?processed(), ?session_started())) =
        next_change(InvoiceID1, Client),
    PaymentID1 = await_payment_process_finish(InvoiceID1, PaymentID1, Client),
    PaymentID1 = await_payment_capture(InvoiceID1, PaymentID1, Client).

-spec payment_customer_risk_score_check(config()) -> test_return().
payment_customer_risk_score_check(C) ->
    Client = cfg(client, C),
    PartyID = cfg(party_id, C),
    PartyClient = cfg(party_client, C),
    ShopID = hg_ct_helper:create_battle_ready_shop(
        cfg(party_id, C),
        ?cat(1),
        <<"RUB">>,
        ?tmpl(1),
        ?pinst(1),
        PartyClient
    ),
    InvoiceID1 = start_invoice(ShopID, <<"rubberduck">>, make_due_date(10), 100000001, C),
    CustomerID = make_customer_w_rec_tool(PartyID, ShopID, cfg(customer_client, C), ?pmt_sys(<<"visa-ref">>)),
    PaymentParams = make_customer_payment_params(CustomerID),
    ?payment_state(?payment(PaymentID1)) = hg_client_invoicing:start_payment(InvoiceID1, PaymentParams, Client),
    [
        ?payment_ev(PaymentID1, ?payment_started(?payment_w_status(?pending()))),
        ?payment_ev(PaymentID1, ?risk_score_changed(fatal)),
        ?payment_ev(PaymentID1, ?payment_status_changed(?failed(Failure)))
    ] = next_changes(InvoiceID1, 3, Client),
    {failure, #domain_Failure{
        code = <<"no_route_found">>,
        sub = #domain_SubFailure{code = <<"risk_score_is_too_high">>}
    }} = Failure.

%

get_payment_cost(InvoiceID, PaymentID, Client) ->
    #payproc_InvoicePayment{
        payment = #domain_InvoicePayment{cost = Cost}
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    Cost.

get_payment_cashflow_mapped(InvoiceID, PaymentID, Client) ->
    #payproc_InvoicePayment{
        cash_flow = CashFlow
    } = hg_client_invoicing:get_payment(InvoiceID, PaymentID, Client),
    [
        {Source, Dest, Volume}
     || #domain_FinalCashFlowPosting{
            source = #domain_FinalCashFlowAccount{account_type = Source},
            destination = #domain_FinalCashFlowAccount{account_type = Dest},
            volume = #domain_Cash{amount = Volume}
        } <- CashFlow
    ].

%
-spec construct_domain_fixture() -> [hg_domain:object()].
construct_domain_fixture() ->
    TestTermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies =
                {value,
                    ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
            categories =
                {value,
                    ?ordset([
                        ?cat(1),
                        ?cat(8)
                    ])},
            payment_methods =
                {decisions, [
                    #domain_PaymentMethodDecision{
                        if_ = ?partycond(<<"DEPRIVED ONE">>, undefined),
                        then_ = {value, ordsets:new()}
                    },
                    #domain_PaymentMethodDecision{
                        if_ = ?partycond(<<"DEPRIVED ONE-II">>, undefined),
                        then_ = {value, ordsets:new()}
                    },
                    #domain_PaymentMethodDecision{
                        if_ = {constant, true},
                        then_ =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"jcb-ref">>)),
                                    ?pmt(payment_terminal, ?pmt_srv(<<"euroset-ref">>)),
                                    ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                                    ?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?token_bank_card(<<"visa-ref">>, <<"applepay-ref">>)),
                                    ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
                                    ?pmt(mobile, ?mob(<<"mts-ref">>))
                                ])}
                    }
                ]},
            cash_limit =
                {decisions, [
                    #domain_CashLimitDecision{
                        if_ =
                            {condition,
                                {payment_tool,
                                    {crypto_currency, #domain_CryptoCurrencyCondition{
                                        definition = {crypto_currency_is, ?crypta(<<"bitcoin-ref">>)}
                                    }}}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(10, <<"RUB">>)},
                                    {inclusive, ?cash(4200000000, <<"RUB">>)}
                                )}
                    },
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(10, <<"RUB">>)},
                                    {exclusive, ?cash(420000000, <<"RUB">>)}
                                )}
                    }
                ]},
            fees =
                {decisions, [
                    #domain_CashFlowDecision{
                        if_ =
                            {condition,
                                {payment_tool,
                                    {bank_card, #domain_BankCardCondition{
                                        definition = {category_is, ?bc_cat(1)}
                                    }}}},
                        then_ =
                            {value, [
                                ?cfpost(
                                    {merchant, settlement},
                                    {system, settlement},
                                    ?merchant_to_system_share_2
                                )
                            ]}
                    },
                    #domain_CashFlowDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value, [
                                ?cfpost(
                                    {merchant, settlement},
                                    {system, settlement},
                                    ?merchant_to_system_share_1
                                )
                            ]}
                    }
                ]},
            holds = #domain_PaymentHoldsServiceTerms{
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                            ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                        ])},
                lifetime =
                    {decisions, [
                        #domain_HoldLifetimeDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ = {value, #domain_HoldLifetime{seconds = 10}}
                        }
                    ]}
            },
            refunds = #domain_PaymentRefundsServiceTerms{
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                            ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                        ])},
                fees =
                    {value, [
                        ?cfpost(
                            {merchant, settlement},
                            {system, settlement},
                            ?fixed(100, <<"RUB">>)
                        )
                    ]},
                eligibility_time = {value, #base_TimeSpan{minutes = 1}},
                partial_refunds = #domain_PartialRefundsServiceTerms{
                    cash_limit =
                        {decisions, [
                            #domain_CashLimitDecision{
                                if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                                then_ =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(1000, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        ]}
                }
            },
            allocations = #domain_PaymentAllocationServiceTerms{
                allow = {constant, true}
            },
            attempt_limit = {value, #domain_AttemptLimit{attempts = 2}}
        },
        recurrent_paytools = #domain_RecurrentPaytoolsServiceTerms{
            payment_methods =
                {value,
                    ordsets:from_list([
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                        ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                    ])}
        }
    },
    DefaultTermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies =
                {value,
                    ?ordset([
                        ?cur(<<"RUB">>),
                        ?cur(<<"USD">>)
                    ])},
            categories =
                {value,
                    ?ordset([
                        ?cat(2),
                        ?cat(3),
                        ?cat(4),
                        ?cat(5),
                        ?cat(6),
                        ?cat(7)
                    ])},
            payment_methods =
                {value,
                    ?ordset([
                        ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                        ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                        ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                    ])},
            cash_limit =
                {decisions, [
                    % проверяем, что условие никогда не отрабатывает
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(200, <<"USD">>)},
                                    {exclusive, ?cash(313370, <<"USD">>)}
                                )}
                    },
                    #domain_CashLimitDecision{
                        if_ =
                            {condition,
                                {payment_tool,
                                    {bank_card, #domain_BankCardCondition{
                                        definition = {empty_cvv_is, true}
                                    }}}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(0, <<"RUB">>)},
                                    {inclusive, ?cash(0, <<"RUB">>)}
                                )}
                    },
                    #domain_CashLimitDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(10, <<"RUB">>)},
                                    {exclusive, ?cash(4200000, <<"RUB">>)}
                                )}
                    }
                ]},
            fees =
                {decisions, [
                    #domain_CashFlowDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ =
                            {value, [
                                ?cfpost(
                                    {merchant, settlement},
                                    {system, settlement},
                                    ?share(45, 1000, operation_amount)
                                )
                            ]}
                    },
                    #domain_CashFlowDecision{
                        if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                        then_ =
                            {value, [
                                ?cfpost(
                                    {merchant, settlement},
                                    {system, settlement},
                                    ?share(65, 1000, operation_amount)
                                )
                            ]}
                    }
                ]},
            holds = #domain_PaymentHoldsServiceTerms{
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                            ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                        ])},
                lifetime =
                    {decisions, [
                        #domain_HoldLifetimeDecision{
                            if_ =
                                {condition,
                                    {payment_tool,
                                        {bank_card, #domain_BankCardCondition{
                                            definition =
                                                {payment_system, #domain_PaymentSystemCondition{
                                                    payment_system_is = ?pmt_sys(<<"mastercard-ref">>)
                                                }}
                                        }}}},
                            then_ = {value, ?hold_lifetime(120)}
                        },
                        #domain_HoldLifetimeDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ = {value, #domain_HoldLifetime{seconds = 3}}
                        }
                    ]}
            },
            chargebacks = #domain_PaymentChargebackServiceTerms{
                allow = {constant, true},
                fees =
                    {value, [
                        ?cfpost(
                            {merchant, settlement},
                            {system, settlement},
                            ?share(1, 1, surplus)
                        )
                    ]}
            },
            refunds = #domain_PaymentRefundsServiceTerms{
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                            ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                        ])},
                fees = {value, []},
                eligibility_time = {value, #base_TimeSpan{minutes = 1}},
                partial_refunds = #domain_PartialRefundsServiceTerms{
                    cash_limit =
                        {value,
                            ?cashrng(
                                {inclusive, ?cash(1000, <<"RUB">>)},
                                {exclusive, ?cash(40000, <<"RUB">>)}
                            )}
                }
            }
        }
    },
    [
        hg_ct_fixture:construct_bank_card_category(
            ?bc_cat(1),
            <<"Bank card category">>,
            <<"Corporative">>,
            [<<"*CORPORAT*">>]
        ),
        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),
        hg_ct_fixture:construct_currency(?cur(<<"USD">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),
        hg_ct_fixture:construct_category(?cat(2), <<"Generic Store">>, live),
        hg_ct_fixture:construct_category(?cat(3), <<"Guns & Booze">>, live),
        hg_ct_fixture:construct_category(?cat(4), <<"Offliner">>, live),
        hg_ct_fixture:construct_category(?cat(5), <<"Timeouter">>, live),
        hg_ct_fixture:construct_category(?cat(6), <<"MachineFailer">>, live),
        hg_ct_fixture:construct_category(?cat(7), <<"TempFailer">>, live),

        %% categories influents in limits choice
        hg_ct_fixture:construct_category(?cat(8), <<"commit success">>),

        hg_ct_fixture:construct_payment_method(?pmt(mobile, ?mob(<<"mts-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?bank_card(<<"jcb-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(payment_terminal, ?pmt_srv(<<"euroset-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>))),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, ?token_bank_card(<<"visa-ref">>, <<"applepay-ref">>))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_inspector(?insp(1), <<"Rejector">>, ?prx(2), #{<<"risk_score">> => <<"low">>}),
        hg_ct_fixture:construct_inspector(?insp(2), <<"Skipper">>, ?prx(2), #{<<"risk_score">> => <<"high">>}),
        hg_ct_fixture:construct_inspector(?insp(3), <<"Fatalist">>, ?prx(2), #{<<"risk_score">> => <<"fatal">>}),
        hg_ct_fixture:construct_inspector(
            ?insp(4),
            <<"Offliner">>,
            ?prx(2),
            #{<<"link_state">> => <<"unexpected_failure">>},
            low
        ),
        hg_ct_fixture:construct_inspector(
            ?insp(5),
            <<"Offliner">>,
            ?prx(2),
            #{<<"link_state">> => <<"timeout">>},
            low
        ),
        hg_ct_fixture:construct_inspector(
            ?insp(6),
            <<"Offliner">>,
            ?prx(2),
            #{<<"link_state">> => <<"unexpected_failure">>}
        ),
        hg_ct_fixture:construct_inspector(
            ?insp(7),
            <<"TempFailer">>,
            ?prx(2),
            #{<<"link_state">> => <<"temporary_failure">>}
        ),

        hg_ct_fixture:construct_contract_template(?tmpl(1), ?trms(1)),
        hg_ct_fixture:construct_contract_template(?tmpl(2), ?trms(2)),
        hg_ct_fixture:construct_contract_template(?tmpl(3), ?trms(3)),

        hg_ct_fixture:construct_system_account_set(?sas(1)),
        hg_ct_fixture:construct_system_account_set(?sas(2)),
        hg_ct_fixture:construct_external_account_set(?eas(1)),
        hg_ct_fixture:construct_external_account_set(?eas(2), <<"Assist">>, ?cur(<<"RUB">>)),

        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(1),
            <<"SubMain">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(1)),
                ?candidate({constant, true}, ?trm(10)),
                ?candidate({constant, true}, ?trm(11))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(2),
            <<"Main">>,
            {delegates, [
                ?delegate(
                    <<"Important merch">>,
                    {condition, {party, #domain_PartyCondition{id = <<"bIg merch">>}}},
                    ?ruleset(1)
                ),
                ?delegate(
                    <<"Provider with turnover limit">>,
                    {condition, {party, #domain_PartyCondition{id = ?PARTY_ID_WITH_LIMIT}}},
                    ?ruleset(4)
                ),
                ?delegate(
                    <<"Provider cascading with turnover limit">>,
                    {condition, {party, #domain_PartyCondition{id = ?PARTY_ID_WITH_SEVERAL_LIMITS}}},
                    ?ruleset(6)
                ),
                ?delegate(<<"Common">>, {constant, true}, ?ruleset(1))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(4),
            <<"SubMain">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(12))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(6),
            <<"SubMain">>,
            {candidates, [
                ?candidate(<<"Middle priority">>, {constant, true}, ?trm(13), 1005),
                ?candidate(<<"High priority">>, {constant, true}, ?trm(12), 1010),
                ?candidate({constant, true}, ?trm(14))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(
            ?ruleset(5),
            <<"SubMain">>,
            {candidates, [
                ?candidate({constant, true}, ?trm(1)),
                ?candidate({constant, true}, ?trm(7))
            ]}
        ),
        hg_ct_fixture:construct_payment_routing_ruleset(?ruleset(3), <<"Prohibitions">>, {candidates, []}),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                default_contract_template = {value, ?tmpl(1)},
                providers =
                    {value,
                        ?ordset([
                            ?prv(1),
                            ?prv(2),
                            ?prv(3),
                            ?prv(4),
                            ?prv(5)
                        ])},
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(3)
                },
                % TODO do we realy need this decision hell here?
                inspector =
                    {decisions, [
                        #domain_InspectorDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {decisions, [
                                    #domain_InspectorDecision{
                                        if_ = {condition, {category_is, ?cat(3)}},
                                        then_ = {value, ?insp(2)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ = {condition, {category_is, ?cat(4)}},
                                        then_ = {value, ?insp(4)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(0, <<"RUB">>)},
                                                        {exclusive, ?cash(500000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(1)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(500000, <<"RUB">>)},
                                                        {exclusive, ?cash(100000000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(2)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(100000000, <<"RUB">>)},
                                                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(3)}
                                    }
                                ]}
                        }
                    ]},
                residences = [],
                realm = test
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(2),
            data = #domain_PaymentInstitution{
                name = <<"Chetky Payments Inc.">>,
                system_account_set = {value, ?sas(2)},
                default_contract_template = {value, ?tmpl(2)},
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(5),
                    prohibitions = ?ruleset(3)
                },
                providers =
                    {value,
                        ?ordset([
                            ?prv(1),
                            ?prv(2),
                            ?prv(3)
                        ])},
                inspector =
                    {decisions, [
                        #domain_InspectorDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ =
                                {decisions, [
                                    #domain_InspectorDecision{
                                        if_ = {condition, {category_is, ?cat(3)}},
                                        then_ = {value, ?insp(2)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ = {condition, {category_is, ?cat(4)}},
                                        then_ = {value, ?insp(4)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ = {condition, {category_is, ?cat(5)}},
                                        then_ = {value, ?insp(5)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ = {condition, {category_is, ?cat(6)}},
                                        then_ = {value, ?insp(6)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ = {condition, {category_is, ?cat(7)}},
                                        then_ = {value, ?insp(7)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(0, <<"RUB">>)},
                                                        {exclusive, ?cash(500000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(1)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(500000, <<"RUB">>)},
                                                        {exclusive, ?cash(100000000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(2)}
                                    },
                                    #domain_InspectorDecision{
                                        if_ =
                                            {condition,
                                                {cost_in,
                                                    ?cashrng(
                                                        {inclusive, ?cash(100000000, <<"RUB">>)},
                                                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                                                    )}},
                                        then_ = {value, ?insp(3)}
                                    }
                                ]}
                        }
                    ]},
                residences = [],
                realm = live
            }
        }},

        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set =
                    {decisions, [
                        #domain_ExternalAccountSetDecision{
                            if_ =
                                {condition,
                                    {party, #domain_PartyCondition{
                                        id = ?PARTYID_EXTERNAL
                                    }}},
                            then_ = {value, ?eas(2)}
                        },
                        #domain_ExternalAccountSetDecision{
                            if_ = {constant, true},
                            then_ = {value, ?eas(1)}
                        }
                    ]},
                payment_institutions = ?ordset([?pinst(1), ?pinst(2)])
            }
        }},

        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = TestTermSet
                    }
                ]
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(2),
            data = #domain_TermSetHierarchy{
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = DefaultTermSet
                    }
                ]
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(3),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(1),
                term_sets = []
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"brovider">>
                    }
                },
                abs_account = <<"1234567890">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1),
                                    ?cat(2)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"jcb-ref">>)),
                                    ?pmt(bank_card, ?bank_card_no_cvv(<<"visa-ref">>)),
                                    ?pmt(crypto_currency, ?crypta(<<"bitcoin-ref">>)),
                                    ?pmt(bank_card, ?token_bank_card(<<"visa-ref">>, <<"applepay-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(1000000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {decisions, [
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {digital_wallet, #domain_DigitalWalletCondition{
                                                    definition = {payment_service_is, ?pmt_srv(<<"qiwi-ref">>)}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(18, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(18, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"mastercard-ref">>)
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(19, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"jcb-ref">>)
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(20, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"visa-ref">>),
                                                            token_service_is = ?token_srv(<<"applepay-ref">>),
                                                            tokenization_method_is = dpan
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(20, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {crypto_currency, #domain_CryptoCurrencyCondition{
                                                    definition = {crypto_currency_is, ?crypta(<<"bitcoin-ref">>)}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(20, 1000, operation_amount)
                                            )
                                        ]}
                                }
                            ]},
                        holds = #domain_PaymentHoldsProvisionTerms{
                            lifetime =
                                {decisions, [
                                    #domain_HoldLifetimeDecision{
                                        if_ =
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {payment_system, #domain_PaymentSystemCondition{
                                                                payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                            }}
                                                    }}}},
                                        then_ = {value, ?hold_lifetime(12)}
                                    }
                                ]}
                        },
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        },
                        chargebacks = #domain_PaymentChargebackProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]}
                        }
                    },
                    recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                        categories = {value, ?ordset([?cat(1), ?cat(4)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                                ])},
                        cash_value = {value, ?cash(1000, <<"RUB">>)}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(1),
            data = #domain_Terminal{
                name = <<"Brominal 1">>,
                description = <<"Brominal 1">>,
                provider_ref = ?prv(1)
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(2),
            data = #domain_Provider{
                name = <<"Drovider">>,
                description = <<"I'm out of ideas of what to write here">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"drovider">>
                    }
                },
                abs_account = <<"1234567890">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(2),
                                    ?cat(4),
                                    ?cat(5),
                                    ?cat(6)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(10000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(16, 1000, operation_amount)
                                )
                            ]},
                        holds = #domain_PaymentHoldsProvisionTerms{
                            lifetime =
                                {decisions, [
                                    #domain_HoldLifetimeDecision{
                                        if_ =
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {payment_system, #domain_PaymentSystemCondition{
                                                                payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                            }}
                                                    }}}},
                                        then_ = {value, ?hold_lifetime(5)}
                                    },
                                    #domain_HoldLifetimeDecision{
                                        if_ =
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {payment_system, #domain_PaymentSystemCondition{
                                                                payment_system_is = ?pmt_sys(<<"mastercard-ref">>)
                                                            }}
                                                    }}}},
                                        then_ = {value, ?hold_lifetime(120)}
                                    }
                                ]}
                        },
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        },
                        chargebacks = #domain_PaymentChargebackProvisionTerms{
                            fees =
                                {value, #domain_Fees{
                                    fees = #{
                                        surplus => ?fixed(?CB_PROVIDER_LEVY, <<"RUB">>)
                                    }
                                }},
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    ),
                                    ?cfpost(
                                        {system, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, surplus)
                                    )
                                ]}
                        }
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(6),
            data = #domain_Terminal{
                name = <<"Drominal 1">>,
                description = <<"Drominal 1">>,
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(2)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(5000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(16, 1000, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {external, outcome},
                                    ?fixed(20, <<"RUB">>),
                                    <<"Assist fee">>
                                )
                            ]}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(7),
            data = #domain_Terminal{
                name = <<"Terminal 7">>,
                description = <<"Terminal 7">>,
                provider_ref = #domain_ProviderRef{id = 2},
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(16, 1000, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {external, outcome},
                                    ?fixed(20, <<"RUB">>),
                                    <<"Kek">>
                                )
                            ]}
                    }
                }
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(3),
            data = #domain_Provider{
                name = <<"Crovider">>,
                description = <<"Payment terminal provider">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"crovider">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(payment_terminal, ?pmt_srv(<<"euroset-ref">>)),
                                    ?pmt(digital_wallet, ?pmt_srv(<<"qiwi-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(10000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(21, 1000, operation_amount)
                                )
                            ]}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(10),
            data = #domain_Terminal{
                name = <<"Payment Terminal Terminal">>,
                provider_ref = ?prv(3),
                description = <<"Euroset">>
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(4),
            data = #domain_Provider{
                name = <<"UnionTelecom">>,
                description = <<"Mobile commerce terminal provider">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"Union Telecom">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(mobile, ?mob(<<"mts-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(10000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(21, 1000, operation_amount)
                                )
                            ]}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(11),
            data = #domain_Terminal{
                name = <<"Parking Payment Terminal">>,
                description = <<"Mts">>,
                provider_ref = #domain_ProviderRef{id = 4},
                options = #{
                    <<"goodPhone">> => <<"7891">>,
                    <<"prefix">> => <<"1234567890">>
                }
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(5),
            data = #domain_Provider{
                name = <<"UnionTelecom">>,
                description = <<"Mobile commerce terminal provider">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"Union Telecom">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(8)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(mobile, ?mob(<<"mts-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(10000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(21, 1000, operation_amount)
                                )
                            ]},
                        holds = #domain_PaymentHoldsProvisionTerms{
                            lifetime =
                                {decisions, [
                                    #domain_HoldLifetimeDecision{
                                        if_ =
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {payment_system, #domain_PaymentSystemCondition{
                                                                payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                            }}
                                                    }}}},
                                        then_ = {value, ?hold_lifetime(12)}
                                    }
                                ]}
                        },
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        },
                        turnover_limits =
                            {value, [
                                #domain_TurnoverLimit{
                                    id = ?LIMIT_ID,
                                    upper_boundary = ?LIMIT_UPPER_BOUNDARY,
                                    domain_revision = dmt_client:get_last_version()
                                }
                            ]}
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(12),
            data = #domain_Terminal{
                name = <<"Parking Payment Terminal">>,
                description = <<"Terminal">>,
                provider_ref = #domain_ProviderRef{id = 5}
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(6),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms#domain_PaymentsProvisionTerms{
                    categories =
                        {value,
                            ?ordset([
                                ?cat(8)
                            ])},
                    payment_methods =
                        {value,
                            ?ordset([
                                ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                ?pmt(mobile, ?mob(<<"mts-ref">>))
                            ])},
                    refunds = #domain_PaymentRefundsProvisionTerms{
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {merchant, settlement},
                                    {provider, settlement},
                                    ?share(1, 1, operation_amount)
                                )
                            ]},
                        partial_refunds = #domain_PartialRefundsProvisionTerms{
                            cash_limit =
                                {value,
                                    ?cashrng(
                                        {inclusive, ?cash(10, <<"RUB">>)},
                                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                                    )}
                        }
                    },
                    turnover_limits =
                        {value, [
                            #domain_TurnoverLimit{
                                id = ?LIMIT_ID2,
                                upper_boundary = ?LIMIT_UPPER_BOUNDARY,
                                domain_revision = dmt_client:get_last_version()
                            }
                        ]}
                }
            })
        }},
        {terminal, ?terminal_obj(?trm(13), ?prv(6))},
        {provider, #domain_ProviderObject{
            ref = ?prv(7),
            data = ?provider(#domain_ProvisionTermSet{
                payments = ?payment_terms#domain_PaymentsProvisionTerms{
                    categories =
                        {value,
                            ?ordset([
                                ?cat(8)
                            ])},
                    payment_methods =
                        {value,
                            ?ordset([
                                ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                ?pmt(mobile, ?mob(<<"mts-ref">>))
                            ])},
                    refunds = #domain_PaymentRefundsProvisionTerms{
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {merchant, settlement},
                                    {provider, settlement},
                                    ?share(1, 1, operation_amount)
                                )
                            ]},
                        partial_refunds = #domain_PartialRefundsProvisionTerms{
                            cash_limit =
                                {value,
                                    ?cashrng(
                                        {inclusive, ?cash(10, <<"RUB">>)},
                                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                                    )}
                        }
                    },
                    turnover_limits =
                        {value, [
                            #domain_TurnoverLimit{
                                id = ?LIMIT_ID3,
                                upper_boundary = ?LIMIT_UPPER_BOUNDARY,
                                domain_revision = dmt_client:get_last_version()
                            }
                        ]}
                }
            })
        }},
        {terminal, ?terminal_obj(?trm(14), ?prv(7))},

        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"visa-ref">>), <<"visa payment system">>),
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"mastercard-ref">>), <<"mastercard payment system">>),
        hg_ct_fixture:construct_payment_system(?pmt_sys(<<"jcb-ref">>), <<"jcb payment system">>),
        hg_ct_fixture:construct_mobile_operator(?mob(<<"mts-ref">>), <<"mts mobile operator">>),
        hg_ct_fixture:construct_payment_service(?pmt_srv(<<"qiwi-ref">>), <<"qiwi payment service">>),
        hg_ct_fixture:construct_payment_service(?pmt_srv(<<"euroset-ref">>), <<"euroset payment service">>),
        hg_ct_fixture:construct_crypto_currency(?crypta(<<"bitcoin-ref">>), <<"bitcoin currency">>),
        hg_ct_fixture:construct_tokenized_service(?token_srv(<<"applepay-ref">>), <<"applepay tokenized service">>)
    ].

construct_term_set_for_cost(LowerBound, UpperBound) ->
    TermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            payment_methods =
                {decisions, [
                    #domain_PaymentMethodDecision{
                        if_ =
                            {condition,
                                {cost_in,
                                    ?cashrng(
                                        {inclusive, ?cash(LowerBound, <<"RUB">>)},
                                        {inclusive, ?cash(UpperBound, <<"RUB">>)}
                                    )}},
                        then_ = {value, ordsets:from_list([?pmt(bank_card, ?bank_card(<<"visa-ref">>))])}
                    },
                    #domain_PaymentMethodDecision{
                        if_ = {constant, true},
                        then_ = {value, ordsets:from_list([])}
                    }
                ]}
        }
    },
    {term_set_hierarchy, #domain_TermSetHierarchyObject{
        ref = ?trms(1),
        data = #domain_TermSetHierarchy{
            parent_terms = undefined,
            term_sets = [
                #domain_TimedTermSet{
                    action_time = #base_TimestampInterval{},
                    terms = TermSet
                }
            ]
        }
    }}.

construct_term_set_for_refund_eligibility_time(Seconds) ->
    TermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            refunds = #domain_PaymentRefundsServiceTerms{
                eligibility_time = {value, #base_TimeSpan{seconds = Seconds}}
            }
        }
    },
    [
        hg_ct_fixture:construct_contract_template(?tmpl(100), ?trms(100)),
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(100),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(2),
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = TermSet
                    }
                ]
            }
        }}
    ].

get_payment_adjustment_fixture(Revision) ->
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(3),
            data = #domain_TermSetHierarchy{
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = #domain_TermSet{
                            payments = #domain_PaymentsServiceTerms{
                                fees =
                                    {value, [
                                        ?cfpost(
                                            {merchant, settlement},
                                            {system, settlement},
                                            ?merchant_to_system_share_3
                                        )
                                    ]},
                                chargebacks = #domain_PaymentChargebackServiceTerms{
                                    allow = {constant, true},
                                    fees =
                                        {value, [
                                            ?cfpost(
                                                {merchant, settlement},
                                                {system, settlement},
                                                ?share(1, 1, surplus)
                                            )
                                        ]}
                                }
                            }
                        }
                    }
                ]
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstitution#domain_PaymentInstitution{
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(101),
                    prohibitions = ?ruleset(3)
                }
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(101),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(100))
                    ]}
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(100),
            data = #domain_Provider{
                name = <<"Adjustable">>,
                description = <<>>,
                abs_account = <<>>,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(100000000, <<"RUB">>)}
                                )},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                ])},
                        cash_flow = {value, get_payment_adjustment_provider_cashflow(initial)},
                        holds = #domain_PaymentHoldsProvisionTerms{
                            lifetime =
                                {decisions, [
                                    #domain_HoldLifetimeDecision{
                                        if_ =
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {payment_system, #domain_PaymentSystemCondition{
                                                                payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                            }}
                                                    }}}},
                                        then_ = {value, ?hold_lifetime(10)}
                                    }
                                ]}
                        },
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        },
                        chargebacks = #domain_PaymentChargebackProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]}
                        }
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(100),
            data = #domain_Terminal{
                name = <<"Adjustable Terminal">>,
                description = <<>>,
                provider_ref = ?prv(100)
            }
        }}
    ].

%

get_payment_adjustment_provider_cashflow(initial) ->
    [
        ?cfpost(
            {provider, settlement},
            {merchant, settlement},
            ?share(1, 1, operation_amount)
        ),
        ?cfpost(
            {system, settlement},
            {provider, settlement},
            ?system_to_provider_share_initial
        )
    ];
get_payment_adjustment_provider_cashflow(actual) ->
    [
        ?cfpost(
            {provider, settlement},
            {merchant, settlement},
            ?share(1, 1, operation_amount)
        ),
        ?cfpost(
            {system, settlement},
            {provider, settlement},
            ?system_to_provider_share_actual
        ),
        ?cfpost(
            {system, settlement},
            {external, outcome},
            ?system_to_external_fixed
        )
    ].

%

get_cashflow_rounding_fixture(Revision) ->
    PaymentInstituition = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstituition#domain_PaymentInstitution{
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(1)
                }
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(1),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions = {candidates, []}
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(100))
                    ]}
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(100),
            data = #domain_Provider{
                name = <<"Rounding">>,
                description = <<>>,
                abs_account = <<>>,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(100000000, <<"RUB">>)}
                                )},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                ])},
                        cash_flow =
                            {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share_with_rounding_method(1, 200000, operation_amount, round_half_towards_zero)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share_with_rounding_method(1, 200000, operation_amount, round_half_away_from_zero)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {system, subagent},
                                    ?share_with_rounding_method(1, 200000, operation_amount, round_half_away_from_zero)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {external, outcome},
                                    ?share(1, 200000, operation_amount)
                                )
                            ]},
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        }
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(100),
            data = #domain_Terminal{
                name = <<"Rounding Terminal">>,
                provider_ref = ?prv(100),
                description = <<>>
            }
        }}
    ].

%

payments_w_bank_card_issuer_conditions_fixture(Revision) ->
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstitution#domain_PaymentInstitution{
                providers =
                    {value,
                        ?ordset([
                            ?prv(100)
                        ])}
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(100),
            data = #domain_Provider{
                name = <<"VTB21">>,
                description = <<>>,
                abs_account = <<>>,
                proxy = #domain_Proxy{ref = ?prx(1), additional = #{}},
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(100000000, <<"RUB">>)}
                                )},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                ])},
                        cash_flow =
                            {decisions, [
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition = {issuer_country_is, kaz}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(25, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ = {constant, true},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(19, 1000, operation_amount)
                                            )
                                        ]}
                                }
                            ]},
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        }
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(100),
            data = #domain_Terminal{
                name = <<"VTB21">>,
                description = <<>>
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(4),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(1),
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = #domain_TermSet{
                            payments = #domain_PaymentsServiceTerms{
                                cash_limit =
                                    {decisions, [
                                        #domain_CashLimitDecision{
                                            if_ =
                                                {condition,
                                                    {payment_tool,
                                                        {bank_card, #domain_BankCardCondition{
                                                            definition = {issuer_country_is, kaz}
                                                        }}}},
                                            then_ =
                                                {value,
                                                    ?cashrng(
                                                        {inclusive, ?cash(1000, <<"RUB">>)},
                                                        {inclusive, ?cash(1000, <<"RUB">>)}
                                                    )}
                                        },
                                        #domain_CashLimitDecision{
                                            if_ = {constant, true},
                                            then_ =
                                                {value,
                                                    ?cashrng(
                                                        {inclusive, ?cash(1000, <<"RUB">>)},
                                                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                                                    )}
                                        }
                                    ]}
                            }
                        }
                    }
                ]
            }
        }},
        hg_ct_fixture:construct_contract_template(?tmpl(4), ?trms(4))
    ].

payments_w_bank_conditions_fixture(_Revision) ->
    [
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(4),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(1),
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = #domain_TermSet{
                            payments = #domain_PaymentsServiceTerms{
                                cash_limit =
                                    {decisions, [
                                        #domain_CashLimitDecision{
                                            if_ =
                                                {condition,
                                                    {payment_tool,
                                                        {bank_card, #domain_BankCardCondition{
                                                            definition = {issuer_bank_is, ?bank(1)}
                                                        }}}},
                                            then_ =
                                                {value,
                                                    ?cashrng(
                                                        {inclusive, ?cash(1000, <<"RUB">>)},
                                                        {inclusive, ?cash(1000, <<"RUB">>)}
                                                    )}
                                        },
                                        #domain_CashLimitDecision{
                                            if_ = {constant, true},
                                            then_ =
                                                {value,
                                                    ?cashrng(
                                                        {inclusive, ?cash(1000, <<"RUB">>)},
                                                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                                                    )}
                                        }
                                    ]}
                            }
                        }
                    }
                ]
            }
        }},
        {bank, #domain_BankObject{
            ref = ?bank(1),
            data = #domain_Bank{
                name = <<"TEST BANK">>,
                description = <<"TEST BANK">>,
                bins = ordsets:from_list([<<"42424242">>]),
                binbase_id_patterns = ordsets:from_list([<<"TEST*BANK">>])
            }
        }},
        hg_ct_fixture:construct_contract_template(?tmpl(4), ?trms(4))
    ].

payment_manual_refund_fixture(_Revision) ->
    [
        {proxy, #domain_ProxyObject{
            ref = ?prx(1),
            data = #domain_ProxyDefinition{
                name = <<"undefined">>,
                description = <<"undefined">>,
                url = <<"undefined">>,
                options = #{}
            }
        }}
    ].

construct_term_set_for_partial_capture_service_permit(_Revision) ->
    TermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            holds = #domain_PaymentHoldsServiceTerms{
                payment_methods =
                    {value,
                        ?ordset([
                            ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                            ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                        ])},
                lifetime =
                    {decisions, [
                        #domain_HoldLifetimeDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ = {value, #domain_HoldLifetime{seconds = 10}}
                        }
                    ]},
                partial_captures = #domain_PartialCaptureServiceTerms{}
            }
        }
    },
    [
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(5),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(1),
                term_sets = [
                    #domain_TimedTermSet{
                        action_time = #base_TimestampInterval{},
                        terms = TermSet
                    }
                ]
            }
        }},
        hg_ct_fixture:construct_contract_template(?tmpl(6), ?trms(5))
    ].

construct_term_set_for_partial_capture_provider_permit(Revision) ->
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstitution#domain_PaymentInstitution{
                payment_routing_rules = #domain_RoutingRules{
                    policies = ?ruleset(2),
                    prohibitions = ?ruleset(3)
                }
            }
        }},
        {routing_rules, #domain_RoutingRulesObject{
            ref = ?ruleset(2),
            data = #domain_RoutingRuleset{
                name = <<"">>,
                decisions =
                    {candidates, [
                        ?candidate({constant, true}, ?trm(1))
                    ]}
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(1),
            data = #domain_Terminal{
                name = <<"Brominal 1">>,
                description = <<"Brominal 1">>,
                provider_ref = #domain_ProviderRef{id = 101}
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(101),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"brovider">>
                    }
                },
                abs_account = <<"1234567890">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                terms = #domain_ProvisionTermSet{
                    payments = #domain_PaymentsProvisionTerms{
                        currencies =
                            {value,
                                ?ordset([
                                    ?cur(<<"RUB">>)
                                ])},
                        categories =
                            {value,
                                ?ordset([
                                    ?cat(1)
                                ])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>))
                                ])},
                        cash_limit =
                            {value,
                                ?cashrng(
                                    {inclusive, ?cash(1000, <<"RUB">>)},
                                    {exclusive, ?cash(1000000000, <<"RUB">>)}
                                )},
                        cash_flow =
                            {decisions, [
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(18, 1000, operation_amount)
                                            )
                                        ]}
                                },
                                #domain_CashFlowDecision{
                                    if_ =
                                        {condition,
                                            {payment_tool,
                                                {bank_card, #domain_BankCardCondition{
                                                    definition =
                                                        {payment_system, #domain_PaymentSystemCondition{
                                                            payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                        }}
                                                }}}},
                                    then_ =
                                        {value, [
                                            ?cfpost(
                                                {provider, settlement},
                                                {merchant, settlement},
                                                ?share(1, 1, operation_amount)
                                            ),
                                            ?cfpost(
                                                {system, settlement},
                                                {provider, settlement},
                                                ?share(18, 1000, operation_amount)
                                            )
                                        ]}
                                }
                            ]},
                        refunds = #domain_PaymentRefundsProvisionTerms{
                            cash_flow =
                                {value, [
                                    ?cfpost(
                                        {merchant, settlement},
                                        {provider, settlement},
                                        ?share(1, 1, operation_amount)
                                    )
                                ]},
                            partial_refunds = #domain_PartialRefundsProvisionTerms{
                                cash_limit =
                                    {value,
                                        ?cashrng(
                                            {inclusive, ?cash(10, <<"RUB">>)},
                                            {exclusive, ?cash(1000000000, <<"RUB">>)}
                                        )}
                            }
                        },
                        holds = #domain_PaymentHoldsProvisionTerms{
                            lifetime =
                                {decisions, [
                                    #domain_HoldLifetimeDecision{
                                        if_ =
                                            {condition,
                                                {payment_tool,
                                                    {bank_card, #domain_BankCardCondition{
                                                        definition =
                                                            {payment_system, #domain_PaymentSystemCondition{
                                                                payment_system_is = ?pmt_sys(<<"visa-ref">>)
                                                            }}
                                                    }}}},
                                        then_ = {value, ?hold_lifetime(12)}
                                    }
                                ]},
                            partial_captures = #domain_PartialCaptureProvisionTerms{}
                        }
                    },
                    recurrent_paytools = #domain_RecurrentPaytoolsProvisionTerms{
                        categories = {value, ?ordset([?cat(1)])},
                        payment_methods =
                            {value,
                                ?ordset([
                                    ?pmt(bank_card, ?bank_card(<<"visa-ref">>)),
                                    ?pmt(bank_card, ?bank_card(<<"mastercard-ref">>))
                                ])},
                        cash_value = {value, ?cash(1000, <<"RUB">>)}
                    }
                }
            }
        }}
    ].

% Deadline as timeout()
set_processing_deadline(Timeout, PaymentParams) ->
    Deadline = woody_deadline:to_binary(woody_deadline:from_timeout(Timeout)),
    PaymentParams#payproc_InvoicePaymentParams{processing_deadline = Deadline}.
