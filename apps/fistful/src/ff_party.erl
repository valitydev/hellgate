%%%
%%% Managed party
%%%
%%% TODOs
%%%
%%%  - We expect party to exist, which is certainly not the general case.
%%%

-module(ff_party).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-type id() :: dmsl_base_thrift:'ID'().
-type wallet_id() :: dmsl_base_thrift:'ID'().
-type wallet() :: dmsl_domain_thrift:'WalletConfig'().
-type terms() :: dmsl_domain_thrift:'TermSet'().
-type account_id() :: dmsl_domain_thrift:'AccountID'().
-type realm() :: ff_payment_institution:realm().
-type attempt_limit() :: integer().

-type validate_account_creation_error() ::
    currency_validation_error().

-type validate_deposit_creation_error() ::
    currency_validation_error()
    | {bad_deposit_amount, Cash :: cash()}.

-type validate_destination_creation_error() ::
    withdrawal_method_validation_error().

-type validate_withdrawal_creation_error() ::
    currency_validation_error()
    | withdrawal_method_validation_error()
    | cash_range_validation_error().

-export_type([id/0]).
-export_type([terms/0]).
-export_type([wallet_id/0]).
-export_type([wallet/0]).
-export_type([validate_deposit_creation_error/0]).
-export_type([validate_account_creation_error/0]).
-export_type([validate_destination_creation_error/0]).
-export_type([validate_withdrawal_creation_error/0]).
-export_type([withdrawal_method_validation_error/0]).
-export_type([cash/0]).
-export_type([cash_range/0]).
-export_type([attempt_limit/0]).
-export_type([provision_term_set/0]).
-export_type([method_ref/0]).

-type inaccessibility() ::
    {inaccessible, blocked | suspended}.

-export_type([inaccessibility/0]).

-export([get_party/1]).
-export([get_party_revision/0]).
-export([checkout/2]).
-export([get_wallet/2]).
-export([get_wallet/3]).
-export([build_account_for_wallet/2]).
-export([wallet_log_balance/2]).
-export([get_wallet_account/1]).
-export([get_wallet_realm/2]).
-export([is_accessible/1]).
-export([is_wallet_accessible/1]).
-export([validate_destination_creation/2]).
-export([get_withdrawal_methods/1]).
-export([validate_withdrawal_creation/3]).
-export([validate_deposit_creation/2]).
-export([validate_wallet_limits/2]).
-export([get_terms/3]).
-export([compute_payment_institution/3]).
-export([compute_routing_ruleset/3]).
-export([compute_provider_terminal_terms/4]).
-export([get_withdrawal_cash_flow_plan/1]).

%% Internal types
-type cash() :: ff_cash:cash().
-type method() :: ff_resource:method().
-type wallet_terms() :: dmsl_domain_thrift:'WalletServiceTerms'().
-type withdrawal_terms() :: dmsl_domain_thrift:'WithdrawalServiceTerms'().
-type currency_id() :: ff_currency:id().

-type currency_ref() :: dmsl_domain_thrift:'CurrencyRef'().
-type domain_cash() :: dmsl_domain_thrift:'Cash'().
-type domain_cash_range() :: dmsl_domain_thrift:'CashRange'().
-type domain_revision() :: ff_domain_config:revision().
-type payinst_ref() :: ff_payment_institution:payinst_ref().
-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type routing_ruleset_ref() :: dmsl_domain_thrift:'RoutingRulesetRef'().
-type routing_ruleset() :: dmsl_domain_thrift:'RoutingRuleset'().
-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().
-type method_ref() :: dmsl_domain_thrift:'PaymentMethodRef'().
-type provision_term_set() :: dmsl_domain_thrift:'ProvisionTermSet'().
-type bound_type() :: 'exclusive' | 'inclusive'.
-type cash_range() :: {{bound_type(), cash()}, {bound_type(), cash()}}.
-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type party_ref() :: dmsl_domain_thrift:'PartyConfigRef'().

-type currency_validation_error() ::
    {terms_violation, {not_allowed_currency, {currency_ref(), ordsets:ordset(currency_ref())}}}.

-type cash_range_validation_error() :: {terms_violation, {cash_range, {cash(), cash_range()}}}.
-type attempt_limit_error() :: {terms_violation, {attempt_limit, attempt_limit()}}.

