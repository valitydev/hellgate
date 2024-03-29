-module(hg_ct_fixture).

-include("hg_ct_domain.hrl").

%%

-export([construct_currency/1]).
-export([construct_currency/2]).
-export([construct_category/2]).
-export([construct_category/3]).
-export([construct_payment_method/1]).
-export([construct_payout_method/1]).
-export([construct_proxy/2]).
-export([construct_proxy/3]).
-export([construct_inspector/3]).
-export([construct_inspector/4]).
-export([construct_inspector/5]).
-export([construct_contract_template/2]).
-export([construct_contract_template/4]).
-export([construct_provider_account_set/1]).
-export([construct_system_account_set/1]).
-export([construct_system_account_set/3]).
-export([construct_external_account_set/1]).
-export([construct_external_account_set/3]).
-export([construct_business_schedule/1]).
-export([construct_dummy_additional_info/0]).
-export([construct_payment_routing_ruleset/3]).
-export([construct_routing_delegate/2]).
-export([construct_routing_candidate/2]).
-export([construct_bank_card_category/4]).
-export([construct_payment_system/2]).
-export([construct_mobile_operator/2]).
-export([construct_payment_service/2]).
-export([construct_crypto_currency/2]).
-export([construct_tokenized_service/2]).

%%

-type name() :: binary().
-type category() :: dmsl_domain_thrift:'CategoryRef'().
-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type proxy() :: dmsl_domain_thrift:'ProxyRef'().
-type inspector() :: dmsl_domain_thrift:'InspectorRef'().
-type risk_score() :: hg_inspector:risk_score().
-type template() :: dmsl_domain_thrift:'ContractTemplateRef'().
-type terms() :: dmsl_domain_thrift:'TermSetHierarchyRef'().
-type lifetime() :: dmsl_domain_thrift:'Lifetime'() | undefined.
-type payment_routing_ruleset() :: dmsl_domain_thrift:'RoutingRulesetRef'().
-type payment_system() :: dmsl_domain_thrift:'PaymentSystemRef'().
-type mobile_operator() :: dmsl_domain_thrift:'MobileOperatorRef'().
-type payment_service() :: dmsl_domain_thrift:'PaymentServiceRef'().
-type crypto_currency() :: dmsl_domain_thrift:'CryptoCurrencyRef'().
-type tokenized_service() :: dmsl_domain_thrift:'BankCardTokenServiceRef'().

-type system_account_set() :: dmsl_domain_thrift:'SystemAccountSetRef'().
-type external_account_set() :: dmsl_domain_thrift:'ExternalAccountSetRef'().

-type business_schedule() :: dmsl_domain_thrift:'BusinessScheduleRef'().

-type bank_card_category() :: dmsl_domain_thrift:'BankCardCategoryRef'().

%%

-define(EVERY, {every, #base_ScheduleEvery{}}).

%%

-spec construct_currency(currency()) -> {currency, dmsl_domain_thrift:'CurrencyObject'()}.
construct_currency(Ref) ->
    construct_currency(Ref, 2).

-spec construct_currency(currency(), Exponent :: pos_integer()) -> {currency, dmsl_domain_thrift:'CurrencyObject'()}.
construct_currency(?cur(SymbolicCode) = Ref, Exponent) ->
    {currency, #domain_CurrencyObject{
        ref = Ref,
        data = #domain_Currency{
            name = SymbolicCode,
            numeric_code = 666,
            symbolic_code = SymbolicCode,
            exponent = Exponent
        }
    }}.

-spec construct_category(category(), name()) -> {category, dmsl_domain_thrift:'CategoryObject'()}.
construct_category(Ref, Name) ->
    construct_category(Ref, Name, test).

-spec construct_category(category(), name(), test | live) -> {category, dmsl_domain_thrift:'CategoryObject'()}.
construct_category(Ref, Name, Type) ->
    {category, #domain_CategoryObject{
        ref = Ref,
        data = #domain_Category{
            name = Name,
            description = Name,
            type = Type
        }
    }}.

-spec construct_payment_method(dmsl_domain_thrift:'PaymentMethodRef'()) ->
    {payment_method, dmsl_domain_thrift:'PaymentMethodObject'()}.
