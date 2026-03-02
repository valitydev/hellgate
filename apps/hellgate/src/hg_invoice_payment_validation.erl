%%% Payment validation module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Contains all validate_* and assert_* functions.

-module(hg_invoice_payment_validation).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").

%% Types
-type st() :: hg_invoice_payment:st().
-type payment() :: hg_invoice_payment:payment().
-type payment_status() :: hg_invoice_payment:payment_status().
-type payment_status_type() :: hg_invoice_payment:payment_status_type().
-type payer() :: dmsl_domain_thrift:'Payer'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type shop_config_ref() :: dmsl_domain_thrift:'ShopConfigRef'().
-type recurrent_paytool_service_terms() :: dmsl_domain_thrift:'RecurrentPaytoolsServiceTerms'().
-type activity() :: hg_invoice_payment:activity().
-type change() :: hg_invoice_payment:change().
-type change_opts() :: hg_invoice_payment:change_opts().
-type make_recurrent() :: true | false.
-type adjustment_status_type() :: pending | processed | captured | cancelled.

%% Validation functions
-export([validate_hold_lifetime/2]).
-export([validate_recurrent_intention/6]).
-export([validate_recurrent_terms/2]).
-export([validate_recurrent_parent/2]).
-export([validate_recurrent_token_present/1]).
-export([validate_recurrent_parent_party/2]).
-export([validate_recurrent_parent_status/1]).
-export([validate_recurrent_payer/2]).
-export([validate_payment_tool/2]).
-export([validate_cash/2]).
-export([validate_limit/2]).
-export([validate_refund_time/3]).
-export([validate_processing_deadline/2]).
-export([validate_merchant_hold_terms/1]).
-export([validate_provider_holds_terms/1]).
-export([validate_payment_status/2]).
-export([validate_allocation_refund/2]).
-export([validate_refund/3]).
-export([validate_partial_refund/3]).
-export([validate_common_refund_terms/3]).
-export([validate_transition/4]).

%% Assertion functions
-export([assert_capture_cost_currency/2]).
-export([assert_capture_cart/2]).
-export([assert_refund_cash/2]).
-export([assert_remaining_payment_amount/2]).
-export([assert_previous_refunds_finished/1]).
-export([assert_refund_cart/3]).
-export([assert_adjustment_payment_status/1]).
-export([assert_no_refunds/1]).
-export([assert_adjustment_payment_statuses/2]).
-export([assert_activity/2]).
-export([assert_payment_status/2]).
-export([assert_no_pending_chargebacks/1]).
-export([assert_no_adjustment_pending/1]).
-export([assert_adjustment_finalized/1]).
-export([assert_payment_flow/2]).
-export([assert_adjustment_status/2]).

%% Internal helper functions
-export([is_adjustment_payment_status_final/1]).

%%% Validation functions

-spec validate_hold_lifetime(
    undefined | dmsl_domain_thrift:'PaymentHoldsServiceTerms'(),
    payment_tool()
) -> dmsl_domain_thrift:'HoldLifetime'() | no_return().
validate_hold_lifetime(
    #domain_PaymentHoldsServiceTerms{
        payment_methods = PMs,
        lifetime = LifetimeSelector
    },
    PaymentTool
) ->
    ok = validate_payment_tool(PaymentTool, PMs),
    get_selector_value(hold_lifetime, LifetimeSelector);
validate_hold_lifetime(undefined, _PaymentTool) ->
    throw_invalid_request(<<"Holds are not available">>).

-spec validate_recurrent_intention(
    payer(),
    recurrent_paytool_service_terms(),
    payment_tool(),
    {shop_config_ref(), shop()},
    payment(),
    make_recurrent()
) -> ok | no_return().
validate_recurrent_intention(
    ?recurrent_payer() = Payer,
    RecurrentTerms,
    PaymentTool,
    ShopObj,
    ParentPayment,
    MakeRecurrent
) ->
    ok = validate_recurrent_terms(RecurrentTerms, PaymentTool),
    ok = validate_recurrent_payer(Payer, MakeRecurrent),
    ok = validate_recurrent_parent(ShopObj, ParentPayment);