-type not_reduced_error() :: {not_reduced, {Name :: atom(), TermsPart :: any()}}.

-type invalid_withdrawal_terms_error() ::
    invalid_wallet_terms_error()
    | {invalid_terms, not_reduced_error()}
    | {invalid_terms, {undefined_withdrawal_terms, wallet_terms()}}.

-type invalid_wallet_terms_error() ::
    {invalid_terms, not_reduced_error()}
    | {invalid_terms, undefined_wallet_terms}.

-type withdrawal_method_validation_error() ::
    {terms_violation, {not_allowed_withdrawal_method, {method_ref(), ordsets:ordset(method_ref())}}}.

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%%

-spec get_party(id()) -> {ok, party()} | {error, notfound}.
get_party(PartyID) ->
    checkout(PartyID, get_party_revision()).

-spec get_party_revision() -> domain_revision() | no_return().
get_party_revision() ->
    ff_domain_config:head().

-spec checkout(id(), domain_revision()) -> {ok, party()} | {error, notfound}.
checkout(PartyID, Revision) ->
    case ff_domain_config:object(Revision, {party_config, #domain_PartyConfigRef{id = PartyID}}) of
        {error, notfound} = Error ->
            Error;
        Party ->
            Party
    end.

-spec get_wallet(wallet_id(), party_ref()) -> {ok, wallet()} | {error, notfound}.
get_wallet(ID, PartyConfigRef) ->
    get_wallet(ID, PartyConfigRef, get_party_revision()).

-spec get_wallet(wallet_id(), party_ref(), domain_revision()) -> {ok, wallet()} | {error, notfound}.
get_wallet(ID, PartyConfigRef, Revision) ->
    Ref = #domain_WalletConfigRef{id = ID},
    case ff_domain_config:object(Revision, {wallet_config, Ref}) of
        {ok, #domain_WalletConfig{party_ref = PartyConfigRef}} = Result ->
            Result;
        _ ->
            {error, notfound}
    end.

-spec build_account_for_wallet(wallet(), domain_revision()) -> ff_account:account().
build_account_for_wallet(
    #domain_WalletConfig{
        party_ref = #domain_PartyConfigRef{id = PartyID}
    } = Wallet,
    DomainRevision
) ->
    {SettlementID, Currency} = get_wallet_account(Wallet),
    Realm = get_wallet_realm(Wallet, DomainRevision),
    ff_account:build(PartyID, Realm, SettlementID, Currency).

-spec wallet_log_balance(wallet_id(), wallet()) -> ok.
wallet_log_balance(WalletID, Wallet) ->
    {SettlementID, Currency} = get_wallet_account(Wallet),
    {ok, {Amounts, Currency}} = ff_accounting:balance(SettlementID, Currency),
    logger:log(notice, "Wallet balance", [], #{
        wallet => #{
            id => WalletID,
            balance => #{
                amount => ff_indef:current(Amounts),
                currency => Currency
            }
        }
    }),
    ok.

-spec get_wallet_account(wallet()) -> {account_id(), currency_id()}.
get_wallet_account(#domain_WalletConfig{
    account = #domain_WalletAccount{settlement = SettlementID, currency = #domain_CurrencyRef{symbolic_code = Currency}}
}) ->
    {SettlementID, Currency}.