construct_payment_method(?pmt(mobile, ?mob(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(_, ?pmt_srv(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(crypto_currency, ?crypta(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(bank_card, ?token_bank_card(Name, _)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(bank_card, ?bank_card(Name)) = Ref) ->
    construct_payment_method(Name, Ref);
construct_payment_method(?pmt(_Type, #domain_BankCardPaymentMethod{} = PM) = Ref) ->
    construct_payment_method(PM#domain_BankCardPaymentMethod.payment_system, Ref).

construct_payment_method(Name, Ref) when is_atom(Name) ->
    construct_payment_method(atom_to_binary(Name, unicode), Ref);
construct_payment_method(Name, Ref) when is_binary(Name) ->
    {payment_method, #domain_PaymentMethodObject{
        ref = Ref,
        data = #domain_PaymentMethodDefinition{
            name = Name,
            description = Name
        }
    }}.

-spec construct_payout_method(dmsl_domain_thrift:'PayoutMethodRef'()) ->
    {payout_method, dmsl_domain_thrift:'PayoutMethodObject'()}.
construct_payout_method(?pomt(M) = Ref) ->
    Def = erlang:atom_to_binary(M, unicode),
    {payout_method, #domain_PayoutMethodObject{
        ref = Ref,
        data = #domain_PayoutMethodDefinition{
            name = Def,
            description = Def
        }
    }}.

-spec construct_proxy(proxy(), name()) -> {proxy, dmsl_domain_thrift:'ProxyObject'()}.
construct_proxy(Ref, Name) ->
    construct_proxy(Ref, Name, #{}).

-spec construct_proxy(proxy(), name(), Opts :: map()) -> {proxy, dmsl_domain_thrift:'ProxyObject'()}.
construct_proxy(Ref, Name, Opts) ->
    {proxy, #domain_ProxyObject{
        ref = Ref,
        data = #domain_ProxyDefinition{
            name = Name,
            description = Name,
            url = <<>>,
            options = Opts
        }
    }}.

-spec construct_inspector(inspector(), name(), proxy()) -> {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef) ->
    construct_inspector(Ref, Name, ProxyRef, #{}).

-spec construct_inspector(inspector(), name(), proxy(), Additional :: map()) ->
    {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef, Additional) ->
    construct_inspector(Ref, Name, ProxyRef, Additional, undefined).

-spec construct_inspector(inspector(), name(), proxy(), Additional :: map(), undefined | risk_score()) ->
    {inspector, dmsl_domain_thrift:'InspectorObject'()}.
construct_inspector(Ref, Name, ProxyRef, Additional, FallBackScore) ->
    {inspector, #domain_InspectorObject{
        ref = Ref,
        data = #domain_Inspector{
            name = Name,
            description = Name,
            proxy = #domain_Proxy{
                ref = ProxyRef,
                additional = Additional
            },
            fallback_risk_score = FallBackScore
        }
    }}.

-spec construct_contract_template(template(), terms()) ->
    {contract_template, dmsl_domain_thrift:'ContractTemplateObject'()}.
construct_contract_template(Ref, TermsRef) ->
    construct_contract_template(Ref, TermsRef, undefined, undefined).

-spec construct_contract_template(template(), terms(), ValidSince :: lifetime(), ValidUntil :: lifetime()) ->
    {contract_template, dmsl_domain_thrift:'ContractTemplateObject'()}.
construct_contract_template(Ref, TermsRef, ValidSince, ValidUntil) ->
    {contract_template, #domain_ContractTemplateObject{
        ref = Ref,
        data = #domain_ContractTemplate{
            valid_since = ValidSince,
            valid_until = ValidUntil,
            terms = TermsRef
        }
    }}.

-spec construct_provider_account_set([currency()]) -> dmsl_domain_thrift:'ProviderAccountSet'().
construct_provider_account_set(Currencies) ->
    ok = hg_context:save(hg_context:create()),
    AccountSet = lists:foldl(
        fun(Cur = ?cur(Code), Acc) ->
            Acc#{Cur => ?prvacc(hg_accounting:create_account(Code))}
        end,
        #{},
        Currencies
    ),
    _ = hg_context:cleanup(),
    AccountSet.

-spec construct_system_account_set(system_account_set()) ->
    {system_account_set, dmsl_domain_thrift:'SystemAccountSetObject'()}.
construct_system_account_set(Ref) ->
    construct_system_account_set(Ref, <<"Primaries">>, ?cur(<<"RUB">>)).

-spec construct_system_account_set(system_account_set(), name(), currency()) ->
    {system_account_set, dmsl_domain_thrift:'SystemAccountSetObject'()}.
construct_system_account_set(Ref, Name, ?cur(CurrencyCode)) ->
    ok = hg_context:save(hg_context:create()),
    SettlementAccountID = hg_accounting:create_account(CurrencyCode),
    SubagentAccountID = hg_accounting:create_account(CurrencyCode),
    hg_context:cleanup(),
    {system_account_set, #domain_SystemAccountSetObject{
        ref = Ref,
        data = #domain_SystemAccountSet{
            name = Name,
            description = Name,
            accounts = #{
                ?cur(CurrencyCode) => #domain_SystemAccount{
                    settlement = SettlementAccountID,
                    subagent = SubagentAccountID
                }
            }
        }
    }}.

-spec construct_external_account_set(external_account_set()) ->
    {external_account_set, dmsl_domain_thrift:'ExternalAccountSetObject'()}.
construct_external_account_set(Ref) ->
    construct_external_account_set(Ref, <<"Primaries">>, ?cur(<<"RUB">>)).

