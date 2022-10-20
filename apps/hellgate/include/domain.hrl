-ifndef(__hellgate_domain__).
-define(__hellgate_domain__, 42).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-define(currency(SymCode), #domain_CurrencyRef{symbolic_code = SymCode}).

-define(cash(Amount, SymCode), #domain_Cash{amount = Amount, currency = ?currency(SymCode)}).

-define(route(ProviderRef, TerminalRef), #domain_PaymentRoute{
    provider = ProviderRef,
    terminal = TerminalRef
}).

-define(failure(Code),
    ?failure(Code, undefined)
).

-define(failure(Code, Reason),
    {failure, #domain_Failure{code = Code, reason = Reason}}
).

-define(operation_timeout(),
    {operation_timeout, #domain_OperationTimeout{}}
).

-define(invoice_payment_merchant_reg_origin(),
    {internal, #domain_InvoicePaymentMerchantRegistration{}}
).

-define(invoice_payment_provider_reg_origin(),
    {external, #domain_InvoicePaymentProviderRegistration{}}
).

-define(invoice_payment_flow_instant(),
    {instant, #domain_InvoicePaymentFlowInstant{}}
).

-define(invoice_payment_flow_hold(OnHoldExpiration, HeldUntil),
    {hold, #domain_InvoicePaymentFlowHold{on_hold_expiration = OnHoldExpiration, held_until = HeldUntil}}
).

-define(hold_lifetime(HoldLifetime), #domain_HoldLifetime{seconds = HoldLifetime}).

-define(payment_resource_payer(Resource, ContactInfo),
    {payment_resource, #domain_PaymentResourcePayer{resource = Resource, contact_info = ContactInfo}}
).

-define(payment_resource_payer(),
    {payment_resource, #domain_PaymentResourcePayer{}}
).

-define(customer_payer(CustomerID, CustomerBindingID, RecurrentPaytoolID, PaymentTool, ContactInfo),
    {customer, #domain_CustomerPayer{
        customer_id = CustomerID,
        customer_binding_id = CustomerBindingID,
        rec_payment_tool_id = RecurrentPaytoolID,
        payment_tool = PaymentTool,
        contact_info = ContactInfo
    }}
).

-define(customer_payer(), {customer, #domain_CustomerPayer{}}).

-define(recurrent_payer(PaymentTool, Parent, ContactInfo),
    {recurrent, #domain_RecurrentPayer{
        payment_tool = PaymentTool,
        recurrent_parent = Parent,
        contact_info = ContactInfo
    }}
).

-define(recurrent_payer(), {recurrent, #domain_RecurrentPayer{}}).

-define(recurrent_parent(InvoiceID, PaymentID), #domain_RecurrentParentPayment{
    invoice_id = InvoiceID,
    payment_id = PaymentID
}).

-define(invoice_cart(Lines), #domain_InvoiceCart{
    lines = Lines
}).

-define(invoice_line(ProductName, Quantity, Price), ?invoice_line(ProductName, Quantity, Price, #{})).

-define(invoice_line(ProductName, Quantity, Price, Metadata), #domain_InvoiceLine{
    product = ProductName,
    quantity = Quantity,
    price = Price,
    metadata = Metadata
}).

-endif.
