-ifndef(__hg_invoice__).
-define(__hg_invoice__, true).

-record(st, {
    activity :: undefined | hg_invoice:activity(),
    invoice :: undefined | hg_invoice:invoice(),
    payments = [] :: [{hg_invoice:payment_id(), hg_invoice:payment_st()}],
    party :: undefined | hg_invoice:party(),
    party_id :: undefined | hg_invoice:party_id()
}).

-endif.
