-module(ff_routing_rule).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([new_reject_context/1]).
-export([gather_routes/4]).
-export([log_reject_context/1]).

%% Accessors

-export([provider_id/1]).
-export([terminal_id/1]).

-type payment_institution() :: ff_payment_institution:payment_institution().
-type routing_ruleset_ref() :: dmsl_domain_thrift:'RoutingRulesetRef'().
-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type provider() :: dmsl_domain_thrift:'Provider'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().
-type provider_id() :: dmsl_domain_thrift:'ObjectID'().
-type terminal_id() :: dmsl_domain_thrift:'ObjectID'().
-type priority() :: integer().
-type weight() :: integer().
-type varset() :: ff_varset:varset().
-type revision() :: ff_domain_config:revision().
-type routing_rule_tag() :: withdrawal_routing_rules.
-type candidate() :: dmsl_domain_thrift:'RoutingCandidate'().
-type candidate_description() :: binary() | undefined.

-type route() :: #{
    provider_ref := provider_ref(),
    terminal_ref := terminal_ref(),
    priority := priority(),
    weight => weight()
}.

-export_type([route/0]).
-export_type([provider/0]).
-export_type([reject_context/0]).
-export_type([rejected_route/0]).

-type reject_context() :: #{
    varset := varset(),
    accepted_routes := [route()],
    rejected_routes := [rejected_route()]
}.

-type rejected_route() :: {provider_ref(), terminal_ref(), Reason :: term()}.

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%% Accessors

-spec provider_id(route()) -> provider_id().
provider_id(#{provider_ref := #domain_ProviderRef{id = ProviderID}}) ->
    ProviderID.

-spec terminal_id(route()) -> terminal_id().
terminal_id(#{terminal_ref := #domain_TerminalRef{id = TerminalID}}) ->
    TerminalID.

%%

-spec new_reject_context(varset()) -> reject_context().
new_reject_context(VS) ->
    #{
        varset => VS,
        accepted_routes => [],
        rejected_routes => []
    }.

-spec gather_routes(payment_institution(), routing_rule_tag(), varset(), revision()) -> {[route()], reject_context()}.
gather_routes(PaymentInstitution, RoutingRuleTag, VS, Revision) ->
    RejectContext = new_reject_context(VS),
    case do_gather_routes(PaymentInstitution, RoutingRuleTag, VS, Revision) of
        {ok, {AcceptedRoutes, RejectedRoutes}} ->
            {AcceptedRoutes, RejectContext#{
                accepted_routes => AcceptedRoutes,
                rejected_routes => RejectedRoutes
            }};
        {error, misconfiguration} ->
            logger:warning("Routing rule misconfiguration. Varset:~n~p", [VS]),
            {[], RejectContext}
    end.

-spec do_gather_routes(payment_institution(), routing_rule_tag(), varset(), revision()) ->
    {ok, {[route()], [rejected_route()]}}
    | {error, misconfiguration}.
do_gather_routes(PaymentInstitution, RoutingRuleTag, VS, Revision) ->
    do(fun() ->
        RoutingRules = maps:get(RoutingRuleTag, PaymentInstitution),
        Policies = RoutingRules#domain_RoutingRules.policies,
        Prohibitions = RoutingRules#domain_RoutingRules.prohibitions,
        PermitCandidates = unwrap(compute_routing_ruleset(Policies, VS, Revision)),
        DenyCandidates = unwrap(compute_routing_ruleset(Prohibitions, VS, Revision)),
        filter_prohibited_candidates(
            PermitCandidates,
            DenyCandidates,
            Revision
        )
    end).

-spec compute_routing_ruleset(routing_ruleset_ref(), varset(), revision()) ->
    {ok, [candidate()]}
    | {error, misconfiguration}.
compute_routing_ruleset(RulesetRef, VS, Revision) ->
    {ok, Ruleset} = ff_party:compute_routing_ruleset(RulesetRef, VS, Revision),
    check_ruleset_computing(Ruleset#domain_RoutingRuleset.decisions).

check_ruleset_computing({delegates, _}) ->
    {error, misconfiguration};
check_ruleset_computing({candidates, Candidates}) ->
    AllReduced = lists:all(
        fun(C) ->
            case C#domain_RoutingCandidate.allowed of
                {constant, _} ->
                    true;
                _ ->
                    false
            end
        end,
        Candidates
    ),
    case AllReduced of
        true ->
            {ok, Candidates};
        false ->
            {error, misconfiguration}
    end.

-spec filter_prohibited_candidates([candidate()], [candidate()], revision()) -> {[route()], [rejected_route()]}.
filter_prohibited_candidates(Candidates, ProhibitedCandidates, Revision) ->
    ProhibitionTable = lists:foldl(
        fun(C, Acc) ->
            Acc#{get_terminal_ref(C) => get_description(C)}
        end,
        #{},
        ProhibitedCandidates
    ),
    lists:foldr(
        fun(C, {Accepted, Rejected}) ->
            Route = make_route(C, Revision),
            #{provider_ref := ProviderRef, terminal_ref := TerminalRef} = Route,
            case maps:find(TerminalRef, ProhibitionTable) of
                error ->
                    {[Route | Accepted], Rejected};
                {ok, Description} ->
                    {Accepted, [{ProviderRef, TerminalRef, {'RoutingRule', Description}} | Rejected]}
            end
        end,
        {[], []},
        Candidates
    ).

-spec get_terminal_ref(candidate()) -> terminal_ref().
get_terminal_ref(Candidate) ->
    Candidate#domain_RoutingCandidate.terminal.

-spec get_description(candidate()) -> candidate_description().
get_description(Candidate) ->
    Candidate#domain_RoutingCandidate.description.

-spec make_route(candidate(), revision()) -> route().
make_route(Candidate, Revision) ->
    TerminalRef = Candidate#domain_RoutingCandidate.terminal,
    {ok, Terminal} = ff_domain_config:object(Revision, {terminal, TerminalRef}),
    Priority = Candidate#domain_RoutingCandidate.priority,
    Weight = Candidate#domain_RoutingCandidate.weight,
    ProviderRef = Terminal#domain_Terminal.provider_ref,
    genlib_map:compact(#{
        provider_ref => ProviderRef,
        terminal_ref => TerminalRef,
        priority => Priority,
        weight => Weight
    }).

-spec log_reject_context(reject_context()) -> ok.
log_reject_context(RejectContext) ->
    _ = logger:log(
        info,
        "Routing reject context: rejected routes: ~p, accepted routes: ~p, varset: ~p",
        [
            maps:get(rejected_routes, RejectContext),
            maps:get(accepted_routes, RejectContext),
            maps:get(varset, RejectContext)
        ],
        logger:get_process_metadata()
    ),
    ok.