-spec get_wallet_realm(wallet(), domain_revision()) -> realm().
get_wallet_realm(#domain_WalletConfig{payment_institution = PaymentInstitutionRef}, DomainRevision) ->
    {ok, WalletRealm} = ff_payment_institution:get_realm(PaymentInstitutionRef, DomainRevision),
    WalletRealm.

-spec is_accessible(id()) ->
    {ok, accessible}
    | {error, inaccessibility()}
    | {error, notfound}.
is_accessible(ID) ->
    case get_party(ID) of
        {ok, #domain_PartyConfig{block = {blocked, _}}} ->
            {error, {inaccessible, blocked}};
        {ok, #domain_PartyConfig{suspension = {suspended, _}}} ->
            {error, {inaccessible, suspended}};
        {ok, #domain_PartyConfig{}} ->
            {ok, accessible};
        {error, notfound} ->
            {error, notfound}
    end.

-spec is_wallet_accessible(wallet()) ->
    {ok, accessible}
    | {error, inaccessibility()}
    | {error, notfound}.
is_wallet_accessible(#domain_WalletConfig{block = {blocked, _}}) ->
    {error, {inaccessible, blocked}};
is_wallet_accessible(#domain_WalletConfig{suspension = {suspended, _}}) ->
    {error, {inaccessible, suspended}};
is_wallet_accessible(#domain_WalletConfig{}) ->
    {ok, accessible};
is_wallet_accessible(_) ->
    {error, notfound}.

%%

-spec get_terms(domain_revision(), wallet(), ff_varset:varset()) -> terms() | no_return().
get_terms(DomainRevision, #domain_WalletConfig{terms = Ref}, Varset) ->
    DomainVarset = ff_varset:encode(Varset),
    Args = {Ref, DomainRevision, DomainVarset},
    Request = {{dmsl_payproc_thrift, 'PartyManagement'}, 'ComputeTerms', Args},
    case ff_woody_client:call(party_config, Request) of
        {ok, Terms} ->
            Terms;
        {exception, Exception} ->
            error(Exception)
    end.

-spec compute_payment_institution(PaymentInstitutionRef, Varset, DomainRevision) -> Result when
    PaymentInstitutionRef :: payinst_ref(),
    Varset :: ff_varset:varset(),
    DomainRevision :: domain_revision(),
    Result :: {ok, payment_institution()} | {error, payinst_not_found}.
compute_payment_institution(PaymentInstitutionRef, Varset, DomainRevision) ->
    DomainVarset = ff_varset:encode(Varset),
    {Client, Context} = get_party_client(),
    Result = party_client_thrift:compute_payment_institution(
        PaymentInstitutionRef,
        DomainRevision,
        DomainVarset,
        Client,
        Context
    ),
    case Result of
        {ok, PaymentInstitution} ->
            {ok, PaymentInstitution};
        {error, #payproc_PaymentInstitutionNotFound{}} ->
            {error, payinst_not_found}
    end.

-spec compute_routing_ruleset(RoutingRulesetRef, Varset, DomainRevision) -> Result when
    RoutingRulesetRef :: routing_ruleset_ref(),
    Varset :: ff_varset:varset(),
    DomainRevision :: domain_revision(),
    Result :: {ok, routing_ruleset()} | {error, ruleset_not_found}.
compute_routing_ruleset(RoutingRulesetRef, Varset, DomainRevision) ->
    DomainVarset = ff_varset:encode(Varset),
    {Client, Context} = get_party_client(),
    Result = party_client_thrift:compute_routing_ruleset(
        RoutingRulesetRef,
        DomainRevision,
        DomainVarset,
        Client,
        Context
    ),
    case Result of
        {ok, RoutingRuleset} ->
            {ok, RoutingRuleset};
        {error, #payproc_RuleSetNotFound{}} ->
            {error, ruleset_not_found}
    end.

-spec compute_provider_terminal_terms(ProviderRef, TerminalRef, Varset, DomainRevision) -> Result when
    ProviderRef :: provider_ref(),
    TerminalRef :: terminal_ref(),
    Varset :: ff_varset:varset(),
    DomainRevision :: domain_revision(),
    Result :: {ok, provision_term_set()} | {error, provider_not_found} | {error, terminal_not_found}.
compute_provider_terminal_terms(ProviderRef, TerminalRef, Varset, DomainRevision) ->
    DomainVarset = ff_varset:encode(Varset),
    {Client, Context} = get_party_client(),
    Result = party_client_thrift:compute_provider_terminal_terms(
        ProviderRef,
        TerminalRef,
        DomainRevision,
        DomainVarset,
        Client,
        Context
    ),
    case Result of
        {ok, RoutingRuleset} ->
            {ok, RoutingRuleset};
        {error, #payproc_ProviderNotFound{}} ->
            {error, provider_not_found};
        {error, #payproc_TerminalNotFound{}} ->
            {error, terminal_not_found};
        {error, #payproc_ProvisionTermSetUndefined{}} ->
            {error, provision_termset_undefined}
    end.

-spec get_withdrawal_methods(terms()) ->
    ordsets:ordset(method_ref()).
get_withdrawal_methods(Terms) ->
    #domain_TermSet{wallets = WalletTerms} = Terms,
    #domain_WalletServiceTerms{withdrawals = WithdrawalTerms} = WalletTerms,
    #domain_WithdrawalServiceTerms{methods = MethodsSelector} = WithdrawalTerms,
    {ok, valid} = do_validate_terms_is_reduced([{withdrawal_methods, MethodsSelector}]),
    {value, Methods} = MethodsSelector,
    Methods.

-spec validate_destination_creation(terms(), method()) -> Result when
    Result :: {ok, valid} | {error, Error},
    Error :: validate_destination_creation_error().
validate_destination_creation(Terms, Method) ->
    Methods = get_withdrawal_methods(Terms),
    validate_withdrawal_terms_method(Method, Methods).

-spec validate_withdrawal_creation(terms(), cash(), method()) -> Result when
    Result :: {ok, valid} | {error, Error},
    Error :: validate_withdrawal_creation_error().
validate_withdrawal_creation(Terms, {_, CurrencyID} = Cash, Method) ->
    #domain_TermSet{wallets = WalletTerms} = Terms,
    do(fun() ->
        {ok, valid} = validate_withdrawal_terms_is_reduced(WalletTerms),
        valid = unwrap(validate_wallet_terms_currency(CurrencyID, WalletTerms)),
        #domain_WalletServiceTerms{withdrawals = WithdrawalTerms} = WalletTerms,
        valid = unwrap(validate_withdrawal_terms_currency(CurrencyID, WithdrawalTerms)),
        valid = unwrap(validate_withdrawal_cash_limit(Cash, WithdrawalTerms)),
        valid = unwrap(validate_withdrawal_attempt_limit(WithdrawalTerms)),
        #domain_WithdrawalServiceTerms{methods = {value, Methods}} = WithdrawalTerms,
        valid = unwrap(validate_withdrawal_terms_method(Method, Methods))
    end).

-spec validate_deposit_creation(terms(), cash()) -> Result when
    Result :: {ok, valid} | {error, Error},
    Error :: validate_deposit_creation_error().
validate_deposit_creation(_Terms, {Amount, _Currency} = Cash) when Amount == 0 ->
    {error, {bad_deposit_amount, Cash}};
validate_deposit_creation(Terms, {_Amount, CurrencyID} = _Cash) ->
    do(fun() ->
        #domain_TermSet{wallets = WalletTerms} = Terms,
        {ok, valid} = validate_wallet_currencies_term_is_reduced(WalletTerms),
        valid = unwrap(validate_wallet_terms_currency(CurrencyID, WalletTerms))
    end).

-spec get_withdrawal_cash_flow_plan(terms()) -> {ok, ff_cash_flow:cash_flow_plan()} | {error, _Error}.
get_withdrawal_cash_flow_plan(Terms) ->
    #domain_TermSet{
        wallets = #domain_WalletServiceTerms{
            withdrawals = #domain_WithdrawalServiceTerms{
                cash_flow = CashFlow
            }
        }
    } = Terms,
    {value, DomainPostings} = CashFlow,
    Postings = ff_cash_flow:decode_domain_postings(DomainPostings),
    {ok, #{postings => Postings}}.

%% Party management client

get_party_client() ->
    Context = ff_context:load(),
    Client = ff_context:get_party_client(Context),
    ClientContext = ff_context:get_party_client_context(Context),
    {Client, ClientContext}.

%% Terms stuff

-spec validate_wallet_currencies_term_is_reduced(wallet_terms() | undefined) ->
    {ok, valid} | {error, {invalid_terms, _Details}}.
validate_wallet_currencies_term_is_reduced(undefined) ->
    {error, {invalid_terms, undefined_wallet_terms}};
validate_wallet_currencies_term_is_reduced(Terms) ->
    #domain_WalletServiceTerms{
        currencies = CurrenciesSelector
    } = Terms,
    do_validate_terms_is_reduced([
        {wallet_currencies, CurrenciesSelector}
    ]).

-spec validate_withdrawal_terms_is_reduced(wallet_terms() | undefined) ->
    {ok, valid} | {error, invalid_withdrawal_terms_error()}.
validate_withdrawal_terms_is_reduced(undefined) ->
    {error, {invalid_terms, undefined_wallet_terms}};
validate_withdrawal_terms_is_reduced(#domain_WalletServiceTerms{withdrawals = undefined} = WalletTerms) ->
    {error, {invalid_terms, {undefined_withdrawal_terms, WalletTerms}}};
validate_withdrawal_terms_is_reduced(Terms) ->
    #domain_WalletServiceTerms{
        currencies = WalletCurrenciesSelector,
        withdrawals = WithdrawalTerms
    } = Terms,
    #domain_WithdrawalServiceTerms{
        currencies = WithdrawalCurrenciesSelector,
        cash_limit = CashLimitSelector,
        cash_flow = CashFlowSelector,
        attempt_limit = AttemptLimitSelector,
        methods = MethodsSelector
    } = WithdrawalTerms,
    do_validate_terms_is_reduced([
        {wallet_currencies, WalletCurrenciesSelector},
        {withdrawal_currencies, WithdrawalCurrenciesSelector},
        {withdrawal_cash_limit, CashLimitSelector},
        {withdrawal_cash_flow, CashFlowSelector},
        {withdrawal_attempt_limit, AttemptLimitSelector},
        {withdrawal_methods, MethodsSelector}
    ]).

-spec do_validate_terms_is_reduced([{atom(), Selector :: any()}]) ->
    {ok, valid} | {error, {invalid_terms, not_reduced_error()}}.
do_validate_terms_is_reduced([]) ->
    {ok, valid};
do_validate_terms_is_reduced([{Name, Terms} | TermsTail]) ->
    case selector_is_reduced(Terms) of
        Result when Result =:= reduced orelse Result =:= is_undefined ->
            do_validate_terms_is_reduced(TermsTail);
        not_reduced ->
            {error, {invalid_terms, {not_reduced, {Name, Terms}}}}
    end.

selector_is_reduced(undefined) ->
    is_undefined;
selector_is_reduced({value, _Value}) ->
    reduced;
selector_is_reduced({decisions, _Decisions}) ->
    not_reduced.

-spec validate_wallet_terms_currency(currency_id(), wallet_terms()) ->
    {ok, valid} | {error, currency_validation_error()}.
validate_wallet_terms_currency(CurrencyID, Terms) ->
    #domain_WalletServiceTerms{
        currencies = {value, Currencies}
    } = Terms,
    validate_currency(CurrencyID, Currencies).

-spec validate_wallet_limits(terms(), wallet()) ->
    {ok, valid}
    | {error, invalid_wallet_terms_error()}
    | {error, cash_range_validation_error()}.
validate_wallet_limits(
    Terms,
    #domain_WalletConfig{
        party_ref = #domain_PartyConfigRef{id = PartyID}
    } = Wallet
) ->
    do(fun() ->
        #domain_TermSet{wallets = WalletTerms} = Terms,
        valid = unwrap(validate_wallet_limits_terms_is_reduced(WalletTerms)),
        #domain_WalletServiceTerms{
            wallet_limit = {value, CashRange}
        } = WalletTerms,
        {AccountID, Currency} = get_wallet_account(Wallet),
        Realm = get_wallet_realm(Wallet, ff_domain_config:head()),
        Account = ff_account:build(PartyID, Realm, AccountID, Currency),
        valid = unwrap(validate_account_balance(Account, CashRange))
    end).

-spec validate_wallet_limits_terms_is_reduced(wallet_terms()) -> {ok, valid} | {error, {invalid_terms, _Details}}.
validate_wallet_limits_terms_is_reduced(Terms) ->
    #domain_WalletServiceTerms{
        wallet_limit = WalletLimitSelector
    } = Terms,
    do_validate_terms_is_reduced([
        {wallet_limit, WalletLimitSelector}
    ]).

-spec validate_withdrawal_terms_currency(currency_id(), withdrawal_terms()) ->
    {ok, valid} | {error, currency_validation_error()}.
validate_withdrawal_terms_currency(CurrencyID, Terms) ->
    #domain_WithdrawalServiceTerms{
        currencies = {value, Currencies}
    } = Terms,
    validate_currency(CurrencyID, Currencies).

-spec validate_withdrawal_cash_limit(cash(), withdrawal_terms()) ->
    {ok, valid} | {error, cash_range_validation_error()}.
validate_withdrawal_cash_limit(Cash, Terms) ->
    #domain_WithdrawalServiceTerms{
        cash_limit = {value, CashRange}
    } = Terms,
    validate_cash_range(ff_dmsl_codec:marshal(cash, Cash), CashRange).

-spec validate_withdrawal_attempt_limit(withdrawal_terms()) -> {ok, valid} | {error, attempt_limit_error()}.
validate_withdrawal_attempt_limit(Terms) ->
    #domain_WithdrawalServiceTerms{
        attempt_limit = AttemptLimit
    } = Terms,
    case AttemptLimit of
        undefined ->
            {ok, valid};
        {value, Limit} ->
            validate_attempt_limit(ff_dmsl_codec:unmarshal(attempt_limit, Limit))
    end.

-spec validate_withdrawal_terms_method(method() | undefined, ordsets:ordset(method_ref())) ->
    {ok, valid} | {error, withdrawal_method_validation_error()}.
validate_withdrawal_terms_method(undefined, _MethodRefs) ->
    %# TODO: remove this when work on TD-234
    {ok, valid};
validate_withdrawal_terms_method(Method, MethodRefs) ->
    MethodRef = ff_dmsl_codec:marshal(payment_method_ref, #{id => Method}),
    case ordsets:is_element(MethodRef, MethodRefs) of
        true ->
            {ok, valid};
        false ->
            {error, {terms_violation, {not_allowed_withdrawal_method, {MethodRef, MethodRefs}}}}
    end.

-spec validate_currency(currency_id(), ordsets:ordset(currency_ref())) ->
    {ok, valid} | {error, currency_validation_error()}.
validate_currency(CurrencyID, Currencies) ->
    CurrencyRef = #domain_CurrencyRef{symbolic_code = CurrencyID},
    case ordsets:is_element(CurrencyRef, Currencies) of
        true ->
            {ok, valid};
        false ->
            {error, {terms_violation, {not_allowed_currency, {CurrencyRef, Currencies}}}}
    end.

-spec validate_account_balance(ff_account:account(), domain_cash_range()) ->
    {ok, valid}
    | {error, cash_range_validation_error()}.
validate_account_balance(Account, CashRange) ->
    do(fun() ->
        {Amounts, CurrencyID} = unwrap(ff_accounting:balance(Account)),
        ExpMinCash = ff_dmsl_codec:marshal(cash, {ff_indef:expmin(Amounts), CurrencyID}),
        ExpMaxCash = ff_dmsl_codec:marshal(cash, {ff_indef:expmax(Amounts), CurrencyID}),
        valid = unwrap(validate_cash_range(ExpMinCash, CashRange)),
        valid = unwrap(validate_cash_range(ExpMaxCash, CashRange))
    end).

-spec validate_cash_range(domain_cash(), domain_cash_range()) -> {ok, valid} | {error, cash_range_validation_error()}.
validate_cash_range(Cash, CashRange) ->
    case is_inside(Cash, CashRange) of
        true ->
            {ok, valid};
        _ ->
            DecodedCash = ff_dmsl_codec:unmarshal(cash, Cash),
            DecodedCashRange = ff_dmsl_codec:unmarshal(cash_range, CashRange),
            {error, {terms_violation, {cash_range, {DecodedCash, DecodedCashRange}}}}
    end.

is_inside(Cash, #domain_CashRange{lower = Lower, upper = Upper}) ->
    compare_cash(fun erlang:'>'/2, Cash, Lower) andalso
        compare_cash(fun erlang:'<'/2, Cash, Upper).

compare_cash(_Fun, V, {inclusive, V}) ->
    true;
compare_cash(
    Fun,
    #domain_Cash{amount = A, currency = C},
    {_, #domain_Cash{amount = Am, currency = C}}
) ->
    Fun(A, Am).

-spec validate_attempt_limit(attempt_limit()) -> {ok, valid} | {error, attempt_limit_error()}.
validate_attempt_limit(AttemptLimit) when AttemptLimit > 0 ->
    {ok, valid};
validate_attempt_limit(AttemptLimit) ->
    {error, {terms_violation, {attempt_limit, AttemptLimit}}}.
