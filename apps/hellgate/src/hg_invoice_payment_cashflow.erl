%%% Payment cashflow module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Contains all cashflow-related functions.

-module(hg_invoice_payment_cashflow).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").

-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").

-define(LOG_MD(Level, Format, Args), logger:log(Level, Format, Args, logger:get_process_metadata())).

%% Types
-type st() :: hg_invoice_payment:st().
-type payment() :: hg_invoice_payment:payment().
-type payment_status() :: hg_invoice_payment:payment_status().
-type route() :: hg_route:payment_route().
-type varset() :: hg_varset:varset().
-type revision() :: hg_domain:revision().
-type opts() :: hg_invoice_payment:opts().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().
-type domain_refund() :: dmsl_domain_thrift:'InvoicePaymentRefund'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type shop_config_ref() :: dmsl_domain_thrift:'ShopConfigRef'().
-type party_config_ref() :: dmsl_domain_thrift:'PartyConfigRef'().
-type cashflow_context() :: hg_invoice_payment:cashflow_context().
-type payment_institution() :: hg_payment_institution:t().
-type action() :: hg_invoice_payment:action().
-type machine_result() :: hg_invoice_payment:machine_result().

%% Cashflow functions
-export([calculate_cashflow/2]).
-export([calculate_cashflow/3]).
-export([process_cash_flow_building/2]).
-export([make_refund_cashflow/8]).
-export([get_provider_terminal_terms/3]).
-export([get_provider_refunds_terms/3]).
-export([get_provider_partial_refunds_terms/3]).
-export([get_cash_flow_for_status/2]).
-export([get_cash_flow_for_target_status/3]).
-export([collect_chargeback_varset/2]).
-export([collect_refund_varset/3]).
-export([collect_partial_refund_varset/1]).
-export([collect_validation_varset/2]).
-export([collect_validation_varset/4]).

%%% Cashflow functions

-spec calculate_cashflow(cashflow_context(), opts()) -> final_cash_flow().
calculate_cashflow(#{route := Route, revision := Revision} = Context, Opts) ->
    CollectCashflowContext = genlib_map:compact(Context#{
        operation => payment,
        party => get_party_obj(Opts),
        shop => get_shop_obj(Opts, Revision),
        provider => get_route_provider(Route, Revision)
    }),
    hg_cashflow_utils:collect_cashflow(CollectCashflowContext).

-spec calculate_cashflow(payment_institution(), cashflow_context(), opts()) -> final_cash_flow().
calculate_cashflow(PaymentInstitution, #{route := Route, revision := Revision} = Context, Opts) ->
    CollectCashflowContext = genlib_map:compact(Context#{
        operation => payment,
        party => get_party_obj(Opts),
        shop => get_shop_obj(Opts, Revision),
        provider => get_route_provider(Route, Revision)
    }),
    hg_cashflow_utils:collect_cashflow(PaymentInstitution, CollectCashflowContext).