-spec construct_external_account_set(external_account_set(), name(), currency()) ->
    {external_account_set, dmsl_domain_thrift:'ExternalAccountSetObject'()}.
construct_external_account_set(Ref, Name, ?cur(CurrencyCode)) ->
    ok = hg_context:save(hg_context:create()),
    AccountID1 = hg_accounting:create_account(CurrencyCode),
    AccountID2 = hg_accounting:create_account(CurrencyCode),
    hg_context:cleanup(),
    {external_account_set, #domain_ExternalAccountSetObject{
        ref = Ref,
        data = #domain_ExternalAccountSet{
            name = Name,
            description = Name,
            accounts = #{
                ?cur(<<"RUB">>) => #domain_ExternalAccount{
                    income = AccountID1,
                    outcome = AccountID2
                }
            }
        }
    }}.

-spec construct_business_schedule(business_schedule()) ->
    {business_schedule, dmsl_domain_thrift:'BusinessScheduleObject'()}.
construct_business_schedule(Ref) ->
    {business_schedule, #domain_BusinessScheduleObject{
        ref = Ref,
        data = #domain_BusinessSchedule{
            name = <<"Every day at 7:40">>,
            schedule = #base_Schedule{
                year = ?EVERY,
                month = ?EVERY,
                day_of_month = ?EVERY,
                day_of_week = ?EVERY,
                hour = {on, [7]},
                minute = {on, [40]},
                second = {on, [0]}
            }
        }
    }}.

-spec construct_dummy_additional_info() -> dmsl_domain_thrift:'AdditionalTransactionInfo'().
construct_dummy_additional_info() ->
    #domain_AdditionalTransactionInfo{rrn = <<"rrn">>, approval_code = <<"code">>}.

-spec construct_payment_routing_ruleset(payment_routing_ruleset(), name(), _) -> dmsl_domain_thrift:'DomainObject'().
construct_payment_routing_ruleset(Ref, Name, Decisions) ->
    {routing_rules, #domain_RoutingRulesObject{
        ref = Ref,
        data = #domain_RoutingRuleset{
            name = Name,
            decisions = Decisions
        }
    }}.

-spec construct_routing_delegate(_RuleSetRef, _Predicate) -> dmsl_domain_thrift:'RoutingDelegate'().
construct_routing_delegate(Ref, Predicate) ->
    #domain_RoutingDelegate{
        allowed = Predicate,
        ruleset = Ref
    }.

-spec construct_routing_candidate(_, _) -> dmsl_domain_thrift:'RoutingCandidate'().
construct_routing_candidate(TerminalRef, Predicate) ->
    #domain_RoutingCandidate{
        allowed = Predicate,
        terminal = TerminalRef
    }.

-spec construct_bank_card_category(bank_card_category(), binary(), binary(), [binary()]) ->
    {bank_card_category, dmsl_domain_thrift:'BankCardCategoryObject'()}.
construct_bank_card_category(Ref, Name, Description, Patterns) ->
    {bank_card_category, #domain_BankCardCategoryObject{
        ref = Ref,
        data = #domain_BankCardCategory{
            name = Name,
            description = Description,
            category_patterns = Patterns
        }
    }}.

-spec construct_payment_system(payment_system(), name()) ->
    {payment_system, dmsl_domain_thrift:'PaymentSystemObject'()}.
construct_payment_system(Ref, Name) ->
    {payment_system, #domain_PaymentSystemObject{
        ref = Ref,
        data = #domain_PaymentSystem{
            name = Name
        }
    }}.

-spec construct_mobile_operator(mobile_operator(), name()) ->
    {mobile_operator, dmsl_domain_thrift:'MobileOperatorObject'()}.
construct_mobile_operator(Ref, Name) ->
    {mobile_operator, #domain_MobileOperatorObject{
        ref = Ref,
        data = #domain_MobileOperator{
            name = Name
        }
    }}.

-spec construct_payment_service(payment_service(), name()) ->
    {payment_service, dmsl_domain_thrift:'PaymentServiceObject'()}.
construct_payment_service(Ref, Name) ->
    {payment_service, #domain_PaymentServiceObject{
        ref = Ref,
        data = #domain_PaymentService{
            name = Name,
            brand_name = string:uppercase(Name)
        }
    }}.

-spec construct_crypto_currency(crypto_currency(), name()) ->
    {crypto_currency, dmsl_domain_thrift:'CryptoCurrencyObject'()}.
construct_crypto_currency(Ref, Name) ->
    {crypto_currency, #domain_CryptoCurrencyObject{
        ref = Ref,
        data = #domain_CryptoCurrency{
            name = Name
        }
    }}.

-spec construct_tokenized_service(tokenized_service(), name()) ->
    {payment_token, dmsl_domain_thrift:'BankCardTokenServiceObject'()}.
construct_tokenized_service(Ref, Name) ->
    {payment_token, #domain_BankCardTokenServiceObject{
        ref = Ref,
        data = #domain_BankCardTokenService{
            name = Name
        }
    }}.
