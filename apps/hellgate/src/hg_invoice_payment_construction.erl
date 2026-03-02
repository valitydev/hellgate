%%% Payment construction module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Contains all construct_* and get_predefined_* functions.

-module(hg_invoice_payment_construction).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").

-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").

%% Types
-type st() :: hg_invoice_payment:st().
-type payment() :: hg_invoice_payment:payment().
-type payer() :: dmsl_domain_thrift:'Payer'().
-type payer_params() :: dmsl_payproc_thrift:'PayerParams'().
-type payment_flow_params() :: dmsl_payproc_thrift:'InvoicePaymentParamsFlow'().
-type payment_info() :: dmsl_proxy_provider_thrift:'PaymentInfo'().
-type payment_plan_id() :: binary().
-type route() :: hg_route:payment_route().
-type failure() :: hg_invoice_payment:failure().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type shop_config_ref() :: dmsl_domain_thrift:'ShopConfigRef'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type party_config_ref() :: dmsl_domain_thrift:'PartyConfigRef'().
-type make_recurrent() :: true | false.
-type activity() :: hg_invoice_payment:activity().
-type target() :: hg_invoice_payment:target().
-type trx_info() :: hg_invoice_payment:trx_info().

%% Construction functions
-export([construct_payer/1]).
-export([construct_payment/10]).
-export([construct_payment_flow/4]).
-export([reconstruct_payment_flow/2]).
-export([reconstruct_payment_flow/3]).
-export([construct_payment_info/4]).
-export([construct_payment_plan_id/4]).
-export([construct_routing_failure/1]).
-export([construct_routing_failure/2]).
-export([get_predefined_route/1]).
-export([get_predefined_recurrent_route/1]).

%% Helper functions for construct_payment_info
-export([construct_proxy_payment/2]).
-export([construct_proxy_invoice/1]).
-export([construct_proxy_shop/1]).
-export([construct_proxy_cash/1]).
-export([construct_proxy_capture/1]).

%%% Construction functions

-spec construct_payer(payer_params()) -> {ok, payer(), map()}.
construct_payer(
    {payment_resource, #payproc_PaymentResourcePayerParams{
        resource = Resource,
        contact_info = ContactInfo
    }}
) ->
    {ok, ?payment_resource_payer(Resource, ContactInfo), #{}};
construct_payer(
    {recurrent, #payproc_RecurrentPayerParams{
        recurrent_parent = Parent,
        contact_info = ContactInfo
    }}
) ->
    ?recurrent_parent(InvoiceID, PaymentID) = Parent,
    ParentPayment =
        try
            hg_invoice_payment:get_payment_state(InvoiceID, PaymentID)
        catch
            throw:#payproc_InvoiceNotFound{} ->
                throw_invalid_recurrent_parent(<<"Parent invoice not found">>);
            throw:#payproc_InvoicePaymentNotFound{} ->
                throw_invalid_recurrent_parent(<<"Parent payment not found">>)
        end,
    #domain_InvoicePayment{payer = ParentPayer} = hg_invoice_payment:get_payment(ParentPayment),
    ParentPaymentTool = hg_invoice_payment:get_payer_payment_tool(ParentPayer),
    {ok, ?recurrent_payer(ParentPaymentTool, Parent, ContactInfo), #{parent_payment => ParentPayment}}.

-spec construct_payment(
    payment_id(),
    dmsl_base_thrift:'Timestamp'(),
    cash(),
    payer(),
    payment_flow_params(),
    party_config_ref(),
    {shop_config_ref(), shop()},
    map(),
    hg_domain:revision(),
    make_recurrent()
) -> payment().
construct_payment(
    PaymentID,
    CreatedAt,
    Cost,
    Payer,
    FlowParams,
    PartyConfigRef,
    {ShopConfigRef, Shop} = ShopObj,
    VS0,
    Revision,
    MakeRecurrent
) ->
    PaymentTool = hg_invoice_payment:get_payer_payment_tool(Payer),
    VS1 = VS0#{
        payment_tool => PaymentTool,
        cost => Cost
    },
    Terms = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS1),
    #domain_TermSet{payments = PaymentTerms, recurrent_paytools = RecurrentTerms} = Terms,
    ok = hg_invoice_payment_validation:validate_payment_tool(
        PaymentTool,
        PaymentTerms#domain_PaymentsServiceTerms.payment_methods
    ),
    ok = hg_invoice_payment_validation:validate_cash(
        Cost,
        PaymentTerms#domain_PaymentsServiceTerms.cash_limit
    ),
    Flow = construct_payment_flow(
        FlowParams,
        CreatedAt,
        PaymentTerms#domain_PaymentsServiceTerms.holds,
        PaymentTool
    ),
    ParentPayment = maps:get(parent_payment, VS1, undefined),
    ok = hg_invoice_payment_validation:validate_recurrent_intention(
        Payer, RecurrentTerms, PaymentTool, ShopObj, ParentPayment, MakeRecurrent
    ),
    #domain_InvoicePayment{
        id = PaymentID,
        created_at = CreatedAt,
        party_ref = PartyConfigRef,
        shop_ref = ShopConfigRef,
        domain_revision = Revision,
        status = ?pending(),
        cost = Cost,
        payer = Payer,
        flow = Flow,
        make_recurrent = MakeRecurrent,
        registration_origin = ?invoice_payment_merchant_reg_origin()
    }.

