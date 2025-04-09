%%% Accounting
%%%
%%% TODO
%%%  - Brittle posting id assignment, it should be a level upper, maybe even in
%%%    `hg_cashflow`.
%%%  - Stuff cash flow details in the posting description fields.

-module(hg_accounting).

-export([get_account/1]).
-export([get_balance/1]).
-export([create_account/1]).
-export([create_account/2]).
-export([collect_account_map/1]).
-export([collect_merchant_account_map/4]).
-export([collect_provider_account_map/4]).
-export([collect_system_account_map/4]).
-export([collect_external_account_map/4]).

-export([hold/2]).
-export([plan/2]).
-export([commit/2]).
-export([rollback/2]).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_accounter_thrift.hrl").

-type amount() :: dmsl_domain_thrift:'Amount'().
-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type currency_code() :: dmsl_domain_thrift:'CurrencySymbolicCode'().
-type account_id() :: dmsl_accounter_thrift:'AccountID'().
-type plan_id() :: dmsl_accounter_thrift:'PlanID'().
-type batch_id() :: dmsl_accounter_thrift:'BatchID'().
-type final_cash_flow() :: hg_cashflow:final_cash_flow().
-type batch() :: {batch_id(), final_cash_flow()}.
-type posting_plan_log() :: dmsl_accounter_thrift:'PostingPlanLog'().
-type thrift_account() :: dmsl_accounter_thrift:'Account'().

-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type route() :: hg_route:payment_route().
-type payment_institution() :: dmsl_domain_thrift:'PaymentInstitution'().
-type provider() :: dmsl_domain_thrift:'Provider'().
-type varset() :: hg_varset:varset().
-type revision() :: hg_domain:revision().

-type collect_account_context() :: #{
    payment := payment(),
    party := party(),
    shop := shop(),
    route := route(),
    payment_institution := payment_institution(),
    provider := provider(),
    varset := varset(),
    revision := revision()
}.

-export_type([plan_id/0]).
-export_type([batch/0]).
-export_type([collect_account_context/0]).
-export_type([posting_plan_log/0]).

-type account() :: #{
    account_id => account_id(),
    currency_code => currency_code()
}.

-type balance() :: #{
    account_id => account_id(),
    own_amount => amount(),
    min_available_amount => amount(),
    max_available_amount => amount()
}.

-spec get_account(account_id()) -> account().
get_account(AccountID) ->
    Account = do_get_account(AccountID),
    construct_account(Account).

-spec get_balance(account_id()) -> balance().
get_balance(AccountID) ->
    Account = do_get_account(AccountID),
    construct_balance(Account).

-spec create_account(currency_code()) -> account_id().
create_account(CurrencyCode) ->
    create_account(CurrencyCode, undefined).

-spec create_account(currency_code(), binary() | undefined) -> account_id().
create_account(CurrencyCode, Description) ->
    case call_accounter('CreateAccount', {construct_prototype(CurrencyCode, Description)}) of
        {ok, Result} ->
            Result;
        {exception, Exception} ->
            % FIXME
            error({accounting, Exception})
    end.

-spec collect_account_map(collect_account_context()) -> map().
collect_account_map(#{
    payment := #domain_InvoicePayment{cost = #domain_Cash{currency = Currency}} = Payment,
    party := Party,
    shop := Shop,
    route := Route,
    payment_institution := PaymentInstitution,
    provider := Provider,
    varset := VS,
    revision := Revision
}) ->
    Map0 = collect_merchant_account_map(Currency, Party, Shop, #{}),
    Map1 = collect_provider_account_map(Payment, Provider, Route, Map0),
    Map2 = collect_system_account_map(Payment, PaymentInstitution, Revision, Map1),
    collect_external_account_map(Payment, VS, Revision, Map2).

-spec collect_merchant_account_map(currency(), party(), shop(), map()) -> map().
collect_merchant_account_map(
    Currency, #domain_PartyConfig{id = PartyID}, #domain_ShopConfig{id = ShopID, currency_configs = Configs}, Acc
) ->
    #{Currency := Config} = Configs,
    Acc#{
        merchant => {PartyID, ShopID},
        {merchant, settlement} => Config#domain_ShopCurrencyConfig.settlement,
        {merchant, guarantee} => Config#domain_ShopCurrencyConfig.guarantee
    }.

-spec collect_provider_account_map(payment(), provider(), route(), map()) -> map().
collect_provider_account_map(Payment, #domain_Provider{accounts = ProviderAccounts}, Route, Acc) ->
    Currency = get_currency(get_payment_cost(Payment)),
    ProviderAccount = hg_payment_institution:choose_provider_account(Currency, ProviderAccounts),
    Acc#{
        provider => Route,
        {provider, settlement} => ProviderAccount#domain_ProviderAccount.settlement
    }.