-spec process_cash_flow_building(action(), st()) -> machine_result().
process_cash_flow_building(Action, St) ->
    Route = hg_invoice_payment:get_route(St),
    Opts = hg_invoice_payment:get_opts(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Payment = hg_invoice_payment:get_payment(St),
    Timestamp = get_payment_created_at(Payment),
    VS0 = hg_invoice_payment_construction:reconstruct_payment_flow(Payment, #{}),
    VS1 = collect_validation_varset(
        get_party_config_ref(Opts),
        get_shop_obj(Opts, Revision),
        Payment,
        VS0
    ),
    ProviderTerms = get_provider_terminal_terms(Route, VS1, Revision),
    Allocation = hg_invoice_payment:get_allocation(St),
    Context = #{
        provision_terms => ProviderTerms,
        route => Route,
        payment => Payment,
        timestamp => Timestamp,
        varset => VS1,
        revision => Revision,
        allocation => Allocation
    },
    FinalCashflow = calculate_cashflow(Context, Opts),
    _ = rollback_unused_payment_limits(St),
    _Clock = hg_accounting:hold(
        hg_invoice_payment:construct_payment_plan_id(St),
        {1, FinalCashflow}
    ),
    Events = [?cash_flow_changed(FinalCashflow)],
    {next, {Events, hg_machine_action:set_timeout(0, Action)}}.

-spec make_refund_cashflow(
    domain_refund(),
    payment(),
    revision(),
    st(),
    opts(),
    dmsl_domain_thrift:'PaymentRefundsServiceTerms'(),
    varset(),
    hg_datetime:timestamp()
) -> final_cash_flow().
make_refund_cashflow(Refund, Payment, Revision, St, Opts, MerchantTerms, VS, Timestamp) ->
    Route = hg_invoice_payment:get_route(St),
    ProviderPaymentsTerms = get_provider_terminal_terms(Route, VS, Revision),
    Allocation = Refund#domain_InvoicePaymentRefund.allocation,
    CollectCashflowContext = genlib_map:compact(#{
        operation => refund,
        provision_terms => get_provider_refunds_terms(ProviderPaymentsTerms, Refund, Payment),
        merchant_terms => MerchantTerms,
        party => get_party_obj(Opts),
        shop => get_shop_obj(Opts, Revision),
        route => Route,
        payment => Payment,
        provider => get_route_provider(Route, Revision),
        timestamp => Timestamp,
        varset => VS,
        revision => Revision,
        refund => Refund,
        allocation => Allocation
    }),
    hg_cashflow_utils:collect_cashflow(CollectCashflowContext).

-spec get_provider_terminal_terms(route(), varset(), revision()) ->
    dmsl_domain_thrift:'PaymentsProvisionTerms'() | undefined.
get_provider_terminal_terms(?route(ProviderRef, TerminalRef), VS, Revision) ->
    PreparedVS = hg_varset:prepare_varset(VS),
    {Client, Context} = get_party_client(),
    {ok, TermsSet} = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        Revision,
        PreparedVS,
        Client,
        Context
    ),
    TermsSet#domain_ProvisionTermSet.payments.

-spec get_provider_refunds_terms(
    dmsl_domain_thrift:'PaymentsProvisionTerms'() | undefined,
    domain_refund(),
    payment()
) -> dmsl_domain_thrift:'PaymentRefundsProvisionTerms'().
get_provider_refunds_terms(
    #domain_PaymentsProvisionTerms{refunds = Terms},
    Refund,
    Payment
) when Terms /= undefined ->
    Cost = get_payment_cost(Payment),
    Cash = get_refund_cash(Refund),
    case hg_cash:sub(Cost, Cash) of
        ?cash(0, _) ->
            Terms;
        ?cash(Amount, _) when Amount > 0 ->
            get_provider_partial_refunds_terms(Terms, Refund, Payment)
    end;
get_provider_refunds_terms(#domain_PaymentsProvisionTerms{refunds = undefined}, _Refund, Payment) ->
    error({misconfiguration, {'No refund terms for a payment', Payment}}).

-spec get_provider_partial_refunds_terms(
    dmsl_domain_thrift:'PaymentRefundsProvisionTerms'(),
    domain_refund(),
    payment()
) -> dmsl_domain_thrift:'PaymentRefundsProvisionTerms'().
get_provider_partial_refunds_terms(
    #domain_PaymentRefundsProvisionTerms{
        partial_refunds = #domain_PartialRefundsProvisionTerms{
            cash_limit = CashLimitSelector
        }
    } = Terms,
    Refund,
    _Payment
) ->
    Cash = get_refund_cash(Refund),
    CashRange = get_selector_value(cash_limit, CashLimitSelector),
    case hg_cash_range:is_inside(Cash, CashRange) of
        within ->
            Terms;
        {exceeds, _} ->
            error({misconfiguration, {'Refund amount doesnt match allowed cash range', CashRange}})
    end;
get_provider_partial_refunds_terms(
    #domain_PaymentRefundsProvisionTerms{partial_refunds = undefined},
    _Refund,
    Payment
) ->
    error({misconfiguration, {'No partial refund terms for a payment', Payment}}).

-spec get_cash_flow_for_status(payment_status(), st()) -> final_cash_flow().
get_cash_flow_for_status({captured, _}, St) ->
    hg_invoice_payment:get_final_cashflow(St);
get_cash_flow_for_status({cancelled, _}, _St) ->
    [];
