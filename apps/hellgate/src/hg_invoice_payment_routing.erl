%%% Payment routing module
%%%
%%% Extracted from hg_invoice_payment.erl for better code organization.
%%% Contains all routing-related functions.

-module(hg_invoice_payment_routing).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").

-include_lib("hellgate/include/domain.hrl").

-include("domain.hrl").
-include("payment_events.hrl").
-include("hg_invoice_payment.hrl").

-define(LOG_MD(Level, Format, Args), logger:log(Level, Format, Args, logger:get_process_metadata())).

%% Types
-type st() :: hg_invoice_payment:st().
-type payment() :: hg_invoice_payment:payment().
-type action() :: hg_invoice_payment:action().
-type machine_result() :: hg_invoice_payment:machine_result().
-type risk_score() :: hg_inspector:risk_score().
-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type varset() :: hg_varset:varset().
-type revision() :: hg_domain:revision().
-type route() :: hg_route:payment_route().
-type routing_ctx() :: hg_routing_ctx:t().

%% Routing functions
-export([gather_routes/4]).
-export([choose_routing_predestination/1]).
-export([log_route_choice_meta/2]).
-export([log_rejected_routes/3]).
-export([filter_attempted_routes/2]).
-export([handle_choose_route_error/4]).
-export([process_routing/2]).
-export([process_risk_score/2]).
-export([check_risk_score/1]).
-export([get_routing_attempt_limit/1]).
-export([route_args/1]).
-export([build_routing_context/4]).

%% Internal helper functions (exported for use within module)
-export([maybe_log_misconfigurations/1]).
-export([log_cascade_attempt_context/2]).

%%% Routing functions

-spec gather_routes(payment_institution(), varset(), revision(), st()) -> routing_ctx().
gather_routes(PaymentInstitution, VS, Revision, St) ->
    Payment = hg_invoice_payment:get_payment(St),
    Predestination = choose_routing_predestination(Payment),
    #domain_Cash{currency = Currency} = get_payment_cost_internal(Payment),
    Payer = Payment#domain_InvoicePayment.payer,
    #domain_ContactInfo{email = Email} = get_contact_info(Payer),
    CardToken = get_payer_card_token(Payer),
    PaymentTool = hg_invoice_payment:get_payer_payment_tool(Payer),
    ClientIP = get_payer_client_ip(Payer),
    hg_routing:gather_routes(Predestination, PaymentInstitution, VS, Revision, #{
        currency => Currency,
        payment_tool => PaymentTool,
        client_ip => ClientIP,
        email => Email,
        card_token => CardToken
    }).

-spec check_risk_score(risk_score()) -> ok | {error, risk_score_is_too_high}.
check_risk_score(fatal) ->
    {error, risk_score_is_too_high};
check_risk_score(_RiskScore) ->
    ok.