-spec construct_payment_flow(
    payment_flow_params(),
    dmsl_base_thrift:'Timestamp'(),
    undefined | dmsl_domain_thrift:'PaymentHoldsServiceTerms'(),
    dmsl_domain_thrift:'PaymentTool'()
) -> dmsl_domain_thrift:'InvoicePaymentFlow'().
construct_payment_flow({instant, _}, _CreatedAt, _Terms, _PaymentTool) ->
    ?invoice_payment_flow_instant();
construct_payment_flow({hold, Params}, CreatedAt, Terms, PaymentTool) ->
    OnHoldExpiration = Params#payproc_InvoicePaymentParamsFlowHold.on_hold_expiration,
    ?hold_lifetime(Seconds) = hg_invoice_payment_validation:validate_hold_lifetime(Terms, PaymentTool),
    HeldUntil = hg_datetime:format_ts(hg_datetime:parse_ts(CreatedAt) + Seconds),
    ?invoice_payment_flow_hold(OnHoldExpiration, HeldUntil).

-spec reconstruct_payment_flow(payment(), hg_varset:varset()) -> hg_varset:varset().
reconstruct_payment_flow(Payment, VS) ->
    #domain_InvoicePayment{
        flow = Flow,
        created_at = CreatedAt
    } = Payment,
    reconstruct_payment_flow(Flow, CreatedAt, VS).

-spec reconstruct_payment_flow(
    dmsl_domain_thrift:'InvoicePaymentFlow'(),
    dmsl_base_thrift:'Timestamp'(),
    hg_varset:varset()
) -> hg_varset:varset().
reconstruct_payment_flow(?invoice_payment_flow_instant(), _CreatedAt, VS) ->
    VS#{flow => instant};
reconstruct_payment_flow(?invoice_payment_flow_hold(_OnHoldExpiration, HeldUntil), CreatedAt, VS) ->
    Seconds = hg_datetime:parse_ts(HeldUntil) - hg_datetime:parse_ts(CreatedAt),
    VS#{flow => {hold, ?hold_lifetime(Seconds)}}.

-spec get_predefined_route(payer()) -> {ok, route()} | undefined.
get_predefined_route(?payment_resource_payer()) ->
    undefined;
get_predefined_route(?recurrent_payer() = Payer) ->
    get_predefined_recurrent_route(Payer).

-spec get_predefined_recurrent_route(payer()) -> {ok, route()}.
get_predefined_recurrent_route(?recurrent_payer(_, ?recurrent_parent(InvoiceID, PaymentID), _)) ->
    PreviousPayment = hg_invoice_payment:get_payment_state(InvoiceID, PaymentID),
    {ok, hg_invoice_payment:get_route(PreviousPayment)}.

-spec construct_payment_plan_id(invoice(), payment(), non_neg_integer(), legacy | normal) -> payment_plan_id().
construct_payment_plan_id(Invoice, Payment, _Iter, legacy) ->
    hg_utils:construct_complex_id([
        get_invoice_id(Invoice),
        get_payment_id(Payment)
    ]);
construct_payment_plan_id(Invoice, Payment, Iter, _Mode) ->
    hg_utils:construct_complex_id([
        get_invoice_id(Invoice),
        get_payment_id(Payment),
        integer_to_binary(Iter)
    ]).

-spec construct_payment_info(activity(), target(), st(), payment_info()) -> payment_info().
construct_payment_info(idle, _Target, _St, PaymentInfo) ->
    PaymentInfo;
construct_payment_info(
    {payment, _Step},
    Target = ?captured(),
    _St,
    PaymentInfo
) ->
    PaymentInfo#proxy_provider_PaymentInfo{
        capture = construct_proxy_capture(Target)
    };
construct_payment_info({payment, _Step}, _Target, _St, PaymentInfo) ->
    PaymentInfo;
construct_payment_info({refund, _ID}, _Target, _St, PaymentInfo) ->
    PaymentInfo.

-spec construct_routing_failure(
    {rejected_routes, {atom(), term()}}
    | {misconfiguration, term()}
    | risk_score_is_too_high
    | atom()
) -> failure().
construct_routing_failure({rejected_routes, {SubCode, RejectedRoutes}}) when
    SubCode =:= limit_misconfiguration orelse
        SubCode =:= limit_overflow orelse
        SubCode =:= adapter_unavailable orelse
        SubCode =:= provider_conversion_is_too_low
->
    construct_routing_failure([rejected, SubCode], genlib:format(RejectedRoutes));
construct_routing_failure({rejected_routes, {_SubCode, RejectedRoutes}}) ->
    construct_routing_failure([forbidden], genlib:format(RejectedRoutes));
construct_routing_failure({misconfiguration = Code, Details}) ->
    construct_routing_failure([unknown, {unknown_error, atom_to_binary(Code)}], genlib:format(Details));
