-module(ff_withdrawal_routing).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([prepare_routes/2]).
-export([prepare_routes/3]).
-export([gather_routes/2]).
-export([filter_limit_overflow_routes/3]).
-export([rollback_routes_limits/3]).
-export([commit_routes_limits/3]).
-export([make_route/2]).
-export([get_provider/1]).
-export([get_terminal/1]).
-export([routes/1]).
-export([log_reject_context/1]).

-import(ff_pipeline, [do/1, unwrap/1]).

-type route() :: #{
    version := 1,
    provider_id := provider_id(),
    terminal_id := terminal_id(),
    provider_id_legacy => provider_id()
}.

-type routing_context() :: #{
    domain_revision := domain_revision(),
    identity := identity(),
    withdrawal => withdrawal(),
    iteration => pos_integer()
}.

-type routing_state() :: #{
    routes := [routing_rule_route()],
    reject_context := reject_context()
}.

-export_type([route/0]).
-export_type([routing_context/0]).

-type identity() :: ff_identity:identity_state().
-type withdrawal() :: ff_withdrawal:withdrawal_state().
-type domain_revision() :: ff_domain_config:revision().
-type party_varset() :: ff_varset:varset().

-type provider_id() :: ff_payouts_provider:id().

-type terminal_id() :: ff_payouts_terminal:id().

-type routing_rule_route() :: ff_routing_rule:route().
-type reject_context() :: ff_routing_rule:reject_context().

