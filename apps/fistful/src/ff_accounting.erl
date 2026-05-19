%%%
%%% Financial transaction between accounts
%%%
-module(ff_accounting).

-include_lib("damsel/include/dmsl_accounter_thrift.hrl").

%%

-type id() :: dmsl_accounter_thrift:'PlanID'().
-type account() :: ff_account:account().
-type account_id() :: ff_account:account_id().
-type currency_code() :: dmsl_domain_thrift:'CurrencySymbolicCode'().
-type amount() :: dmsl_domain_thrift:'Amount'().
-type body() :: ff_cash:cash().
-type posting() :: {account_id(), account_id(), body()}.
-type balance() :: {ff_indef:indef(amount()), ff_currency:id()}.
-type posting_plan_log() :: dmsl_accounter_thrift:'PostingPlanLog'().

-export_type([id/0]).
-export_type([body/0]).
-export_type([account/0]).
-export_type([posting/0]).

-export([balance/1]).
-export([balance/2]).
-export([create_account/2]).

-export([prepare_trx/2]).
-export([commit_trx/2]).
-export([cancel_trx/2]).

%%

-spec balance(account()) -> {ok, balance()}.
balance(Account) ->
    AccountID = ff_account:account_id(Account),
    Currency = ff_account:currency(Account),
    {ok, ThriftAccount} = get_account_by_id(AccountID),
    {ok, build_account_balance(ThriftAccount, Currency)}.

-spec balance(account_id(), currency_code()) -> {ok, balance()}.
balance(AccountID, Currency) ->
    {ok, ThriftAccount} = get_account_by_id(AccountID),
    {ok, build_account_balance(ThriftAccount, Currency)}.

-spec create_account(currency_code(), binary() | undefined) ->
    {ok, account_id()}
    | {error, {exception, any()}}.
create_account(CurrencyCode, Description) ->
    case call('CreateAccount', {construct_prototype(CurrencyCode, Description)}) of
        {ok, Result} ->
            {ok, Result};
        {exception, Exception} ->
            {error, {exception, Exception}}
    end.

-spec prepare_trx(id(), [posting()]) -> {ok, posting_plan_log()}.
prepare_trx(ID, Postings) ->
    hold(encode_plan_change(ID, Postings)).

-spec commit_trx(id(), [posting()]) -> {ok, posting_plan_log()}.
commit_trx(ID, Postings) ->
    commit_plan(encode_plan(ID, Postings)).

-spec cancel_trx(id(), [posting()]) -> {ok, posting_plan_log()}.
cancel_trx(ID, Postings) ->
    rollback_plan(encode_plan(ID, Postings)).

%% Woody stuff

get_account_by_id(ID) ->
    case call('GetAccountByID', {ID}) of
        {ok, Account} ->
            {ok, Account};
        {exception, Unexpected} ->
            error(Unexpected)
    end.

hold(PlanChange) ->
    case call('Hold', {PlanChange}) of
        {ok, PostingPlanLog} ->
            {ok, PostingPlanLog};
        {exception, Unexpected} ->
            error(Unexpected)
    end.

commit_plan(Plan) ->
    case call('CommitPlan', {Plan}) of
        {ok, PostingPlanLog} ->
            {ok, PostingPlanLog};
        {exception, Unexpected} ->
            error(Unexpected)
    end.

rollback_plan(Plan) ->
    case call('RollbackPlan', {Plan}) of
        {ok, PostingPlanLog} ->
            {ok, PostingPlanLog};
        {exception, Unexpected} ->
            error(Unexpected)
    end.

call(Function, Args) ->
    Service = {dmsl_accounter_thrift, 'Accounter'},
    ff_woody_client:call(accounter, {Service, Function, Args}).

encode_plan_change(ID, Postings) ->
    #accounter_PostingPlanChange{
        id = ID,
        batch = encode_batch(Postings)
    }.

encode_plan(ID, Postings) ->
    #accounter_PostingPlan{
        id = ID,
        batch_list = [encode_batch(Postings)]
    }.

encode_batch(Postings) ->
    #accounter_PostingBatch{
        % TODO
        id = 1,
        postings = [
            encode_posting(Source, Destination, Body)
         || {Source, Destination, Body} <- Postings
        ]
    }.

encode_posting(Source, Destination, {Amount, Currency}) ->
    #accounter_Posting{
        from_id = Source,
        to_id = Destination,
        amount = Amount,
        currency_sym_code = Currency,
        description = <<"TODO">>
    }.

build_account_balance(
    #accounter_Account{
        own_amount = Own,
        max_available_amount = MaxAvail,
        min_available_amount = MinAvail
    },
    Currency
) ->
    {ff_indef:new(MinAvail, Own, MaxAvail), Currency}.

construct_prototype(CurrencyCode, Description) ->
    #accounter_AccountPrototype{
        currency_sym_code = CurrencyCode,
        description = Description
    }.
