-ifndef(__hg_invoice_payment__).
-define(__hg_invoice_payment__, true).

-record(st, {
    activity :: hg_invoice_payment:activity(),
    status_log = [] :: [dmsl_domain_thrift:'InvoicePaymentStatus'()],
    payment :: undefined | hg_invoice_payment:payment(),
    risk_score :: undefined | hg_inspector:risk_score(),
    routes = [] :: [hg_route:payment_route()],
    candidate_routes :: undefined | [hg_route:payment_route()],
    interim_payment_status :: undefined | hg_invoice_payment:payment_status(),
    new_cash :: undefined | hg_cash:cash(),
    new_cash_provided :: undefined | boolean(),
    new_cash_flow :: undefined | hg_cashflow:final_cash_flow(),
    cash_flow :: undefined | hg_cashflow:final_cash_flow(),
    partial_cash_flow :: undefined | hg_cashflow:final_cash_flow(),
    final_cash_flow :: undefined | hg_cashflow:final_cash_flow(),
    trx :: undefined | hg_invoice_payment:trx_info(),
    target :: undefined | hg_invoice_payment:target(),
    sessions = #{} :: #{hg_invoice_payment:session_target_type() => [hg_session:t()]},
    retry_attempts = #{} :: #{hg_invoice_payment:session_target_type() => non_neg_integer()},
    refunds = #{} :: #{hg_invoice_payment:refund_id() => hg_invoice_payment:refund_state()},
    chargebacks = #{} :: #{hg_invoice_payment_chargeback:id() => hg_invoice_payment_chargeback:state()},
    adjustments = [] :: [hg_invoice_payment:adjustment()],
    recurrent_token :: undefined | dmsl_domain_thrift:'Token'(),
    opts :: undefined | hg_invoice_payment:opts(),
    repair_scenario :: undefined | hg_invoice_repair:scenario(),
    capture_data :: undefined | hg_invoice_payment:capture_data(),
    failure :: undefined | hg_invoice_payment:failure(),
    timings :: undefined | hg_timings:t(),
    allocation :: undefined | hg_allocation:allocation(),
    route_limits = #{} :: hg_routing:limits(),
    route_scores = #{} :: hg_routing:scores(),
    shop_limit_status = undefined :: undefined | initialized | finalized
}).

-record(refund_st, {
    refund :: undefined | hg_invoice_payment:domain_refund(),
    cash_flow :: undefined | hg_cashflow:final_cash_flow(),
    sessions = [] :: [hg_invoice_payment:session()],
    transaction_info :: undefined | hg_invoice_payment:trx_info(),
    failure :: undefined | hg_invoice_payment:failure()
}).

-endif.