get_cash_flow_for_status({failed, _}, _St) ->
    [].

-spec get_cash_flow_for_target_status(payment_status(), st(), opts()) -> final_cash_flow().
get_cash_flow_for_target_status({captured, Captured}, St0, Opts) ->
    Payment0 = hg_invoice_payment:get_payment(St0),
    Route = hg_invoice_payment:get_route(St0),
    Cost = get_captured_cost(Captured, Payment0),
    Allocation = get_captured_allocation(Captured),
    Payment1 = Payment0#domain_InvoicePayment{
        cost = Cost
    },
    Payment2 =
        case Payment1 of
            #domain_InvoicePayment{changed_cost = ChangedCost} when ChangedCost =/= undefined ->
                Payment1#domain_InvoicePayment{
                    cost = ChangedCost
                };
            _ ->
                Payment1
        end,
    Timestamp = get_payment_created_at(Payment2),
    St = St0#st{payment = Payment2},
    Revision = Payment2#domain_InvoicePayment.domain_revision,
    VS = collect_validation_varset(St, Opts),
    Context = #{
        provision_terms => get_provider_terminal_terms(Route, VS, Revision),
        route => Route,
        payment => Payment2,
        timestamp => Timestamp,
        varset => VS,
        revision => Revision,
        allocation => Allocation
    },
    calculate_cashflow(Context, Opts);
get_cash_flow_for_target_status({cancelled, _}, _St, _Opts) ->
    [];
get_cash_flow_for_target_status({failed, _}, _St, _Opts) ->
    [].

-spec collect_chargeback_varset(
    dmsl_domain_thrift:'PaymentChargebackServiceTerms'() | undefined,
    varset()
) -> varset().
collect_chargeback_varset(
    #domain_PaymentChargebackServiceTerms{},
    VS
) ->
    % nothing here yet
    VS;
collect_chargeback_varset(undefined, VS) ->
    VS.

-spec collect_refund_varset(
    undefined
    | dmsl_domain_thrift:'PaymentRefundsServiceTerms'()
    | dmsl_domain_thrift:'PaymentsServiceTerms'()
    | {value, dmsl_domain_thrift:'PaymentRefundsServiceTerms'()},
    payment_tool(),
    varset()
) -> varset().
collect_refund_varset(Terms, PaymentTool, VS) ->
    case normalize_refund_terms(Terms) of
        #domain_PaymentRefundsServiceTerms{
            payment_methods = PaymentMethodSelector,
            partial_refunds = PartialRefundsServiceTerms
        } ->
            RPMs = get_selector_value(payment_methods, PaymentMethodSelector),
            case hg_payment_tool:has_any_payment_method(PaymentTool, RPMs) of
                true ->
                    RVS = collect_partial_refund_varset(PartialRefundsServiceTerms),
                    VS#{refunds => RVS};
                false ->
                    VS
            end;
        undefined ->
            VS
    end.

normalize_refund_terms(#domain_PaymentRefundsServiceTerms{} = Terms) ->
    Terms;
normalize_refund_terms(#domain_PaymentsServiceTerms{refunds = Terms}) ->
    normalize_refund_terms(Terms);
normalize_refund_terms({value, Terms}) ->
    normalize_refund_terms(Terms);
normalize_refund_terms(undefined) ->
    undefined;
normalize_refund_terms(Other) ->
    error({misconfiguration, {'Unexpected refund terms', Other}}).

-spec collect_partial_refund_varset(
    dmsl_domain_thrift:'PartialRefundsServiceTerms'() | undefined
) -> map().
collect_partial_refund_varset(
    #domain_PartialRefundsServiceTerms{
        cash_limit = CashLimitSelector
    }
) ->
    #{
        partial => #{
            cash_limit => get_selector_value(cash_limit, CashLimitSelector)
        }
    };
collect_partial_refund_varset(undefined) ->
    #{}.

-spec collect_validation_varset(st(), opts()) -> varset().
collect_validation_varset(St, Opts) ->
    Revision = hg_invoice_payment:get_payment_revision(St),
    collect_validation_varset(
        get_party_config_ref(Opts),
        get_shop_obj(Opts, Revision),
        hg_invoice_payment:get_payment(St),
        #{}
    ).

