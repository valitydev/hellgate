-ifndef(__hellgate_invoice_events__).
-define(__hellgate_invoice_events__, 42).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

%% FIXME old names remain for simplicity, should be changes
-define(invoice_ev(InvoiceChanges), {invoice_changes, InvoiceChanges}).

-define(invoice_created(Invoice),
    {invoice_created, #payproc_InvoiceCreated{invoice = Invoice}}
).

-define(invoice_status_changed(Status),
    {invoice_status_changed, #payproc_InvoiceStatusChanged{status = Status}}
).

-define(invoice_adjustment_ev(ID, Payload),
    {invoice_adjustment_change, #payproc_InvoiceAdjustmentChange{
        id = ID,
        payload = Payload
    }}
).

-define(invoice_adjustment_ev(ID, Payload, OccurredAt),
    {invoice_adjustment_change, #payproc_InvoiceAdjustmentChange{
        id = ID,
        payload = Payload,
        occurred_at = OccurredAt
    }}
).

-define(invoice_adjustment_created(Adjustment),
    {invoice_adjustment_created, #payproc_InvoiceAdjustmentCreated{
        adjustment = Adjustment
    }}
).

-define(invoice_adjustment_status_changed(Status),
    {invoice_adjustment_status_changed, #payproc_InvoiceAdjustmentStatusChanged{
        status = Status
    }}
).

-define(payment_ev(PaymentID, Payload),
    {invoice_payment_change, #payproc_InvoicePaymentChange{
        id = PaymentID,
        payload = Payload
    }}
).

-define(payment_ev(PaymentID, Payload, OccurredAt),
    {invoice_payment_change, #payproc_InvoicePaymentChange{
        id = PaymentID,
        payload = Payload,
        occurred_at = OccurredAt
    }}
).

-define(invoice_paid(),
    {paid, #domain_InvoicePaid{}}
).

-define(invoice_unpaid(),
    {unpaid, #domain_InvoiceUnpaid{}}
).

-define(invoice_cancelled(Reason),
    {cancelled, #domain_InvoiceCancelled{details = Reason}}
).

-define(invoice_fulfilled(Reason),
    {fulfilled, #domain_InvoiceFulfilled{details = Reason}}
).

-define(INVOICE_TPL_VIOLATED, "Template violation: ").
-define(INVOICE_TPL_NO_COST, <<?INVOICE_TPL_VIOLATED "missing invoice cost">>).
-define(INVOICE_TPL_BAD_COST, <<?INVOICE_TPL_VIOLATED "cost mismatch">>).
-define(INVOICE_TPL_BAD_CURRENCY, <<?INVOICE_TPL_VIOLATED "invalid currency">>).
-define(INVOICE_TPL_BAD_AMOUNT, <<?INVOICE_TPL_VIOLATED "invalid amount">>).
-endif.