-spec collect_system_account_map(payment(), payment_institution(), revision(), map()) -> map().
collect_system_account_map(Payment, PaymentInstitution, Revision, Acc) ->
    Currency = get_currency(get_payment_cost(Payment)),
    SystemAccount = hg_payment_institution:get_system_account(Currency, Revision, PaymentInstitution),
    Acc#{
        {system, settlement} => SystemAccount#domain_SystemAccount.settlement,
        {system, subagent} => SystemAccount#domain_SystemAccount.subagent
    }.

-spec collect_external_account_map(payment(), varset(), revision(), map()) -> map().
collect_external_account_map(Payment, VS, Revision, Acc) ->
    Currency = get_currency(get_payment_cost(Payment)),
    case hg_payment_institution:choose_external_account(Currency, VS, Revision) of
        #domain_ExternalAccount{income = Income, outcome = Outcome} ->
            Acc#{
                {external, income} => Income,
                {external, outcome} => Outcome
            };
        undefined ->
            Acc
    end.

-spec do_get_account(account_id()) -> thrift_account().
do_get_account(AccountID) ->
    case call_accounter('GetAccountByID', {AccountID}) of
        {ok, Result} ->
            Result;
        {exception, #accounter_AccountNotFound{}} ->
            hg_woody_service_wrapper:raise(#payproc_AccountNotFound{})
    end.

construct_prototype(CurrencyCode, Description) ->
    #accounter_AccountPrototype{
        currency_sym_code = CurrencyCode,
        description = Description,
        creation_time = hg_datetime:format_now()
    }.

%%
-spec plan(plan_id(), [batch()]) -> posting_plan_log().
plan(_PlanID, []) ->
    error(badarg);
plan(_PlanID, Batches) when not is_list(Batches) ->
    error(badarg);
plan(PlanID, Batches) ->
    lists:foldl(
        fun(Batch, _) -> hold(PlanID, Batch) end,
        undefined,
        Batches
    ).

-spec hold(plan_id(), batch()) -> posting_plan_log().
hold(PlanID, Batch) ->
    do('Hold', construct_plan_change(PlanID, Batch)).

-spec commit(plan_id(), [batch()]) -> posting_plan_log().
commit(PlanID, Batches) ->
    do('CommitPlan', construct_plan(PlanID, Batches)).

-spec rollback(plan_id(), [batch()]) -> posting_plan_log().
rollback(PlanID, Batches) ->
    do('RollbackPlan', construct_plan(PlanID, Batches)).

do(Op, Plan) ->
    case call_accounter(Op, {Plan}) of
        {ok, Clock} ->
            Clock;
        {exception, Exception} ->
            % FIXME
            error({accounting, Exception})
    end.

construct_plan_change(PlanID, {BatchID, Cashflow}) ->
    #accounter_PostingPlanChange{
        id = PlanID,
        batch = #accounter_PostingBatch{
            id = BatchID,
            postings = collect_postings(Cashflow)
        }
    }.

construct_plan(PlanID, Batches) ->
    #accounter_PostingPlan{
        id = PlanID,
        batch_list = [
            #accounter_PostingBatch{
                id = BatchID,
                postings = collect_postings(Cashflow)
            }
         || {BatchID, Cashflow} <- Batches
        ]
    }.

collect_postings(Cashflow) ->
    [
        #accounter_Posting{
            from_id = Source,
            to_id = Destination,
            amount = Amount,
            currency_sym_code = CurrencyCode,
            description = construct_posting_description(Details)
        }
     || #domain_FinalCashFlowPosting{
            source = #domain_FinalCashFlowAccount{account_id = Source},
            destination = #domain_FinalCashFlowAccount{account_id = Destination},
            details = Details,
            volume = #domain_Cash{
                amount = Amount,
                currency = #domain_CurrencyRef{symbolic_code = CurrencyCode}
            }
        } <- Cashflow
    ].

construct_posting_description(Details) when is_binary(Details) ->
    Details;
construct_posting_description(undefined) ->
    <<>>.

%%

construct_account(
    #accounter_Account{
        id = AccountID,
        currency_sym_code = CurrencyCode
    }
) ->
    #{
        account_id => AccountID,
        currency_code => CurrencyCode
    }.

construct_balance(
    #accounter_Account{
        id = AccountID,
        own_amount = OwnAmount,
        min_available_amount = MinAvailableAmount,
        max_available_amount = MaxAvailableAmount
    }
) ->
    #{
        account_id => AccountID,
        own_amount => OwnAmount,
        min_available_amount => MinAvailableAmount,
        max_available_amount => MaxAvailableAmount
    }.

%%

call_accounter(Function, Args) ->
    hg_woody_wrapper:call(accounter, Function, Args).

get_payment_cost(#domain_InvoicePayment{changed_cost = Cost}) when Cost =/= undefined ->
    Cost;
get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_currency(#domain_Cash{currency = Currency}) ->
    Currency.