-spec choose_routing_predestination(payment()) -> hg_routing:route_predestination().
choose_routing_predestination(#domain_InvoicePayment{make_recurrent = true}) ->
    recurrent_payment;
choose_routing_predestination(#domain_InvoicePayment{payer = ?payment_resource_payer()}) ->
    payment.

-spec log_route_choice_meta(map(), revision()) -> ok.
log_route_choice_meta(#{choice_meta := undefined}, _Revision) ->
    ok;
log_route_choice_meta(#{choice_meta := ChoiceMeta}, Revision) ->
    Metadata = hg_routing:get_logger_metadata(ChoiceMeta, Revision),
    logger:log(notice, "Routing decision made", #{routing => Metadata}).

-spec maybe_log_misconfigurations(term()) -> ok.
maybe_log_misconfigurations({misconfiguration, _} = Error) ->
    {Format, Details} = hg_routing:prepare_log_message(Error),
    ?LOG_MD(warning, Format, Details);
maybe_log_misconfigurations(_Error) ->
    ok.

-spec log_rejected_routes(atom(), [hg_route:rejected_route()], varset()) -> ok.
log_rejected_routes(_, [], _VS) ->
    ok;
log_rejected_routes(all, Routes, VS) ->
    ?LOG_MD(warning, "No route found for varset: ~p", [VS]),
    ?LOG_MD(warning, "No route found, rejected routes: ~p", [Routes]);
log_rejected_routes(limit_misconfiguration, Routes, _VS) ->
    ?LOG_MD(warning, "Limiter hold error caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(limit_overflow, Routes, _VS) ->
    ?LOG_MD(notice, "Limit overflow caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(in_blacklist, Routes, _VS) ->
    ?LOG_MD(notice, "Route candidates are blacklisted: ~p", [Routes]);
log_rejected_routes(adapter_unavailable, Routes, _VS) ->
    ?LOG_MD(notice, "Adapter unavailability caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(provider_conversion_is_too_low, Routes, _VS) ->
    ?LOG_MD(notice, "Lacking conversion of provider caused route candidates to be rejected: ~p", [Routes]);
log_rejected_routes(forbidden, Routes, VS) ->
    ?LOG_MD(notice, "Rejected routes found for varset: ~p", [VS]),
    ?LOG_MD(notice, "Rejected routes found, rejected routes: ~p", [Routes]);
log_rejected_routes(_, _Routes, _VS) ->
    ok.

-spec process_risk_score(action(), st()) -> machine_result().
process_risk_score(Action, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Payment = hg_invoice_payment:get_payment(St),
    VS1 = get_varset_internal(St, #{}),
    PaymentInstitutionRef = get_payment_institution_ref(Opts, Revision),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    RiskScore = repair_inspect(Payment, PaymentInstitution, Opts, St),
    Events = [?risk_score_changed(RiskScore)],
    case check_risk_score(RiskScore) of
        ok ->
            {next, {Events, hg_machine_action:set_timeout(0, Action)}};
        {error, risk_score_is_too_high = Reason} ->
            logger:notice("No route found, reason = ~p, varset: ~p", [Reason, VS1]),
            handle_choose_route_error(Reason, Events, St, Action)
    end.

-spec process_routing(action(), st()) -> machine_result().
process_routing(Action, St) ->
    {PaymentInstitution, VS, Revision} = route_args(St),
    Ctx0 = hg_routing_ctx:with_guard(build_routing_context(PaymentInstitution, VS, Revision, St)),
    %% NOTE We need to handle routing errors differently if route not found
    %% before the pipeline.
    case hg_routing_ctx:error(Ctx0) of
        undefined ->
            Ctx1 = run_routing_decision_pipeline(Ctx0, VS, St),
            _ = [
                log_rejected_routes(Group, RejectedRoutes, VS)
             || {Group, RejectedRoutes} <- hg_routing_ctx:rejections(Ctx1)
            ],
            Events = produce_routing_events(Ctx1, Revision, St),
            {next, {Events, hg_machine_action:set_timeout(0, Action)}};
        Error ->
            ok = maybe_log_misconfigurations(Error),
            ok = log_rejected_routes(all, hg_routing_ctx:rejected_routes(Ctx0), VS),
            handle_choose_route_error(Error, [], St, Action)
    end.

-spec route_args(st()) -> {payment_institution(), varset(), revision()}.
route_args(St) ->
    Opts = hg_invoice_payment:get_opts(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Payment = hg_invoice_payment:get_payment(St),
    #{payment_tool := PaymentTool} =
        VS1 = get_varset_internal(St, #{risk_score => hg_invoice_payment:get_risk_score(St)}),
    CreatedAt = hg_invoice_payment:get_payment_created_at(Payment),
    PaymentInstitutionRef = get_payment_institution_ref(Opts, Revision),
    MerchantTerms = get_merchant_payments_terms(Opts, Revision, CreatedAt, VS1),
    VS2 = collect_refund_varset(MerchantTerms#domain_PaymentsServiceTerms.refunds, PaymentTool, VS1),
    VS3 = collect_chargeback_varset(MerchantTerms#domain_PaymentsServiceTerms.chargebacks, VS2),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    {PaymentInstitution, VS3, Revision}.

-spec build_routing_context(payment_institution(), varset(), revision(), st()) -> routing_ctx().
build_routing_context(PaymentInstitution, VS, Revision, St) ->
    Payer = hg_invoice_payment:get_payment_payer(St),
    case hg_invoice_payment_construction:get_predefined_route(Payer) of
        {ok, PaymentRoute} ->
            hg_routing_ctx:new([hg_route:from_payment_route(PaymentRoute)]);
        undefined ->
            gather_routes(PaymentInstitution, VS, Revision, St)
    end.

-spec filter_attempted_routes(routing_ctx(), st()) -> routing_ctx().
filter_attempted_routes(Ctx, #st{routes = AttemptedRoutes}) ->
    lists:foldr(
        fun(R, C) ->
            R1 = hg_route:from_payment_route(R),
            R2 = hg_route:to_rejected_route(R1, {'AlreadyAttempted', undefined}),
            hg_routing_ctx:reject(already_attempted, R2, C)
        end,
        Ctx,
        AttemptedRoutes
    ).

-spec handle_choose_route_error(term(), hg_invoice_payment:events(), st(), action()) -> machine_result().
handle_choose_route_error(Error, Events, St, Action) ->
    Failure = hg_invoice_payment_construction:construct_routing_failure(Error),
    hg_invoice_payment:process_failure(hg_invoice_payment:get_activity(St), Events, Action, Failure, St).

-spec get_routing_attempt_limit(st()) -> pos_integer().
get_routing_attempt_limit(
    #st{
        payment = #domain_InvoicePayment{
            party_ref = PartyConfigRef,
            shop_ref = ShopConfigRef,
            domain_revision = Revision
        }
    } = St
) ->
    {PartyConfigRef, _Party} = hg_party:checkout(PartyConfigRef, Revision),
    ShopObj = {_, Shop} = hg_party:get_shop(ShopConfigRef, PartyConfigRef, Revision),
    VS = collect_validation_varset(PartyConfigRef, ShopObj, hg_invoice_payment:get_payment(St), #{}),
    Terms = hg_invoice_utils:compute_shop_terms(Revision, Shop, VS),
    #domain_TermSet{payments = PaymentTerms} = Terms,
    log_cascade_attempt_context(PaymentTerms, St),
    get_routing_attempt_limit_value(PaymentTerms#domain_PaymentsServiceTerms.attempt_limit).

%%% Helper functions

-spec run_routing_decision_pipeline(routing_ctx(), varset(), st()) -> routing_ctx().
run_routing_decision_pipeline(Ctx0, VS, St) ->
    %% NOTE Since this is routing step then current attempt is not yet
    %% accounted for in `St`.
    NewIter = hg_invoice_payment:get_iter(St) + 1,
    hg_routing_ctx:pipeline(
        Ctx0,
        [
            fun(Ctx) -> filter_attempted_routes(Ctx, St) end,
            fun(Ctx) -> filter_routes_with_limit_hold(Ctx, VS, NewIter, St) end,
            fun(Ctx) -> filter_routes_by_limit_overflow(Ctx, VS, NewIter, St) end,
            fun(Ctx) -> hg_routing:filter_by_blacklist(Ctx, build_blacklist_context(St)) end,
            fun hg_routing:filter_by_critical_provider_status/1,
            fun hg_routing:choose_route_with_ctx/1
        ]
    ).

-spec produce_routing_events(routing_ctx(), revision(), st()) -> hg_invoice_payment:events().
produce_routing_events(#{error := Error} = Ctx, Revision, St) when Error =/= undefined ->
    %% TODO Pass failure subcode from error. Say, if last candidates were
    %% rejected because of provider gone critical, then use subcode to highlight
    %% the offender. Like 'provider_dead' or 'conversion_lacking'.
    Failure = genlib:define(St#st.failure, hg_invoice_payment_construction:construct_routing_failure(Error)),
    %% NOTE Not all initial candidates have their according limits held. And so
    %% we must account only for those that can be rolled back.
    RollbackableCandidates = hg_routing_ctx:accounted_candidates(Ctx),
    Route = hg_route:to_payment_route(hd(RollbackableCandidates)),
    Candidates =
        ordsets:from_list([hg_route:to_payment_route(R) || R <- RollbackableCandidates]),
    RouteScores = hg_routing_ctx:route_scores(Ctx),
    RouteLimits = hg_routing_ctx:route_limits(Ctx),
    Decision = build_route_decision_context(Route, Revision),
    %% For protocol compatability we set choosen route in route_changed event.
    %% It doesn't influence cash_flow building because this step will be
    %% skipped. And all limit's 'hold' operations will be rolled back.
    %% For same purpose in cascade routing we use route from unfiltered list of
    %% originally resolved candidates.
    [?route_changed(Route, Candidates, RouteScores, RouteLimits, Decision), ?payment_rollback_started(Failure)];
produce_routing_events(Ctx, Revision, _St) ->
    ok = log_route_choice_meta(Ctx, Revision),
    Route = hg_route:to_payment_route(hg_routing_ctx:choosen_route(Ctx)),
    Candidates =
        ordsets:from_list([hg_route:to_payment_route(R) || R <- hg_routing_ctx:considered_candidates(Ctx)]),
    RouteScores = hg_routing_ctx:route_scores(Ctx),
    RouteLimits = hg_routing_ctx:route_limits(Ctx),
    Decision = build_route_decision_context(Route, Revision),
    [?route_changed(Route, Candidates, RouteScores, RouteLimits, Decision)].

-spec build_route_decision_context(route(), revision()) -> dmsl_payproc_thrift:'RouteDecisionContext'().
build_route_decision_context(Route, Revision) ->
    ProvisionTerms = hg_routing:get_provision_terms(Route, #{}, Revision),
    SkipRecurrent =
        case ProvisionTerms#domain_ProvisionTermSet.extension of
            #domain_ExtendedProvisionTerms{skip_recurrent = true} ->
                true;
            _ ->
                undefined
        end,
    #payproc_RouteDecisionContext{skip_recurrent = SkipRecurrent}.

-spec build_blacklist_context(st()) -> map().
build_blacklist_context(St) ->
    Revision = hg_invoice_payment:get_payment_revision(St),
    #domain_InvoicePayment{payer = Payer} = hg_invoice_payment:get_payment(St),
    Token =
        case hg_invoice_payment:get_payer_payment_tool(Payer) of
            {bank_card, #domain_BankCard{token = CardToken}} ->
                CardToken;
            _ ->
                undefined
        end,
    Opts = hg_invoice_payment:get_opts(St),
    VS1 = get_varset_internal(St, #{}),
    PaymentInstitutionRef = get_payment_institution_ref(Opts, Revision),
    PaymentInstitution = hg_payment_institution:compute_payment_institution(PaymentInstitutionRef, VS1, Revision),
    InspectorRef = get_selector_value(inspector, PaymentInstitution#domain_PaymentInstitution.inspector),
    Inspector = hg_domain:get(Revision, {inspector, InspectorRef}),
    #{
        revision => Revision,
        token => Token,
        inspector => Inspector
    }.

-spec log_cascade_attempt_context(dmsl_domain_thrift:'PaymentsServiceTerms'(), st()) -> ok.
log_cascade_attempt_context(
    #domain_PaymentsServiceTerms{attempt_limit = AttemptLimit},
    #st{routes = AttemptedRoutes}
) ->
    ?LOG_MD(notice, "Cascade context: merchant payment terms' attempt limit '~p', attempted routes: ~p", [
        AttemptLimit, AttemptedRoutes
    ]).

-spec get_routing_attempt_limit_value(undefined | dmsl_domain_thrift:'AttemptLimitSelector'()) -> pos_integer().
get_routing_attempt_limit_value(undefined) ->
    1;
get_routing_attempt_limit_value({decisions, _}) ->
    get_routing_attempt_limit_value(undefined);
get_routing_attempt_limit_value({value, #domain_AttemptLimit{attempts = Value}}) when is_integer(Value) ->
    Value.

%%% Internal helper functions

-spec filter_routes_with_limit_hold(routing_ctx(), varset(), pos_integer(), st()) -> routing_ctx().
filter_routes_with_limit_hold(Ctx0, VS, Iter, St) ->
    {_Routes, RejectedRoutes} = hold_limit_routes(hg_routing_ctx:candidates(Ctx0), VS, Iter, St),
    Ctx1 = reject_routes(limit_misconfiguration, RejectedRoutes, Ctx0),
    hg_routing_ctx:stash_current_candidates(Ctx1).

-spec filter_routes_by_limit_overflow(routing_ctx(), varset(), pos_integer(), st()) -> routing_ctx().
filter_routes_by_limit_overflow(Ctx0, VS, Iter, St) ->
    {_Routes, RejectedRoutes, Limits} = get_limit_overflow_routes(hg_routing_ctx:candidates(Ctx0), VS, Iter, St),
    Ctx1 = hg_routing_ctx:stash_route_limits(Limits, Ctx0),
    reject_routes(limit_overflow, RejectedRoutes, Ctx1).

-spec reject_routes(atom(), [hg_route:rejected_route()], routing_ctx()) -> routing_ctx().
reject_routes(GroupReason, RejectedRoutes, Ctx) ->
    lists:foldr(
        fun(R, C) -> hg_routing_ctx:reject(GroupReason, R, C) end,
        Ctx,
        RejectedRoutes
    ).

-spec hold_limit_routes([hg_route:t()], varset(), pos_integer(), st()) ->
    {[hg_route:t()], [hg_route:rejected_route()]}.
hold_limit_routes(Routes0, VS, Iter, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Payment = hg_invoice_payment:get_payment(St),
    Invoice = hg_invoice_payment:get_invoice(Opts),
    {Routes1, Rejected} = lists:foldl(
        fun(Route, {LimitHeldRoutes, RejectedRoutes} = Acc) ->
            PaymentRoute = hg_route:to_payment_route(Route),
            ProviderTerms = hg_routing:get_payment_terms(PaymentRoute, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms, strict),
            try
                ok = hg_limiter:hold_payment_limits(TurnoverLimits, Invoice, Payment, PaymentRoute, Iter),
                {[Route | LimitHeldRoutes], RejectedRoutes}
            catch
                error:(#limiter_LimitNotFound{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc);
                error:(#limiter_InvalidOperationCurrency{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc);
                error:(#limiter_OperationContextNotSupported{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc);
                error:(#limiter_PaymentToolNotSupported{} = LimiterError) ->
                    do_reject_route(LimiterError, Route, TurnoverLimits, Acc)
            end
        end,
        {[], []},
        Routes0
    ),
    {lists:reverse(Routes1), Rejected}.

-spec do_reject_route(
    term(), hg_route:t(), [dmsl_domain_thrift:'TurnoverLimit'()], {[hg_route:t()], [hg_route:rejected_route()]}
) ->
    {[hg_route:t()], [hg_route:rejected_route()]}.
do_reject_route(LimiterError, Route, TurnoverLimits, {LimitHeldRoutes, RejectedRoutes}) ->
    LimitsIDs = [T#domain_TurnoverLimit.ref#domain_LimitConfigRef.id || T <- TurnoverLimits],
    RejectedRoute = hg_route:to_rejected_route(Route, {'LimitHoldError', LimitsIDs, LimiterError}),
    {LimitHeldRoutes, [RejectedRoute | RejectedRoutes]}.

-spec get_limit_overflow_routes([hg_route:t()], varset(), pos_integer(), st()) ->
    {[hg_route:t()], [hg_route:rejected_route()], hg_routing:limits()}.
get_limit_overflow_routes(Routes, VS, Iter, St) ->
    Opts = hg_invoice_payment:get_opts(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    Payment = hg_invoice_payment:get_payment(St),
    Invoice = hg_invoice_payment:get_invoice(Opts),
    lists:foldl(
        fun(Route, {RoutesNoOverflowIn, RejectedIn, LimitsIn}) ->
            PaymentRoute = hg_route:to_payment_route(Route),
            ProviderTerms = hg_routing:get_payment_terms(PaymentRoute, VS, Revision),
            TurnoverLimits = get_turnover_limits(ProviderTerms, strict),
            case hg_limiter:check_limits(TurnoverLimits, Invoice, Payment, PaymentRoute, Iter) of
                {ok, Limits} ->
                    {[Route | RoutesNoOverflowIn], RejectedIn, LimitsIn#{PaymentRoute => Limits}};
                {error, {limit_overflow, IDs, Limits}} ->
                    RejectedRoute = hg_route:to_rejected_route(Route, {'LimitOverflow', IDs}),
                    {RoutesNoOverflowIn, [RejectedRoute | RejectedIn], LimitsIn#{PaymentRoute => Limits}}
            end
        end,
        {[], [], #{}},
        Routes
    ).

-spec get_turnover_limits(dmsl_domain_thrift:'PaymentsProvisionTerms'(), strict) ->
    [dmsl_domain_thrift:'TurnoverLimit'()].
get_turnover_limits(ProviderTerms, strict) ->
    hg_limiter:get_turnover_limits(ProviderTerms, strict).

-spec repair_inspect(payment(), payment_institution(), hg_invoice_payment:opts(), st()) -> risk_score().
repair_inspect(Payment, PaymentInstitution, Opts, #st{repair_scenario = Scenario}) ->
    case hg_invoice_repair:check_for_action(skip_inspector, Scenario) of
        {result, Result} ->
            Result;
        call ->
            inspect(Payment, PaymentInstitution, Opts)
    end.

-spec inspect(payment(), payment_institution(), hg_invoice_payment:opts()) -> risk_score().
inspect(#domain_InvoicePayment{domain_revision = Revision} = Payment, PaymentInstitution, Opts) ->
    InspectorRef = get_selector_value(inspector, PaymentInstitution#domain_PaymentInstitution.inspector),
    Inspector = hg_domain:get(Revision, {inspector, InspectorRef}),
    hg_inspector:inspect(get_shop(Opts, Revision), hg_invoice_payment:get_invoice(Opts), Payment, Inspector).

%%% Helper functions that need to access hg_invoice_payment internals

-spec get_contact_info(dmsl_domain_thrift:'Payer'()) -> dmsl_domain_thrift:'ContactInfo'().
get_contact_info(?payment_resource_payer(_, ContactInfo)) ->
    ContactInfo;
get_contact_info(?recurrent_payer(_, _, ContactInfo)) ->
    ContactInfo.

-spec get_payer_card_token(dmsl_domain_thrift:'Payer'()) -> undefined | dmsl_domain_thrift:'Token'().
get_payer_card_token(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    case get_resource_payment_tool(PaymentResource) of
        {bank_card, #domain_BankCard{token = Token}} ->
            Token;
        _ ->
            undefined
    end;
get_payer_card_token(?recurrent_payer(_, _, _)) ->
    undefined.

-spec get_payer_client_ip(dmsl_domain_thrift:'Payer'()) -> undefined | dmsl_domain_thrift:'IPAddress'().
get_payer_client_ip(
    ?payment_resource_payer(
        #domain_DisposablePaymentResource{
            client_info = #domain_ClientInfo{
                ip_address = IP
            }
        },
        _ContactInfo
    )
) ->
    IP;
get_payer_client_ip(_OtherPayer) ->
    undefined.

-spec get_resource_payment_tool(dmsl_domain_thrift:'DisposablePaymentResource'()) -> dmsl_domain_thrift:'PaymentTool'().
get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

-spec get_payment_institution_ref(hg_invoice_payment:opts(), revision()) ->
    dmsl_domain_thrift:'PaymentInstitutionRef'().
get_payment_institution_ref(Opts, Revision) ->
    Shop = get_shop(Opts, Revision),
    Shop#domain_ShopConfig.payment_institution.

-spec get_shop(hg_invoice_payment:opts(), revision()) -> dmsl_domain_thrift:'ShopConfig'().
get_shop(Opts, Revision) ->
    {_, Shop} = get_shop_obj(Opts, Revision),
    Shop.

-spec get_shop_obj(hg_invoice_payment:opts(), revision()) ->
    {dmsl_domain_thrift:'ShopConfigRef'(), dmsl_domain_thrift:'ShopConfig'()}.
get_shop_obj(#{invoice := #domain_Invoice{shop_ref = ShopConfigRef}, party_config_ref := PartyConfigRef}, Revision) ->
    hg_party:get_shop(ShopConfigRef, PartyConfigRef, Revision).

-spec get_merchant_payments_terms(hg_invoice_payment:opts(), revision(), dmsl_base_thrift:'Timestamp'(), varset()) ->
    dmsl_domain_thrift:'PaymentsServiceTerms'().
get_merchant_payments_terms(Opts, Revision, _Timestamp, VS) ->
    ShopObj = get_shop_obj(Opts, Revision),
    Terms = hg_invoice_utils:compute_shop_terms(Revision, element(2, ShopObj), VS),
    Terms#domain_TermSet.payments.

-spec collect_refund_varset(
    undefined
    | dmsl_domain_thrift:'PaymentRefundsServiceTerms'()
    | dmsl_domain_thrift:'PaymentsServiceTerms'()
    | {value, dmsl_domain_thrift:'PaymentRefundsServiceTerms'()},
    dmsl_domain_thrift:'PaymentTool'(),
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

-spec collect_partial_refund_varset(undefined | dmsl_domain_thrift:'PartialRefundsServiceTerms'()) -> map().
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

-spec collect_chargeback_varset(
    undefined | dmsl_domain_thrift:'PaymentChargebackServiceTerms'(),
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

-spec collect_validation_varset(
    dmsl_domain_thrift:'PartyConfigRef'(),
    {dmsl_domain_thrift:'ShopConfigRef'(), dmsl_domain_thrift:'ShopConfig'()},
    payment(),
    varset()
) -> varset().
collect_validation_varset(PartyConfigRef, {#domain_ShopConfigRef{id = ShopConfigID}, Shop}, Payment, VS) ->
    #domain_InvoicePayment{cost = Cost, payer = Payer} = Payment,
    #domain_Cash{currency = CurrencyRef} = Cost,
    #domain_ShopConfig{category = Category} = Shop,
    PaymentTool = hg_invoice_payment:get_payer_payment_tool(Payer),
    VS#{
        party_config_ref => PartyConfigRef,
        party_id => PartyConfigRef#domain_PartyConfigRef.id,
        shop_id => ShopConfigID,
        category => Category,
        currency => CurrencyRef,
        cost => Cost,
        payment_tool => PaymentTool
    }.

-spec get_selector_value(atom(), term()) -> term().
get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

-spec get_payment_cost_internal(payment()) -> dmsl_domain_thrift:'Cash'().
get_payment_cost_internal(#domain_InvoicePayment{changed_cost = Cost}) when Cost =/= undefined ->
    Cost;
get_payment_cost_internal(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

-spec get_varset_internal(st(), varset()) -> varset().
get_varset_internal(St, InitialValue) ->
    Opts = hg_invoice_payment:get_opts(St),
    Payment = hg_invoice_payment:get_payment(St),
    Revision = hg_invoice_payment:get_payment_revision(St),
    VS0 = hg_invoice_payment_construction:reconstruct_payment_flow(Payment, InitialValue),
    VS1 = collect_validation_varset(get_party_config_ref(Opts), get_shop_obj(Opts, Revision), Payment, VS0),
    VS1.

-spec get_party_config_ref(hg_invoice_payment:opts()) -> dmsl_domain_thrift:'PartyConfigRef'().
get_party_config_ref(#{party_config_ref := PartyConfigRef}) ->
    PartyConfigRef.