-spec collect_validation_varset(party_config_ref(), {shop_config_ref(), shop()}, payment(), varset()) -> varset().
collect_validation_varset(PartyConfigRef, ShopObj, Payment, VS) ->
    Cost = #domain_Cash{currency = Currency} = get_payment_cost(Payment),
    VS0 = collect_validation_varset_(PartyConfigRef, ShopObj, Currency, VS),
    VS0#{
        cost => Cost,
        payment_tool => get_payment_tool(Payment)
    }.

%%% Internal helper functions

collect_validation_varset_(PartyConfigRef, {#domain_ShopConfigRef{id = ShopConfigID}, Shop}, Currency, VS) ->
    #domain_ShopConfig{
        category = Category
    } = Shop,
    VS#{
        party_config_ref => PartyConfigRef,
        shop_id => ShopConfigID,
        category => Category,
        currency => Currency
    }.

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

get_party_client() ->
    HgContext = hg_context:load(),
    Client = hg_context:get_party_client(HgContext),
    Context = hg_context:get_party_client_context(HgContext),
    {Client, Context}.

get_route_provider_ref(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

get_route_provider(Route, Revision) ->
    hg_domain:get(Revision, {provider, get_route_provider_ref(Route)}).

get_party_obj(#{party := Party, party_config_ref := PartyConfigRef}) ->
    {PartyConfigRef, Party}.

get_party_config_ref(#{party_config_ref := PartyConfigRef}) ->
    PartyConfigRef.

get_shop_obj(#{invoice := Invoice, party_config_ref := PartyConfigRef}, Revision) ->
    hg_party:get_shop(get_invoice_shop_config_ref(Invoice), PartyConfigRef, Revision).

get_invoice_shop_config_ref(#domain_Invoice{shop_ref = ShopConfigRef}) ->
    ShopConfigRef.

get_payment_cost(#domain_InvoicePayment{changed_cost = Cost}) when Cost =/= undefined ->
    Cost;
get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_payment_tool(#domain_InvoicePayment{payer = Payer}) ->
    hg_invoice_payment:get_payer_payment_tool(Payer).

get_payment_created_at(#domain_InvoicePayment{created_at = CreatedAt}) ->
    CreatedAt.

get_captured_cost(#domain_InvoicePaymentCaptured{cost = Cost}, _) when Cost /= undefined ->
    Cost;
get_captured_cost(_, #domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_captured_allocation(#domain_InvoicePaymentCaptured{allocation = Allocation}) ->
    Allocation.

get_refund_cash(#domain_InvoicePaymentRefund{cash = Cash}) ->
    Cash.

rollback_unused_payment_limits(St) ->
    Route = hg_invoice_payment:get_route(St),
    Routes = get_candidate_routes_internal(St),
    UnUsedRoutes = Routes -- [Route],
    rollback_payment_limits_internal(UnUsedRoutes, hg_invoice_payment:get_iter(St), St, [
        ignore_business_error, ignore_not_found
    ]).

get_candidate_routes_internal(#st{candidate_routes = undefined}) ->
    [];
get_candidate_routes_internal(#st{candidate_routes = Routes}) ->
    Routes.

rollback_payment_limits_internal(Routes, Iter, St, Flags) ->
    Opts = hg_invoice_payment:get_opts(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Payment = hg_invoice_payment:get_payment(St),
    Invoice = get_invoice_internal(Opts),
    VS = get_varset_internal(St, Revision),
    lists:foreach(
        fun(Route) ->
            ProviderTerms = hg_routing:get_payment_terms(Route, VS, Revision),
            TurnoverLimits = get_turnover_limits_internal(ProviderTerms, strict),
            ok = hg_limiter:rollback_payment_limits(TurnoverLimits, Invoice, Payment, Route, Iter, Flags)
        end,
        Routes
    ).

get_invoice_internal(#{invoice := Invoice}) ->
    Invoice.

get_varset_internal(St, _Revision) ->
    Opts = hg_invoice_payment:get_opts(St),
    collect_validation_varset(St, Opts).

get_turnover_limits_internal(ProviderTerms, Mode) ->
    hg_limiter:get_turnover_limits(ProviderTerms, Mode).
