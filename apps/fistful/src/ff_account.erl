%%%
%%% Account
%%%
%%% Responsible for, at least:
%%%  - managing partymgmt-related wallet stuff,
%%%  - acknowledging transfer postings,
%%%  - accounting and checking limits.
%%%

-module(ff_account).

-include_lib("damsel/include/dmsl_accounter_thrift.hrl").

-type account_id() :: dmsl_accounter_thrift:'AccountID'().
-type amount() :: dmsl_domain_thrift:'Amount'().
-type party_id() :: ff_party:id().
-type realm() :: ff_payment_institution:realm().

-type account() :: #{
    realm := realm(),
    party_id => party_id(),
    currency := currency_id(),
    account_id := account_id()
}.

-type account_balance() :: #{
    account_id := account_id(),
    currency := ff_currency:id(),
    expected_min := amount(),
    current := amount(),
    expected_max := amount()
}.

-type event() ::
    {created, account()}.

-type create_error() ::
    {terms, ff_party:validate_account_creation_error()}
    | {party, ff_party:inaccessibility()}.

-export_type([account_id/0]).
-export_type([account/0]).
-export_type([event/0]).
-export_type([create_error/0]).
-export_type([account_balance/0]).

-export([party_id/1]).
-export([realm/1]).
-export([currency/1]).
-export([account_id/1]).

-export([build/3]).
-export([build/4]).
-export([create/3]).
-export([is_accessible/1]).

-export([apply_event/2]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1]).

%% Internal types

-type currency() :: ff_currency:currency().
-type currency_id() :: ff_currency:id().

%% Accessors

-spec party_id(account()) -> party_id() | undefined.
-spec realm(account()) -> realm().
-spec currency(account()) -> currency_id().
-spec account_id(account()) -> account_id().

party_id(Account) ->
    maps:get(party_id, Account, undefined).

realm(#{realm := V}) ->
    V.

currency(#{currency := CurrencyID}) ->
    CurrencyID.

account_id(#{account_id := AccounterID}) ->
    AccounterID.

%% Actuators

-spec build(realm(), account_id(), currency_id()) -> account().
build(Realm, AccountID, CurrencyID) ->
    #{
        realm => Realm,
        currency => CurrencyID,
        account_id => AccountID
    }.

-spec build(party_id(), realm(), account_id(), currency_id()) -> account().
build(PartyID, Realm, AccountID, CurrencyID) ->
    #{
        realm => Realm,
        party_id => PartyID,
        currency => CurrencyID,
        account_id => AccountID
    }.

-spec create(party_id(), realm(), currency()) -> {ok, [event()]}.
create(PartyID, Realm, Currency) ->
    CurrencyID = ff_currency:id(Currency),
    CurrencyCode = ff_currency:symcode(Currency),
    {ok, AccountID} = ff_accounting:create_account(CurrencyCode, atom_to_binary(Realm)),
    {ok, [
        {created, #{
            realm => Realm,
            party_id => PartyID,
            currency => CurrencyID,
            account_id => AccountID
        }}
    ]}.

-spec is_accessible(account()) ->
    {ok, accessible}
    | {error, ff_party:inaccessibility()}.
is_accessible(Account) ->
    do(fun() ->
        case party_id(Account) of
            undefined ->
                accessible;
            PartyID ->
                unwrap(ff_party:is_accessible(PartyID))
        end
    end).

%% State

-spec apply_event(event(), ff_maybe:'maybe'(account())) -> account().
apply_event({created, Account}, undefined) ->
    Account.