-type withdrawal_provision_terms() :: dmsl_domain_thrift:'WithdrawalProvisionTerms'().
-type currency_selector() :: dmsl_domain_thrift:'CurrencySelector'().
-type cash_limit_selector() :: dmsl_domain_thrift:'CashLimitSelector'().
-type turnover_limit_selector() :: dmsl_domain_thrift:'TurnoverLimitSelector'().
-type process_route_fun() :: fun(
    (withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
        ok
        | {ok, valid}
        | {error, Error :: term()}
).

%%

-spec prepare_routes(party_varset(), identity(), domain_revision()) ->
    {ok, [route()]} | {error, route_not_found}.
prepare_routes(PartyVarset, Identity, DomainRevision) ->
    prepare_routes(PartyVarset, #{identity => Identity, domain_revision => DomainRevision}).

-spec prepare_routes(party_varset(), routing_context()) ->
    {ok, [route()]} | {error, route_not_found}.
prepare_routes(PartyVarset, Context) ->
    State = gather_routes(PartyVarset, Context),
    log_reject_context(State),
    routes(State).

-spec gather_routes(party_varset(), routing_context()) ->
    routing_state().
gather_routes(PartyVarset, Context = #{identity := Identity, domain_revision := DomainRevision}) ->
    {ok, PaymentInstitutionID} = ff_party:get_identity_payment_institution_id(Identity),
    {ok, PaymentInstitution} = ff_payment_institution:get(PaymentInstitutionID, PartyVarset, DomainRevision),
    {Routes, RejectContext} = ff_routing_rule:gather_routes(
        PaymentInstitution,
        withdrawal_routing_rules,
        PartyVarset,
        DomainRevision
    ),
    filter_valid_routes(#{routes => Routes, reject_context => RejectContext}, PartyVarset, Context).

-spec filter_limit_overflow_routes(routing_state(), party_varset(), routing_context()) ->
    routing_state().
filter_limit_overflow_routes(State, PartyVarset, RoutingContext) ->
    validate_routes_with(
        fun do_validate_limits/4,
        State,
        PartyVarset,
        RoutingContext
    ).

-spec rollback_routes_limits([route()], party_varset(), routing_context()) ->
    ok.
rollback_routes_limits(Routes, PartyVarset, RoutingContext) ->
    process_routes_with(
        fun do_rollback_limits/4,
        Routes,
        PartyVarset,
        RoutingContext
    ).

-spec commit_routes_limits([route()], party_varset(), routing_context()) ->
    ok.
commit_routes_limits(Routes, PartyVarset, RoutingContext) ->
    process_routes_with(
        fun do_commit_limits/4,
        Routes,
        PartyVarset,
        RoutingContext
    ).

-spec make_route(provider_id(), terminal_id() | undefined) -> route().
make_route(ProviderID, TerminalID) ->
    genlib_map:compact(#{
        version => 1,
        provider_id => ProviderID,
        terminal_id => TerminalID
    }).

-spec get_provider(route()) -> provider_id().
get_provider(#{provider_id := ProviderID}) ->
    ProviderID.

-spec get_terminal(route()) -> ff_maybe:maybe(terminal_id()).
get_terminal(Route) ->
    maps:get(terminal_id, Route, undefined).

-spec routes(routing_state()) ->
    {ok, [route()]} | {error, route_not_found}.
routes(#{routes := Routes = [_ | _]}) ->
    {ok, sort_routes(Routes)};
routes(_) ->
    {error, route_not_found}.

-spec sort_routes([routing_rule_route()]) -> [route()].
sort_routes(RoutingRuleRoutes) ->
    ProviderTerminalMap = lists:foldl(
        fun(#{provider_ref := ProviderRef, terminal_ref := TerminalRef, priority := Priority}, Acc0) ->
            TerminalID = TerminalRef#domain_TerminalRef.id,
            ProviderID = ProviderRef#domain_ProviderRef.id,
            Routes = maps:get(Priority, Acc0, []),
            Acc1 = maps:put(Priority, [{ProviderID, TerminalID} | Routes], Acc0),
            Acc1
        end,
        #{},
        RoutingRuleRoutes
    ),
    lists:foldl(
        fun({_, Data}, Acc) ->
            SortedRoutes = [make_route(P, T) || {P, T} <- lists:sort(Data)],
            SortedRoutes ++ Acc
        end,
        [],
        lists:keysort(1, maps:to_list(ProviderTerminalMap))
    ).

-spec log_reject_context(routing_state()) ->
    ok.
log_reject_context(#{reject_context := RejectContext}) ->
    ff_routing_rule:log_reject_context(RejectContext).

%%

-spec filter_valid_routes(routing_state(), party_varset(), routing_context()) ->
    routing_state().
filter_valid_routes(State, PartyVarset, RoutingContext) ->
    validate_routes_with(
        fun do_validate_terms/4,
        State,
        PartyVarset,
        RoutingContext
    ).

-spec process_routes_with(process_route_fun(), [route()], party_varset(), routing_context()) ->
    ok.
process_routes_with(Func, Routes, PartyVarset, RoutingContext) ->
    lists:foreach(
        fun(Route) ->
            ProviderID = maps:get(provider_id, Route),
            TerminalID = maps:get(terminal_id, Route),
            ProviderRef = #domain_ProviderRef{id = ProviderID},
            TerminalRef = #domain_TerminalRef{id = TerminalID},
            get_route_terms_and_process(Func, ProviderRef, TerminalRef, PartyVarset, RoutingContext)
        end,
        Routes
    ).

-spec validate_routes_with(
    process_route_fun(), routing_state(), party_varset(), routing_context()
) ->
    routing_state().
validate_routes_with(Func, #{routes := Routes, reject_context := RejectContext}, PartyVarset, RoutingContext) ->
    lists:foldl(
        fun(Route, State = #{routes := ValidRoutes0, reject_context := RejectContext0}) ->
            ProviderRef = maps:get(provider_ref, Route),
            TerminalRef = maps:get(terminal_ref, Route),
            case get_route_terms_and_process(Func, ProviderRef, TerminalRef, PartyVarset, RoutingContext) of
                {ok, valid} ->
                    ValidRoutes1 = [Route | ValidRoutes0],
                    State#{routes => ValidRoutes1};
                {error, RejectReason} ->
                    RejectedRoutes0 = maps:get(rejected_routes, RejectContext0),
                    RejectedRoutes1 = [{ProviderRef, TerminalRef, RejectReason} | RejectedRoutes0],
                    RejectContext1 = maps:put(rejected_routes, RejectedRoutes1, RejectContext0),
                    State#{reject_context => RejectContext1}
            end
        end,
        #{routes => [], reject_context => RejectContext},
        Routes
    ).

get_route_terms_and_process(
    Func, ProviderRef, TerminalRef, PartyVarset, RoutingContext = #{domain_revision := DomainRevision}
) ->
    case ff_party:compute_provider_terminal_terms(ProviderRef, TerminalRef, PartyVarset, DomainRevision) of
        {ok, #domain_ProvisionTermSet{
            wallet = #domain_WalletProvisionTerms{
                withdrawals = WithdrawalProvisionTerms
            }
        }} ->
            Route = make_route(ProviderRef#domain_ProviderRef.id, TerminalRef#domain_TerminalRef.id),
            Func(WithdrawalProvisionTerms, PartyVarset, Route, RoutingContext);
        {error, Error} ->
            {error, Error}
    end.

-spec do_rollback_limits(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    ok.
do_rollback_limits(CombinedTerms, _PartyVarset, Route, #{withdrawal := Withdrawal, iteration := Iter}) ->
    #domain_WithdrawalProvisionTerms{
        turnover_limit = TurnoverLimit
    } = CombinedTerms,
    Limits = ff_limiter:get_turnover_limits(TurnoverLimit),
    ff_limiter:rollback_withdrawal_limits(Limits, Route, Withdrawal, Iter).

-spec do_commit_limits(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    ok.
do_commit_limits(CombinedTerms, _PartyVarset, Route, #{withdrawal := Withdrawal, iteration := Iter}) ->
    #domain_WithdrawalProvisionTerms{
        turnover_limit = TurnoverLimit
    } = CombinedTerms,
    Limits = ff_limiter:get_turnover_limits(TurnoverLimit),
    ff_limiter:commit_withdrawal_limits(Limits, Route, Withdrawal, Iter).

-spec do_validate_limits(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    {ok, valid}
    | {error, Error :: term()}.
do_validate_limits(CombinedTerms, PartyVarset, Route, RoutingContext) ->
    do(fun() ->
        #domain_WithdrawalProvisionTerms{
            turnover_limit = TurnoverLimits
        } = CombinedTerms,
        valid = unwrap(validate_turnover_limits(TurnoverLimits, PartyVarset, Route, RoutingContext))
    end).

-spec do_validate_terms(withdrawal_provision_terms(), party_varset(), route(), routing_context()) ->
    {ok, valid}
    | {error, Error :: term()}.
do_validate_terms(CombinedTerms, PartyVarset, _Route, _RoutingContext) ->
    do(fun() ->
        #domain_WithdrawalProvisionTerms{
            allow = Allow,
            currencies = CurrenciesSelector,
            %% PayoutMethodsSelector is useless for withdrawals
            %% so we can just ignore it
            %% payout_methods = PayoutMethodsSelector,
            cash_limit = CashLimitSelector
        } = CombinedTerms,
        valid = unwrap(validate_selectors_defined(CombinedTerms)),
        valid = unwrap(validate_allow(Allow)),
        valid = unwrap(validate_currencies(CurrenciesSelector, PartyVarset)),
        valid = unwrap(validate_cash_limit(CashLimitSelector, PartyVarset))
    end).

-spec validate_selectors_defined(withdrawal_provision_terms()) ->
    {ok, valid}
    | {error, Error :: term()}.
validate_selectors_defined(Terms) ->
    Selectors = [
        Terms#domain_WithdrawalProvisionTerms.currencies,
        Terms#domain_WithdrawalProvisionTerms.payout_methods,
        Terms#domain_WithdrawalProvisionTerms.cash_limit,
        Terms#domain_WithdrawalProvisionTerms.cash_flow
    ],
    case lists:any(fun(Selector) -> Selector =:= undefined end, Selectors) of
        false ->
            {ok, valid};
        true ->
            {error, terms_undefined}
    end.

validate_allow(Constant) ->
    case Constant of
        undefined ->
            {ok, valid};
        {constant, true} ->
            {ok, valid};
        {constant, false} ->
            {error, {terms_violation, terminal_forbidden}};
        Ambiguous ->
            {error, {misconfiguration, {'Could not reduce predicate to a value', {allow, Ambiguous}}}}
    end.

-spec validate_currencies(currency_selector(), party_varset()) ->
    {ok, valid}
    | {error, Error :: term()}.
validate_currencies({value, Currencies}, #{currency := CurrencyRef}) ->
    case ordsets:is_element(CurrencyRef, Currencies) of
        true ->
            {ok, valid};
        false ->
            {error, {terms_violation, {not_allowed_currency, {CurrencyRef, Currencies}}}}
    end;
validate_currencies(_NotReducedSelector, _VS) ->
    {error, {misconfiguration, {not_reduced_termset, currencies}}}.

-spec validate_cash_limit(cash_limit_selector(), party_varset()) ->
    {ok, valid}
    | {error, Error :: term()}.
validate_cash_limit({value, CashRange}, #{cost := Cash}) ->
    case hg_cash_range:is_inside(Cash, CashRange) of
        within ->
            {ok, valid};
        _NotInRange ->
            {error, {terms_violation, {cash_range, {Cash, CashRange}}}}
    end;
validate_cash_limit(_NotReducedSelector, _VS) ->
    {error, {misconfiguration, {not_reduced_termset, cash_range}}}.

-spec validate_turnover_limits(turnover_limit_selector(), party_varset(), route(), routing_context()) ->
    {ok, valid}
    | {error, Error :: term()}.
validate_turnover_limits(undefined, _VS, _Route, _RoutingContext) ->
    {ok, valid};
validate_turnover_limits({value, TurnoverLimits}, _VS, Route, #{withdrawal := Withdrawal, iteration := Iter}) ->
    ok = ff_limiter:hold_withdrawal_limits(TurnoverLimits, Route, Withdrawal, Iter),
    case ff_limiter:check_limits(TurnoverLimits, Route, Withdrawal) of
        {ok, _} ->
            {ok, valid};
        {error, Error} ->
            {error, {terms_violation, Error}}
    end;
validate_turnover_limits(NotReducedSelector, _VS, _Route, _RoutingContext) ->
    {error, {misconfiguration, {'Could not reduce selector to a value', NotReducedSelector}}}.

%% TESTS

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec convert_to_route_test() -> _.
convert_to_route_test() ->
    ?assertEqual(
        [],
        sort_routes([])
    ),
    ?assertEqual(
        [
            #{provider_id => 100, terminal_id => 2000, version => 1},
            #{provider_id => 100, terminal_id => 2001, version => 1},
            #{provider_id => 200, terminal_id => 2100, version => 1},
            #{provider_id => 200, terminal_id => 2101, version => 1},
            #{provider_id => 300, terminal_id => 2200, version => 1}
        ],
        sort_routes([
            #{
                provider_ref => #domain_ProviderRef{id = 100},
                terminal_ref => #domain_TerminalRef{id = 2000},
                priority => 1000
            },
            #{
                provider_ref => #domain_ProviderRef{id = 100},
                terminal_ref => #domain_TerminalRef{id = 2001},
                priority => 1000
            },
            #{
                provider_ref => #domain_ProviderRef{id = 200},
                terminal_ref => #domain_TerminalRef{id = 2100},
                priority => 900
            },
            #{
                provider_ref => #domain_ProviderRef{id = 200},
                terminal_ref => #domain_TerminalRef{id = 2101},
                priority => 900
            },
            #{
                provider_ref => #domain_ProviderRef{id = 300},
                terminal_ref => #domain_TerminalRef{id = 2200},
                priority => 100
            }
        ])
    ).

-endif.
