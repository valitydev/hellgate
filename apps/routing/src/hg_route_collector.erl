-module(hg_route_collector).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").
-include_lib("hellgate/include/domain.hrl").

-export([fill_blacklist/2]).
-export([fill_fd_overrides/2]).
-export([fill_prohibition/4]).
-export([fill_accepted/4]).
-export([get_routes/4]).

-callback fill(_Params, [hg_route:t()]) -> [hg_route:t()].
-callback fill([hg_route:t()]) -> [hg_route:t()].
-optional_callbacks([fill/1, fill/2]).

-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type route_predestination() :: payment | recurrent_paytool | recurrent_payment.
-type varset() :: hg_varset:varset().
-type revision() :: hg_domain:revision().

-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type client_ip() :: dmsl_domain_thrift:'IPAddress'().
-type email() :: binary().
-type card_token() :: dmsl_domain_thrift:'Token'().

-type gather_route_context() :: #{
    currency := currency(),
    payment_tool := payment_tool(),
    client_ip := client_ip() | undefined,
    email => email() | undefined,
    card_token => card_token() | undefined
}.

-type get_routes_resut() :: #{
    routes := [hg_route:t()],
    error => get_routes_error()
}.

-type get_routes_error() :: {misconfiguration, _Reason}.

-type blacklist_context() :: hg_inspector:blacklist_context().

-export_type([payment_institution/0]).
-export_type([route_predestination/0]).
-export_type([varset/0]).
-export_type([revision/0]).
-export_type([blacklist_context/0]).
-export_type([gather_route_context/0]).
-export_type([get_routes_error/0]).