construct_routing_failure(risk_score_is_too_high = Code) ->
    construct_routing_failure([Code], undefined);
construct_routing_failure(Error) when is_atom(Error) ->
    construct_routing_failure([{unknown_error, Error}], undefined).

-spec construct_routing_failure([term()], undefined | binary()) -> failure().
construct_routing_failure(Codes, Reason) ->
    {failure, payproc_errors:construct('PaymentFailure', mk_static_error([no_route_found | Codes]), Reason)}.

%%% Helper functions

-spec mk_static_error([term()]) -> term().
mk_static_error([_ | _] = Codes) -> mk_static_error_(#payproc_error_GeneralFailure{}, lists:reverse(Codes)).
mk_static_error_(T, []) -> T;
mk_static_error_(Sub, [Code | Codes]) -> mk_static_error_({Code, Sub}, Codes).

-spec construct_proxy_payment(payment(), trx_info()) -> dmsl_proxy_provider_thrift:'InvoicePayment'().
construct_proxy_payment(
    #domain_InvoicePayment{
        id = ID,
        created_at = CreatedAt,
        domain_revision = Revision,
        payer = Payer,
        payer_session_info = PayerSessionInfo,
        cost = Cost,
        make_recurrent = MakeRecurrent,
        skip_recurrent = SkipRecurrent,
        processing_deadline = Deadline
    },
    Trx
) ->
    ContactInfo = get_contact_info(Payer),
    PaymentTool = hg_invoice_payment:get_payer_payment_tool(Payer),
    #proxy_provider_InvoicePayment{
        id = ID,
        created_at = CreatedAt,
        trx = Trx,
        payment_resource = construct_payment_resource(Payer),
        payment_service = hg_payment_tool:get_payment_service(PaymentTool, Revision),
        payer_session_info = PayerSessionInfo,
        cost = construct_proxy_cash(Cost),
        contact_info = ContactInfo,
        make_recurrent = MakeRecurrent,
        skip_recurrent = SkipRecurrent,
        processing_deadline = Deadline
    }.

construct_payment_resource(?payment_resource_payer(Resource, _)) ->
    {disposable_payment_resource, Resource};
construct_payment_resource(?recurrent_payer(PaymentTool, ?recurrent_parent(InvoiceID, PaymentID), _)) ->
    PreviousPayment = hg_invoice_payment:get_payment_state(InvoiceID, PaymentID),
    RecToken = hg_invoice_payment:get_recurrent_token(PreviousPayment),
    {recurrent_payment_resource, #proxy_provider_RecurrentPaymentResource{
        payment_tool = PaymentTool,
        rec_token = RecToken
    }}.

get_contact_info(?payment_resource_payer(_, ContactInfo)) ->
    ContactInfo;
get_contact_info(?recurrent_payer(_, _, ContactInfo)) ->
    ContactInfo.

-spec construct_proxy_invoice(invoice()) -> dmsl_proxy_provider_thrift:'Invoice'().
construct_proxy_invoice(
    #domain_Invoice{
        id = InvoiceID,
        created_at = CreatedAt,
        due = Due,
        details = Details,
        cost = Cost
    }
) ->
    #proxy_provider_Invoice{
        id = InvoiceID,
        created_at = CreatedAt,
        due = Due,
        details = Details,
        cost = construct_proxy_cash(Cost)
    }.

-spec construct_proxy_shop({shop_config_ref(), shop()}) -> dmsl_proxy_provider_thrift:'Shop'().
construct_proxy_shop(
    {
        #domain_ShopConfigRef{id = ShopConfigID},
        Shop = #domain_ShopConfig{
            location = Location,
            category = ShopCategoryRef
        }
    }
) ->
    ShopCategory = hg_domain:get({category, ShopCategoryRef}),
    #proxy_provider_Shop{
        id = ShopConfigID,
        category = ShopCategory,
        name = Shop#domain_ShopConfig.name,
        description = Shop#domain_ShopConfig.description,
        location = Location
    }.

-spec construct_proxy_cash(cash()) -> dmsl_proxy_provider_thrift:'Cash'().
construct_proxy_cash(#domain_Cash{
    amount = Amount,
    currency = CurrencyRef
}) ->
    #proxy_provider_Cash{
        amount = Amount,
        currency = hg_domain:get({currency, CurrencyRef})
    }.

-spec construct_proxy_capture(target()) -> dmsl_proxy_provider_thrift:'InvoicePaymentCapture'().
construct_proxy_capture(?captured(_, Cost)) ->
    #proxy_provider_InvoicePaymentCapture{
        cost = construct_proxy_cash(Cost)
    }.

-spec get_invoice_id(invoice()) -> dmsl_domain_thrift:'InvoiceID'().
get_invoice_id(#domain_Invoice{id = ID}) ->
    ID.

-spec get_payment_id(payment()) -> payment_id().
get_payment_id(#domain_InvoicePayment{id = ID}) ->
    ID.

-spec throw_invalid_recurrent_parent(binary()) -> no_return().
throw_invalid_recurrent_parent(Details) ->
    throw(#payproc_InvalidRecurrentParentPayment{details = Details}).
