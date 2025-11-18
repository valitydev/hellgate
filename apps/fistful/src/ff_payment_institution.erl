-module(ff_payment_institution).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-type id() :: dmsl_domain_thrift:'ObjectID'().

-type domain_revision() :: ff_domain_config:revision().
-type party_varset() :: ff_varset:varset().
-type realm() :: test | live.

-type payment_institution() :: #{
    id := id(),
    realm := realm(),
    system_accounts := dmsl_domain_thrift:'SystemAccountSetSelector'(),
    withdrawal_routing_rules := dmsl_domain_thrift:'RoutingRules'(),
    payment_system => dmsl_domain_thrift:'PaymentSystemSelector'()
}.

-type payinst_ref() :: dmsl_domain_thrift:'PaymentInstitutionRef'().

-type system_accounts() :: #{
    ff_currency:id() => system_account()
}.

-type system_account() :: #{
    settlement => ff_account:account(),
    subagent => ff_account:account()
}.

-export_type([id/0]).
-export_type([realm/0]).
-export_type([payinst_ref/0]).
-export_type([payment_institution/0]).

-export([id/1]).
-export([realm/1]).

-export([ref/1]).
-export([get/3]).
-export([get_realm/2]).
-export([system_accounts/2]).
-export([payment_system/1]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%%

-spec id(payment_institution()) -> id().
id(#{id := ID}) ->
    ID.

-spec realm(payment_institution()) -> realm().
realm(#{realm := V}) ->
    V.

%%

-spec ref(id()) -> payinst_ref().
ref(ID) ->
    #domain_PaymentInstitutionRef{id = ID}.

-spec get(id() | payinst_ref(), party_varset(), domain_revision()) ->
    {ok, payment_institution()}
    | {error, payinst_not_found}.
get(#domain_PaymentInstitutionRef{id = ID} = Ref, VS, DomainRevision) ->
    do(fun() ->
        PaymentInstitution = unwrap(ff_party:compute_payment_institution(Ref, VS, DomainRevision)),
        decode(ID, PaymentInstitution)
    end);
get(PaymentInstitutionID, VS, DomainRevision) ->
    get(ref(PaymentInstitutionID), VS, DomainRevision).

-spec get_realm(payinst_ref(), domain_revision()) ->
    {ok, realm()}
    | {error, notfound}.
get_realm(Ref, DomainRevision) ->
    do(fun() ->
        #domain_PaymentInstitution{realm = Realm} = unwrap(
            ff_domain_config:object(DomainRevision, {payment_institution, Ref})
        ),
        Realm
    end).

get_selector_value(Name, Selector) ->
    case Selector of
        {value, V} ->
            {ok, V};
        Ambiguous ->
            {error, {misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}}}
    end.

-spec payment_system(payment_institution()) ->
    {ok, ff_resource:payment_system() | undefined}
    | {error, term()}.
payment_system(#{payment_system := PaymentSystem}) ->
    case get_selector_value(payment_system, PaymentSystem) of
        {ok, #'domain_PaymentSystemRef'{id = ID}} ->
            {ok, #{id => ID}};
        {error, Error} ->
            {error, Error}
    end;
payment_system(_PaymentInstitution) ->
    {ok, undefined}.

-spec system_accounts(payment_institution(), domain_revision()) ->
    {ok, system_accounts()}
    | {error, term()}.
system_accounts(PaymentInstitution, DomainRevision) ->
    #{
        realm := Realm,
        system_accounts := SystemAccountSetSelector
    } = PaymentInstitution,
    do(fun() ->
        SystemAccountSetRef = unwrap(get_selector_value(system_accounts, SystemAccountSetSelector)),
        SystemAccountSet = unwrap(ff_domain_config:object(DomainRevision, {system_account_set, SystemAccountSetRef})),
        decode_system_account_set(SystemAccountSet, Realm)
    end).

%%

decode(ID, #domain_PaymentInstitution{
    wallet_system_account_set = SystemAccounts,
    withdrawal_routing_rules = WithdrawalRoutingRules,
    payment_system = PaymentSystem,
    realm = Realm
}) ->
    genlib_map:compact(#{
        id => ID,
        realm => Realm,
        system_accounts => SystemAccounts,
        withdrawal_routing_rules => WithdrawalRoutingRules,
        payment_system => PaymentSystem
    }).

decode_system_account_set(#domain_SystemAccountSet{accounts = Accounts}, Realm) ->
    maps:fold(
        fun(CurrencyRef, SystemAccount, Acc) ->
            #domain_CurrencyRef{symbolic_code = CurrencyID} = CurrencyRef,
            maps:put(
                CurrencyID,
                decode_system_account(SystemAccount, CurrencyID, Realm),
                Acc
            )
        end,
        #{},
        Accounts
    ).

decode_system_account(SystemAccount, CurrencyID, Realm) ->
    #domain_SystemAccount{
        settlement = SettlementAccountID,
        subagent = SubagentAccountID
    } = SystemAccount,
    #{
        settlement => decode_account(SettlementAccountID, CurrencyID, Realm),
        subagent => decode_account(SubagentAccountID, CurrencyID, Realm)
    }.

decode_account(AccountID, CurrencyID, Realm) when AccountID =/= undefined ->
    ff_account:build(Realm, AccountID, CurrencyID);
decode_account(undefined, _, _) ->
    undefined.
