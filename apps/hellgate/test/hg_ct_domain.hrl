-ifndef(__hellgate_ct_domain__).
-define(__hellgate_ct_domain__, 42).

-include_lib("hellgate/include/domain.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").
-include_lib("damsel/include/dmsl_user_interaction_thrift.hrl").

-define(ordset(Es), ordsets:from_list(Es)).

-define(match(Term), erlang:binary_to_term(erlang:term_to_binary(Term))).
-define('_', ?match('_')).

-define(glob(), #domain_GlobalsRef{}).
-define(cur(ID), #domain_CurrencyRef{symbolic_code = ID}).
-define(pmt(C, T), #domain_PaymentMethodRef{id = {C, T}}).
-define(pmt_sys(ID), #domain_PaymentSystemRef{id = ID}).
-define(pmt_srv(ID), #domain_PaymentServiceRef{id = ID}).
-define(pomt(M), #domain_PayoutMethodRef{id = M}).
-define(cat(ID), #domain_CategoryRef{id = ID}).
-define(prx(ID), #domain_ProxyRef{id = ID}).
-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(prvtrm(ID), #domain_ProviderTerminalRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).
-define(tmpl(ID), #domain_ContractTemplateRef{id = ID}).
-define(trms(ID), #domain_TermSetHierarchyRef{id = ID}).
-define(sas(ID), #domain_SystemAccountSetRef{id = ID}).
-define(eas(ID), #domain_ExternalAccountSetRef{id = ID}).
-define(insp(ID), #domain_InspectorRef{id = ID}).
-define(pinst(ID), #domain_PaymentInstitutionRef{id = ID}).
-define(bank(ID), #domain_BankRef{id = ID}).
-define(bussched(ID), #domain_BusinessScheduleRef{id = ID}).
-define(ruleset(ID), #domain_RoutingRulesetRef{id = ID}).
-define(bc_cat(ID), #domain_BankCardCategoryRef{id = ID}).
-define(mob(ID), #domain_MobileOperatorRef{id = ID}).
-define(crypta(ID), #domain_CryptoCurrencyRef{id = ID}).
-define(token_srv(ID), #domain_BankCardTokenServiceRef{id = ID}).
-define(bank_card(ID), #domain_BankCardPaymentMethod{payment_system = ?pmt_sys(ID)}).
-define(bank_card_no_cvv(ID), #domain_BankCardPaymentMethod{payment_system = ?pmt_sys(ID), is_cvv_empty = true}).
-define(token_bank_card(ID, Prv), ?token_bank_card(ID, Prv, dpan)).
-define(token_bank_card(ID, Prv, Method), #domain_BankCardPaymentMethod{
    payment_system = ?pmt_sys(ID),
    payment_token = ?token_srv(Prv),
    tokenization_method = Method
}).

-define(cashrng(Lower, Upper), #domain_CashRange{lower = Lower, upper = Upper}).

-define(prvacc(Stl), #domain_ProviderAccount{settlement = Stl}).
-define(partycond(ID, Def), {condition, {party, #domain_PartyCondition{id = ID, definition = Def}}}).

-define(fixed(Amount, Currency),
    {fixed, #domain_CashVolumeFixed{
        cash = #domain_Cash{
            amount = Amount,
            currency = ?currency(Currency)
        }
    }}
).

-define(ratio(P, Q), #base_Rational{p = P, q = Q}).

-define(share(P, Q, C), {share, #domain_CashVolumeShare{parts = ?ratio(P, Q), 'of' = C}}).

-define(share_with_rounding_method(P, Q, C, RM),
    {share, #domain_CashVolumeShare{parts = ?ratio(P, Q), 'of' = C, rounding_method = RM}}
).

-define(cfpost(A1, A2, V), #domain_CashFlowPosting{
    source = A1,
    destination = A2,
    volume = V
}).

-define(cfpost(A1, A2, V, D), #domain_CashFlowPosting{
    source = A1,
    destination = A2,
    volume = V,
    details = D
}).

-define(contact_info(EMail),
    ?contact_info(EMail, undefined)
).

-define(contact_info(EMail, Phone),
    ?contact_info(EMail, Phone, undefined, undefined, undefined, undefined, undefined, undefined, undefined)
).

-define(contact_info(EMail, Phone, FirstName, LastName, Country, State, City, Address, PostalCode),
    #domain_ContactInfo{
        email = EMail,
        phone_number = Phone,
        first_name = FirstName,
        last_name = LastName,
        country = Country,
        state = State,
        city = City,
        address = Address,
        postal_code = PostalCode
    }
).

-define(timeout_reason(), <<"Timeout">>).

-define(cart(Price, Details), #domain_InvoiceCart{
    lines = [
        #domain_InvoiceLine{
            product = <<"Test">>,
            quantity = 1,
            price = Price,
            metadata = Details
        }
    ]
}).

-define(pin(Features), #domain_RoutingPin{features = ordsets:from_list(Features)}).

-define(candidate(Allowed, TerminalRef),
    ?candidate(undefined, Allowed, TerminalRef)
).

-define(candidate(Descr, Allowed, TerminalRef),
    ?candidate(Descr, Allowed, TerminalRef, undefined)
).

-define(candidate(Descr, Allowed, TerminalRef, Priority),
    ?candidate(Descr, Allowed, TerminalRef, Priority, undefined)
).

-define(candidate(Descr, Allowed, TerminalRef, Priority, Weight),
    ?candidate(Descr, Allowed, TerminalRef, Priority, Weight, undefined)
).

-define(candidate(Descr, Allowed, TerminalRef, Priority, Weight, Pin), #domain_RoutingCandidate{
    description = Descr,
    allowed = Allowed,
    terminal = TerminalRef,
    priority = Priority,
    weight = Weight,
    pin = Pin
}).

-define(delegate(Allowed, RuleSetRef), #domain_RoutingDelegate{
    allowed = Allowed,
    ruleset = RuleSetRef
}).

-define(delegate(Descr, Allowed, RuleSetRef), #domain_RoutingDelegate{
    description = Descr,
    allowed = Allowed,
    ruleset = RuleSetRef
}).

-define(terminal_obj(Ref, PRef), #domain_TerminalObject{
    ref = Ref,
    data = #domain_Terminal{
        name = <<"Payment Terminal">>,
        description = <<"Best terminal">>,
        provider_ref = PRef
    }
}).

-define(provider(ProvisionTermSet), #domain_Provider{
    name = <<"Biba">>,
    description = <<"Payment terminal provider">>,
    proxy = #domain_Proxy{
        ref = ?prx(1),
        additional = #{
            <<"override">> => <<"biba">>
        }
    },
    abs_account = <<"0987654321">>,
    accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
    terms = ProvisionTermSet
}).

-define(payment_terms, #domain_PaymentsProvisionTerms{
    allow = {constant, true},
    global_allow = {constant, true},
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
                ?pmt(payment_terminal, ?pmt_srv(<<"euroset-ref">>))
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
}).

-define(err_gen_failure(), #payproc_error_GeneralFailure{}).

-define(redirect(Uri, Form),
    {redirect, {post_request, #user_interaction_BrowserPostRequest{uri = Uri, form = Form}}}
).

-define(payterm_receipt(SPID),
    {payment_terminal_reciept, #user_interaction_PaymentTerminalReceipt{short_payment_id = SPID}}
).

-endif.