-define(fd_overrides(Enabled), #domain_RouteFaultDetectorOverrides{enabled = Enabled}).
-define(rejected(Reason), {rejected, Reason}).

-spec fill_blacklist(hg_inspector:blacklist_context(), [hg_route:t()]) -> [hg_route:t()].
fill_blacklist(_BlCtx, []) ->
    [];
fill_blacklist(BlCtx, Routes) ->
    [hg_inspector:fill_blacklist(R, BlCtx) || R <- Routes].

-spec fill_fd_overrides(revision(), [hg_route:t()]) ->
    [hg_route:t()].
fill_fd_overrides(Revision, Routes) ->
    lists:foldr(
        fun(Route, AccIn) ->
            TRef = hg_route:terminal_ref(Route),
            FdOverrides = get_provider_fd_overrides(Revision, TRef),
            [hg_route:set_fd_overrides(FdOverrides, Route) | AccIn]
        end,
        [],
        Routes
    ).

get_provider_fd_overrides(Revision, TerminalRef) ->
    #domain_Terminal{provider_ref = ProviderRef, route_fd_overrides = TrmFdOverrides} =
        hg_domain:get(Revision, {terminal, TerminalRef}),
    #domain_Provider{route_fd_overrides = PrvFdOverrides} =
        hg_domain:get(Revision, {provider, ProviderRef}),
    merge_fd_overrides(PrvFdOverrides, TrmFdOverrides).

merge_fd_overrides(_A, B = ?fd_overrides(Enabled)) when Enabled =/= undefined ->
    B;
merge_fd_overrides(A = ?fd_overrides(Enabled), _B) when Enabled =/= undefined ->
    A;
merge_fd_overrides(_A, _B) ->
    ?fd_overrides(undefined).

-spec fill_prohibition(revision(), varset(), payment_institution(), [hg_route:t()]) ->
    [hg_route:t()].
fill_prohibition(Revision, VS, #domain_PaymentInstitution{payment_routing_rules = RoutingRules}, Routes) ->
    #domain_RoutingRules{
        prohibitions = Prohibitions
    } = RoutingRules,
    Table = get_table_prohibitions(Prohibitions, VS, Revision),
    lists:foldr(
        fun(Route, AccIn) ->
            TRef = hg_route:terminal_ref(Route),
            case maps:find(TRef, Table) of
                error ->
                    [Route | AccIn];
                {ok, Description} ->
                    [hg_route:set_prohibit({true, Description}, Route) | AccIn]
            end
        end,
        [],
        Routes
    ).

get_table_prohibitions(Prohibitions, VS, Revision) ->
    RuleSetDeny = compute_rule_set(Prohibitions, VS, Revision),
    lists:foldr(
        fun(#domain_RoutingCandidate{terminal = K, description = V}, AccIn) ->
            AccIn#{K => V}
        end,
        #{},
        get_decisions_candidates(RuleSetDeny)
    ).

-spec fill_accepted(route_predestination(), revision(), varset(), [hg_route:t()]) ->
    [hg_route:t()].
fill_accepted(Predestination, Revision, VS, Routes) ->
    lists:foldr(
        fun(Route, AccIn) ->
            PRef = hg_route:provider_ref(Route),
            TRef = hg_route:terminal_ref(Route),
            try
                true = acceptable_terminal(Predestination, PRef, TRef, VS, Revision),
                [Route | AccIn]
            catch
                {rejected, Reason} ->
                    [hg_route:set_accepted({false, {rejected, Reason}}, Route) | AccIn];
                error:{misconfiguration, Reason} ->
                    [hg_route:set_accepted({false, {misconfiguration, Reason}}, Route) | AccIn]
            end
        end,
        [],
        Routes
    ).

-spec get_routes(revision(), varset(), payment_institution(), gather_route_context()) ->
    get_routes_resut().
get_routes(_, _, #domain_PaymentInstitution{payment_routing_rules = undefined}, _) ->
    #{routes => [], error => {misconfiguration, {payment_routing_rules, empty}}};
get_routes(Revision, VS, #domain_PaymentInstitution{payment_routing_rules = RoutingRules}, Ctx) ->
    #domain_RoutingRules{
        policies = Policies
    } = RoutingRules,
    try
        Candidates = get_candidates(Policies, VS, Revision),
        #{routes => collect_routes(Candidates, Revision, Ctx)}
    catch
        throw:{misconfiguration, _Reason} = Error ->
            #{routes => [], error => Error}
    end.

get_candidates(RoutingRule, VS, Revision) ->
    get_decisions_candidates(
        compute_rule_set(RoutingRule, VS, Revision)
    ).

get_decisions_candidates(#domain_RoutingRuleset{decisions = Decisions}) ->
    case Decisions of
        {delegates, _Delegates} ->
            throw({misconfiguration, {routing_decisions, Decisions}});
        {candidates, Candidates} ->
            ok = validate_decisions_candidates(Candidates),
            Candidates
    end.

compute_rule_set(RuleSetRef, VS, Revision) ->
    {Client, Context} = get_party_client(),
    {ok, RuleSet} = party_client_thrift:compute_routing_ruleset(
        RuleSetRef,
        Revision,
        hg_varset:prepare_varset(VS),
        Client,
        Context
    ),
    RuleSet.

validate_decisions_candidates([]) ->
    ok;
validate_decisions_candidates([#domain_RoutingCandidate{allowed = {constant, true}} | Rest]) ->
    validate_decisions_candidates(Rest);
validate_decisions_candidates([Candidate | _]) ->
    throw({misconfiguration, {routing_candidate, Candidate}}).

collect_routes(Candidates, Revision, Ctx) ->
    lists:foldr(
        fun(Candidate, Routes) ->
            #domain_RoutingCandidate{
                terminal = TerminalRef,
                priority = Priority,
                weight = Weight,
                pin = Pin
            } = Candidate,
            #domain_Terminal{provider_ref = ProviderRef} = hg_domain:get(Revision, {terminal, TerminalRef}),
            GatheredPinInfo = gather_pin_info(Pin, Ctx),
            Route = hg_route:new(Revision, ProviderRef, TerminalRef, Weight, Priority, GatheredPinInfo),
            [Route | Routes]
        end,
        [],
        Candidates
    ).

gather_pin_info(undefined, _Ctx) ->
    #{};
gather_pin_info(#domain_RoutingPin{features = Features}, Ctx) ->
    FeaturesList = ordsets:to_list(Features),
    lists:foldl(
        fun(Feature, Acc) ->
            Acc#{Feature => maps:get(Feature, Ctx, undefined)}
        end,
        #{},
        FeaturesList
    ).

%% Accept

-spec acceptable_terminal(
    route_predestination(),
    hg_route:provider_ref(),
    hg_route:terminal_ref(),
    varset(),
    revision()
) -> true | no_return().
acceptable_terminal(Predestination, ProviderRef, TerminalRef, VS, Revision) ->
    {Client, Context} = get_party_client(),
    Result = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        Revision,
        hg_varset:prepare_varset(VS),
        Client,
        Context
    ),
    case Result of
        {ok, ProvisionTermSet} ->
            check_terms_acceptability(Predestination, ProvisionTermSet, VS);
        {error, #payproc_ProvisionTermSetUndefined{}} ->
            throw(?rejected({'ProvisionTermSet', undefined}))
    end.

get_party_client() ->
    HgContext = hg_context:load(),
    Client = hg_context:get_party_client(HgContext),
    Context = hg_context:get_party_client_context(HgContext),
    {Client, Context}.

check_terms_acceptability(payment, Terms, VS) ->
    acceptable_payment_terms(Terms#domain_ProvisionTermSet.payments, VS);
check_terms_acceptability(recurrent_paytool, Terms, VS) ->
    acceptable_recurrent_paytool_terms(Terms#domain_ProvisionTermSet.recurrent_paytools, VS);
check_terms_acceptability(recurrent_payment, Terms, VS) ->
    % Use provider check combined from recurrent_paytool and payment check
    _ = acceptable_payment_terms(Terms#domain_ProvisionTermSet.payments, VS),
    acceptable_recurrent_paytool_terms(Terms#domain_ProvisionTermSet.recurrent_paytools, VS).

acceptable_payment_terms(
    #domain_PaymentsProvisionTerms{
        allow = Allow,
        global_allow = GlobalAllow,
        currencies = CurrenciesSelector,
        categories = CategoriesSelector,
        payment_methods = PMsSelector,
        cash_limit = CashLimitSelector,
        holds = HoldsTerms,
        refunds = RefundsTerms,
        risk_coverage = RiskCoverageSelector
    },
    VS
) ->
    % TODO varsets getting mixed up
    %      it seems better to pass down here hierarchy of contexts w/ appropriate module accessors
    ParentName = 'PaymentsProvisionTerms',
    _ = acceptable_allow(ParentName, global_allow, GlobalAllow),
    _ = acceptable_allow(ParentName, allow, Allow),
    _ = try_accept_term(ParentName, currency, getv(currency, VS), CurrenciesSelector),
    _ = try_accept_term(ParentName, category, getv(category, VS), CategoriesSelector),
    _ = try_accept_term(ParentName, payment_tool, getv(payment_tool, VS), PMsSelector),
    _ = try_accept_term(ParentName, cost, getv(cost, VS), CashLimitSelector),
    _ = acceptable_holds_terms(HoldsTerms, getv(flow, VS, undefined)),
    _ = acceptable_refunds_terms(RefundsTerms, getv(refunds, VS, undefined)),
    _ = acceptable_risk(ParentName, RiskCoverageSelector, VS),
    %% TODO Check chargeback terms when there will be any
    %% _ = acceptable_chargeback_terms(...)
    true;
acceptable_payment_terms(undefined, _VS) ->
    throw(?rejected({'PaymentsProvisionTerms', undefined})).

acceptable_holds_terms(_Terms, undefined) ->
    true;
acceptable_holds_terms(_Terms, instant) ->
    true;
acceptable_holds_terms(Terms, {hold, Lifetime}) ->
    case Terms of
        #domain_PaymentHoldsProvisionTerms{lifetime = LifetimeSelector} ->
            _ = try_accept_term('PaymentHoldsProvisionTerms', lifetime, Lifetime, LifetimeSelector),
            true;
        undefined ->
            throw(?rejected({'PaymentHoldsProvisionTerms', undefined}))
    end.

acceptable_risk(_ParentName, undefined, _VS) ->
    true;
acceptable_risk(ParentName, Selector, VS) ->
    RiskCoverage = get_selector_value(risk_coverage, Selector),
    RiskScore = getv(risk_score, VS),
    hg_inspector:compare_risk_score(RiskCoverage, RiskScore) >= 0 orelse
        throw(?rejected({ParentName, risk_coverage})).

acceptable_refunds_terms(_Terms, undefined) ->
    true;
acceptable_refunds_terms(
    #domain_PaymentRefundsProvisionTerms{
        partial_refunds = PartialRefundsTerms
    },
    RVS
) ->
    _ = acceptable_partial_refunds_terms(
        PartialRefundsTerms,
        getv(partial, RVS, undefined)
    ),
    true;
acceptable_refunds_terms(undefined, _RVS) ->
    throw(?rejected({'PaymentRefundsProvisionTerms', undefined})).

acceptable_partial_refunds_terms(_Terms, undefined) ->
    true;
acceptable_partial_refunds_terms(
    #domain_PartialRefundsProvisionTerms{cash_limit = CashLimitSelector},
    #{cash_limit := MerchantLimit}
) ->
    ProviderLimit = get_selector_value(cash_limit, CashLimitSelector),
    hg_cash_range:is_subrange(MerchantLimit, ProviderLimit) == true orelse
        throw(?rejected({'PartialRefundsProvisionTerms', cash_limit}));
acceptable_partial_refunds_terms(undefined, _RVS) ->
    throw(?rejected({'PartialRefundsProvisionTerms', undefined})).

acceptable_allow(_ParentName, _Type, undefined) ->
    true;
acceptable_allow(_ParentName, _Type, {constant, true}) ->
    true;
acceptable_allow(ParentName, Type, {constant, false}) ->
    throw(?rejected({ParentName, Type}));
acceptable_allow(_ParentName, Type, Ambiguous) ->
    erlang:error({misconfiguration, {'Could not reduce predicate to a value', {Type, Ambiguous}}}).

acceptable_recurrent_paytool_terms(
    #domain_RecurrentPaytoolsProvisionTerms{
        categories = CategoriesSelector,
        payment_methods = PMsSelector
    },
    VS
) ->
    _ = try_accept_term('RecurrentPaytoolsProvisionTerms', category, getv(category, VS), CategoriesSelector),
    _ = try_accept_term('RecurrentPaytoolsProvisionTerms', payment_tool, getv(payment_tool, VS), PMsSelector),
    true;
acceptable_recurrent_paytool_terms(undefined, _VS) ->
    throw(?rejected({'RecurrentPaytoolsProvisionTerms', undefined})).

try_accept_term(ParentName, Name, _Value, undefined) ->
    throw(?rejected({ParentName, Name}));
try_accept_term(ParentName, Name, Value, Selector) ->
    Values = get_selector_value(Name, Selector),
    test_term(Name, Value, Values) orelse throw(?rejected({ParentName, Name})).

test_term(currency, V, Vs) ->
    ordsets:is_element(V, Vs);
test_term(category, V, Vs) ->
    ordsets:is_element(V, Vs);
test_term(payment_tool, PT, PMs) ->
    hg_payment_tool:has_any_payment_method(PT, PMs);
test_term(cost, Cost, CashRange) ->
    hg_cash_range:is_inside(Cost, CashRange) == within;
test_term(lifetime, ?hold_lifetime(Lifetime), ?hold_lifetime(Allowed)) ->
    Lifetime =< Allowed.

%%

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            V;
        Ambiguous ->
            erlang:error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

getv(Name, VS) ->
    maps:get(Name, VS).

getv(Name, VS, Default) ->
    maps:get(Name, VS, Default).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec merge_fd_overrides_test_() -> _.
merge_fd_overrides_test_() ->
    [
        ?_assertEqual(?fd_overrides(undefined), merge_fd_overrides(undefined, ?fd_overrides(undefined))),
        ?_assertEqual(?fd_overrides(true), merge_fd_overrides(?fd_overrides(true), undefined)),
        ?_assertEqual(?fd_overrides(true), merge_fd_overrides(?fd_overrides(true), ?fd_overrides(undefined))),
        ?_assertEqual(?fd_overrides(false), merge_fd_overrides(?fd_overrides(true), ?fd_overrides(false)))
    ].

-endif.