validate_recurrent_intention(Payer, RecurrentTerms, PaymentTool, _Shop, _ParentPayment, true = MakeRecurrent) ->
    ok = validate_recurrent_terms(RecurrentTerms, PaymentTool),
    ok = validate_recurrent_payer(Payer, MakeRecurrent);
validate_recurrent_intention(_Payer, _RecurrentTerms, _PaymentTool, _Shop, _ParentPayment, false = _MakeRecurrent) ->
    ok.

-spec validate_recurrent_terms(recurrent_paytool_service_terms(), payment_tool()) -> ok | no_return().
validate_recurrent_terms(undefined, _PaymentTool) ->
    throw(#payproc_OperationNotPermitted{});
validate_recurrent_terms(RecurrentTerms, PaymentTool) ->
    #domain_RecurrentPaytoolsServiceTerms{payment_methods = PaymentMethodSelector} = RecurrentTerms,
    PMs = get_selector_value(recurrent_payment_methods, PaymentMethodSelector),
    %% TODO delete logging after successfull migration tokenization method in domain_config
    %% https://rbkmoney.atlassian.net/browse/ED-87
    _ =
        case hg_payment_tool:has_any_payment_method(PaymentTool, PMs) of
            false ->
                logger:notice("PaymentTool: ~p", [PaymentTool]),
                logger:notice("RecurrentPaymentMethods: ~p", [PMs]),
                throw_invalid_request(<<"Invalid payment method">>);
            true ->
                ok
        end,
    ok.

-spec validate_recurrent_parent({shop_config_ref(), shop()}, st()) -> ok | no_return().
validate_recurrent_parent(ShopObj, ParentPayment) ->
    ok = validate_recurrent_token_present(ParentPayment),
    ok = validate_recurrent_parent_party(ShopObj, ParentPayment),
    ok = validate_recurrent_parent_status(ParentPayment).

-spec validate_recurrent_token_present(st()) -> ok | no_return().
validate_recurrent_token_present(PaymentState) ->
    case hg_invoice_payment:get_recurrent_token(PaymentState) of
        Token when Token =/= undefined ->
            ok;
        undefined ->
            throw_invalid_recurrent_parent(<<"Parent payment has no recurrent token">>)
    end.

-spec validate_recurrent_parent_party({shop_config_ref(), shop()}, st()) -> ok | no_return().
validate_recurrent_parent_party({_, #domain_ShopConfig{party_ref = PartyConfigRef}}, PaymentState) ->
    Payment = hg_invoice_payment:get_payment(PaymentState),
    PaymentPartyConfigRef = get_payment_party_config_ref(Payment),
    case PartyConfigRef =:= PaymentPartyConfigRef of
        true ->
            ok;
        false ->
            throw_invalid_recurrent_parent(<<"Parent payment refer to another party">>)
    end.

-spec validate_recurrent_parent_status(st()) -> ok | no_return().
validate_recurrent_parent_status(PaymentState) ->
    case hg_invoice_payment:get_payment(PaymentState) of
        #domain_InvoicePayment{status = {failed, _}} ->
            throw_invalid_recurrent_parent(<<"Invalid parent payment status">>);
        _Other ->
            ok
    end.

-spec validate_recurrent_payer(dmsl_domain_thrift:'Payer'(), make_recurrent()) -> ok | no_return().
validate_recurrent_payer(?recurrent_payer(), _MakeRecurrent) ->
    ok;
validate_recurrent_payer(?payment_resource_payer(), true) ->
    ok;
validate_recurrent_payer(_OtherPayer, true) ->
    throw_invalid_request(<<"Invalid payer">>).

-spec validate_payment_tool(payment_tool(), dmsl_domain_thrift:'PaymentMethodSelector'()) -> ok | no_return().
validate_payment_tool(PaymentTool, PaymentMethodSelector) ->
    PMs = get_selector_value(payment_methods, PaymentMethodSelector),
    _ =
        case hg_payment_tool:has_any_payment_method(PaymentTool, PMs) of
            false ->
                throw_invalid_request(<<"Invalid payment method">>);
            true ->
                ok
        end,
    ok.

-spec validate_cash(dmsl_domain_thrift:'Cash'(), dmsl_domain_thrift:'CashLimitSelector'()) -> ok | no_return().
validate_cash(Cash, CashLimitSelector) ->
    Limit = get_selector_value(cash_limit, CashLimitSelector),
    ok = validate_limit(Cash, Limit).

-spec validate_limit(dmsl_domain_thrift:'Cash'(), dmsl_domain_thrift:'CashRange'()) -> ok | no_return().
validate_limit(Cash, CashRange) ->
    case hg_cash_range:is_inside(Cash, CashRange) of
        within ->
            ok;
        {exceeds, lower} ->
            throw_invalid_request(<<"Invalid amount, less than allowed minumum">>);
        {exceeds, upper} ->
            throw_invalid_request(<<"Invalid amount, more than allowed maximum">>)
    end.

-spec validate_refund_time(timestamp(), timestamp(), dmsl_domain_thrift:'TimeSpanSelector'()) -> ok | no_return().
validate_refund_time(RefundCreatedAt, PaymentCreatedAt, TimeSpanSelector) ->
    EligibilityTime = get_selector_value(eligibility_time, TimeSpanSelector),
    RefundEndTime = hg_datetime:add_time_span(EligibilityTime, PaymentCreatedAt),
    case hg_datetime:compare(RefundCreatedAt, RefundEndTime) of
        Result when Result == earlier; Result == simultaneously ->
            ok;
        later ->
            throw(#payproc_OperationNotPermitted{})
    end.

-spec validate_processing_deadline(payment(), processed) -> ok | dmsl_domain_thrift:'OperationFailure'().
validate_processing_deadline(#domain_InvoicePayment{processing_deadline = Deadline}, processed = _TargetType) ->
    case hg_invoice_utils:check_deadline(Deadline) of
        ok ->
            ok;
        {error, deadline_reached} ->
            {failure,
                payproc_errors:construct(
                    'PaymentFailure',
                    {authorization_failed, {processing_deadline_reached, #payproc_error_GeneralFailure{}}}
                )}
    end;
validate_processing_deadline(_, _TargetType) ->
    ok.

-type timestamp() :: dmsl_base_thrift:'Timestamp'().

-spec validate_merchant_hold_terms(dmsl_domain_thrift:'PaymentsServiceTerms'()) -> ok | no_return().
validate_merchant_hold_terms(#domain_PaymentsServiceTerms{holds = Terms}) when Terms /= undefined ->
    case Terms of
        %% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
        #domain_PaymentHoldsServiceTerms{partial_captures = undefined} ->
            ok;
        #domain_PaymentHoldsServiceTerms{} ->
            throw(#payproc_OperationNotPermitted{})
    end;
%% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
validate_merchant_hold_terms(#domain_PaymentsServiceTerms{holds = undefined}) ->
    ok.

-spec validate_provider_holds_terms(dmsl_domain_thrift:'PaymentsProvisionTerms'()) -> ok | no_return().
validate_provider_holds_terms(#domain_PaymentsProvisionTerms{holds = Terms}) when Terms /= undefined ->
    case Terms of
        %% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
        #domain_PaymentHoldsProvisionTerms{partial_captures = undefined} ->
            ok;
        #domain_PaymentHoldsProvisionTerms{} ->
            throw(#payproc_OperationNotPermitted{})
    end;
%% Чтобы упростить интеграцию, по умолчанию разрешили частичные подтверждения
validate_provider_holds_terms(#domain_PaymentsProvisionTerms{holds = undefined}) ->
    ok.

-spec validate_payment_status(payment_status_type(), payment()) -> ok | no_return().
validate_payment_status(Status, #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
validate_payment_status(_, #domain_InvoicePayment{status = Status}) ->
    throw(#payproc_InvalidPaymentStatus{status = Status}).

-spec validate_allocation_refund(undefined | hg_allocation:allocation(), st()) -> ok.
validate_allocation_refund(undefined, _St) ->
    ok.

-spec validate_refund(
    dmsl_domain_thrift:'PaymentRefundsServiceTerms'(), dmsl_domain_thrift:'InvoicePaymentRefund'(), payment()
) -> ok | no_return().
validate_refund(Terms, Refund, Payment) ->
    Cost = get_payment_cost(Payment),
    Cash = get_refund_cash(Refund),
    case hg_cash:sub(Cost, Cash) of
        ?cash(0, _) ->
            validate_common_refund_terms(Terms, Refund, Payment);
        ?cash(Amount, _) when Amount > 0 ->
            validate_partial_refund(Terms, Refund, Payment)
    end.

-spec validate_partial_refund(
    dmsl_domain_thrift:'PaymentRefundsServiceTerms'(), dmsl_domain_thrift:'InvoicePaymentRefund'(), payment()
) -> ok | no_return().
validate_partial_refund(
    #domain_PaymentRefundsServiceTerms{partial_refunds = PRs} = Terms,
    Refund,
    Payment
) when PRs /= undefined ->
    ok = validate_common_refund_terms(Terms, Refund, Payment),
    ok = validate_cash(
        get_refund_cash(Refund),
        PRs#domain_PartialRefundsServiceTerms.cash_limit
    ),
    ok;
validate_partial_refund(
    #domain_PaymentRefundsServiceTerms{partial_refunds = undefined},
    _Refund,
    _Payment
) ->
    throw(#payproc_OperationNotPermitted{}).

-spec validate_common_refund_terms(
    dmsl_domain_thrift:'PaymentRefundsServiceTerms'(), dmsl_domain_thrift:'InvoicePaymentRefund'(), payment()
) -> ok | no_return().
validate_common_refund_terms(Terms, Refund, Payment) ->
    ok = validate_payment_tool(
        get_payment_tool(Payment),
        Terms#domain_PaymentRefundsServiceTerms.payment_methods
    ),
    ok = validate_refund_time(
        get_refund_created_at(Refund),
        get_payment_created_at(Payment),
        Terms#domain_PaymentRefundsServiceTerms.eligibility_time
    ),
    ok.

-spec validate_transition(activity() | [activity()], change(), st(), change_opts()) -> ok | no_return().
validate_transition(Allowed, Change, St, Opts) ->
    case {Opts, is_transition_valid(Allowed, St)} of
        {#{}, true} ->
            ok;
        {#{validation := strict}, false} ->
            erlang:error({invalid_transition, Change, St, Allowed});
        {#{}, false} ->
            logger:warning(
                "Invalid transition for change ~p in state ~p, allowed ~p",
                [Change, St, Allowed]
            )
    end.

is_transition_valid(Allowed, St) when is_list(Allowed) ->
    lists:any(fun(A) -> is_transition_valid(A, St) end, Allowed);
is_transition_valid(Allowed, #st{activity = Activity}) ->
    Activity =:= Allowed.

%%% Assertion functions

-spec assert_capture_cost_currency(undefined | dmsl_domain_thrift:'Cash'(), payment()) -> ok | no_return().
assert_capture_cost_currency(undefined, _) ->
    ok;
assert_capture_cost_currency(?cash(_, SymCode), #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    ok;
assert_capture_cost_currency(?cash(_, PassedSymCode), #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    throw(#payproc_InconsistentCaptureCurrency{
        payment_currency = SymCode,
        passed_currency = PassedSymCode
    }).

-spec assert_capture_cart(undefined | dmsl_domain_thrift:'Cash'(), undefined | dmsl_domain_thrift:'InvoiceCart'()) ->
    ok | no_return().
assert_capture_cart(_Cost, undefined) ->
    ok;
assert_capture_cart(Cost, Cart) ->
    case Cost =:= hg_invoice_utils:get_cart_amount(Cart) of
        true ->
            ok;
        _ ->
            throw_invalid_request(<<"Capture amount does not match with the cart total amount">>)
    end.

-spec assert_refund_cash(dmsl_domain_thrift:'Cash'(), st()) -> ok | no_return().
assert_refund_cash(Cash, St) ->
    PaymentAmount = get_remaining_payment_amount(Cash, St),
    assert_remaining_payment_amount(PaymentAmount, St).

-spec assert_remaining_payment_amount(dmsl_domain_thrift:'Cash'(), st()) -> ok | no_return().
assert_remaining_payment_amount(?cash(Amount, _), _St) when Amount >= 0 ->
    ok;
assert_remaining_payment_amount(?cash(Amount, _), St) when Amount < 0 ->
    Maximum = hg_invoice_payment:get_remaining_payment_balance(St),
    throw(#payproc_InvoicePaymentAmountExceeded{maximum = Maximum}).

-spec assert_previous_refunds_finished(st()) -> ok | no_return().
assert_previous_refunds_finished(St) ->
    PendingRefunds = lists:filter(
        fun(#payproc_InvoicePaymentRefund{refund = R}) ->
            R#domain_InvoicePaymentRefund.status =:= ?refund_pending()
        end,
        hg_invoice_payment:get_refunds(St)
    ),
    case PendingRefunds of
        [] ->
            ok;
        [_R | _] ->
            throw(#payproc_OperationNotPermitted{})
    end.

-spec assert_refund_cart(undefined | dmsl_domain_thrift:'Cash'(), undefined | dmsl_domain_thrift:'InvoiceCart'(), st()) ->
    ok | no_return().
assert_refund_cart(_RefundCash, undefined, _St) ->
    ok;
assert_refund_cart(undefined, _Cart, _St) ->
    throw_invalid_request(<<"Refund amount does not match with the cart total amount">>);
assert_refund_cart(RefundCash, Cart, St) ->
    InterimPaymentAmount = hg_invoice_payment:get_remaining_payment_balance(St),
    case hg_cash:sub(InterimPaymentAmount, RefundCash) =:= hg_invoice_utils:get_cart_amount(Cart) of
        true ->
            ok;
        _ ->
            throw_invalid_request(<<"Remaining payment amount not equal cart cost">>)
    end.

-spec assert_adjustment_payment_status(payment_status()) -> ok | no_return().
assert_adjustment_payment_status(Status) ->
    case is_adjustment_payment_status_final(Status) of
        true ->
            ok;
        false ->
            erlang:throw(#payproc_InvalidPaymentStatus{status = Status})
    end.

-spec assert_no_refunds(st()) -> ok | no_return().
assert_no_refunds(St) ->
    case hg_invoice_payment:get_refunds_count(St) of
        0 ->
            ok;
        _ ->
            throw_invalid_request(<<"Cannot change status of payment with refunds.">>)
    end.

-spec assert_adjustment_payment_statuses(TargetStatus :: payment_status(), Status :: payment_status()) ->
    ok | no_return().
assert_adjustment_payment_statuses(Status, Status) ->
    erlang:throw(#payproc_InvoicePaymentAlreadyHasStatus{status = Status});
assert_adjustment_payment_statuses(TargetStatus, _Status) ->
    case is_adjustment_payment_status_final(TargetStatus) of
        true ->
            ok;
        false ->
            erlang:throw(#payproc_InvalidPaymentTargetStatus{status = TargetStatus})
    end.

-spec is_adjustment_payment_status_final(payment_status()) -> boolean().
is_adjustment_payment_status_final({captured, _}) ->
    true;
is_adjustment_payment_status_final({cancelled, _}) ->
    true;
is_adjustment_payment_status_final({failed, _}) ->
    true;
is_adjustment_payment_status_final(_) ->
    false.

-spec assert_activity(activity(), st()) -> ok | no_return().
assert_activity(Activity, #st{activity = Activity}) ->
    ok;
assert_activity(_Activity, St) ->
    %% TODO: Create dedicated error like "Payment is capturing already"
    #domain_InvoicePayment{status = Status} = hg_invoice_payment:get_payment(St),
    throw(#payproc_InvalidPaymentStatus{status = Status}).

-spec assert_payment_status(
    payment_status_type() | [payment_status_type()],
    payment()
) -> ok | no_return().
assert_payment_status([Status | _], #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
assert_payment_status([_ | Rest], InvoicePayment) ->
    assert_payment_status(Rest, InvoicePayment);
assert_payment_status(Status, #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
assert_payment_status(_, #domain_InvoicePayment{status = Status}) ->
    throw(#payproc_InvalidPaymentStatus{status = Status}).

-spec assert_no_pending_chargebacks(st()) -> ok | no_return().
assert_no_pending_chargebacks(PaymentState) ->
    Chargebacks = [
        CB#payproc_InvoicePaymentChargeback.chargeback
     || CB <- hg_invoice_payment:get_chargebacks(PaymentState)
    ],
    case lists:any(fun hg_invoice_payment_chargeback:is_pending/1, Chargebacks) of
        true ->
            throw(#payproc_InvoicePaymentChargebackPending{});
        false ->
            ok
    end.

-spec assert_no_adjustment_pending(st()) -> ok | no_return().
assert_no_adjustment_pending(#st{adjustments = As}) ->
    lists:foreach(fun assert_adjustment_finalized/1, As).

-spec assert_adjustment_finalized(dmsl_domain_thrift:'InvoicePaymentAdjustment'()) -> ok | no_return().
assert_adjustment_finalized(#domain_InvoicePaymentAdjustment{id = ID, status = {Status, _}}) when
    Status =:= pending; Status =:= processed
->
    throw(#payproc_InvoicePaymentAdjustmentPending{id = ID});
assert_adjustment_finalized(_) ->
    ok.

-spec assert_payment_flow(hold, payment()) -> ok | no_return().
assert_payment_flow(hold, #domain_InvoicePayment{flow = ?invoice_payment_flow_hold(_, _)}) ->
    ok;
assert_payment_flow(_, _) ->
    throw(#payproc_OperationNotPermitted{}).

-spec assert_adjustment_status(adjustment_status_type(), dmsl_domain_thrift:'InvoicePaymentAdjustment'()) ->
    ok | no_return().
assert_adjustment_status(Status, #domain_InvoicePaymentAdjustment{status = {Status, _}}) ->
    ok;
assert_adjustment_status(_, #domain_InvoicePaymentAdjustment{status = Status}) ->
    throw(#payproc_InvalidPaymentAdjustmentStatus{status = Status}).

%%% Helper functions

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

-spec throw_invalid_request(binary()) -> no_return().
throw_invalid_request(Why) ->
    throw(#base_InvalidRequest{errors = [Why]}).

-spec throw_invalid_recurrent_parent(binary()) -> no_return().
throw_invalid_recurrent_parent(Details) ->
    throw(#payproc_InvalidRecurrentParentPayment{details = Details}).

get_payment_party_config_ref(#domain_InvoicePayment{party_ref = PartyConfigRef}) ->
    PartyConfigRef.

get_payment_cost(#domain_InvoicePayment{changed_cost = Cost}) when Cost /= undefined ->
    Cost;
get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_payment_tool(#domain_InvoicePayment{payer = Payer}) ->
    get_payer_payment_tool(Payer).

get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource);
get_payer_payment_tool(?recurrent_payer(PaymentTool, _, _)) ->
    PaymentTool.

get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

get_payment_created_at(#domain_InvoicePayment{created_at = CreatedAt}) ->
    CreatedAt.

get_refund_cash(#domain_InvoicePaymentRefund{cash = Cash}) ->
    Cash.

get_refund_created_at(#domain_InvoicePaymentRefund{created_at = CreatedAt}) ->
    CreatedAt.

get_remaining_payment_amount(Cash, St) ->
    InterimPaymentAmount = hg_invoice_payment:get_remaining_payment_balance(St),
    hg_cash:sub(InterimPaymentAmount, Cash).
