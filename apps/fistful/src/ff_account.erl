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

-type id() :: binary().
-type accounter_account_id() :: dmsl_accounter_thrift:'AccountID'().
-type account() :: #{
    id := id(),
    identity := identity_id(),
    currency := currency_id(),
    accounter_account_id := accounter_account_id()
}.

-type amount() :: dmsl_domain_thrift:'Amount'().

-type account_balance() :: #{
    id := id(),
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

-export_type([id/0]).
-export_type([accounter_account_id/0]).
-export_type([account/0]).
-export_type([event/0]).
-export_type([create_error/0]).
-export_type([account_balance/0]).

-export([id/1]).
-export([identity/1]).
-export([currency/1]).
-export([accounter_account_id/1]).

-export([create/3]).
-export([is_accessible/1]).
-export([check_account_creation/3]).

-export([apply_event/2]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1, unwrap/2]).

%% Internal types

-type identity() :: ff_identity:identity_state().
-type currency() :: ff_currency:currency().
-type identity_id() :: ff_identity:id().
-type currency_id() :: ff_currency:id().

%% Accessors

-spec id(account()) -> id().
-spec identity(account()) -> identity_id().
-spec currency(account()) -> currency_id().
-spec accounter_account_id(account()) -> accounter_account_id().

id(#{id := ID}) ->
    ID.

identity(#{identity := IdentityID}) ->
    IdentityID.

currency(#{currency := CurrencyID}) ->
    CurrencyID.

accounter_account_id(#{accounter_account_id := AccounterID}) ->
    AccounterID.

%% Actuators

-spec create(id(), identity(), currency()) -> {ok, [event()]} | {error, create_error()}.
create(ID, Identity, Currency) ->
    do(fun() ->
        unwrap(check_account_creation(ID, Identity, Currency)),
        CurrencyID = ff_currency:id(Currency),
        CurrencyCode = ff_currency:symcode(Currency),
        Description = ff_string:join($/, [<<"ff/account">>, ID]),
        {ok, AccounterID} = ff_accounting:create_account(CurrencyCode, Description),
        [
            {created, #{
                id => ID,
                identity => ff_identity:id(Identity),
                currency => CurrencyID,
                accounter_account_id => AccounterID
            }}
        ]
    end).

-spec is_accessible(account()) ->
    {ok, accessible}
    | {error, ff_party:inaccessibility()}.
is_accessible(Account) ->
    do(fun() ->
        Identity = get_identity(Account),
        accessible = unwrap(ff_identity:is_accessible(Identity))
    end).

-spec check_account_creation(id(), identity(), currency()) ->
    {ok, valid}
    | {error, create_error()}.
check_account_creation(ID, Identity, Currency) ->
    do(fun() ->
        DomainRevision = ff_domain_config:head(),
        PartyID = ff_identity:party(Identity),
        accessible = unwrap(party, ff_party:is_accessible(PartyID)),
        TermVarset = #{
            wallet_id => ID,
            currency => ff_currency:to_domain_ref(Currency)
        },
        {ok, PartyRevision} = ff_party:get_revision(PartyID),
        Terms = ff_identity:get_terms(Identity, #{
            party_revision => PartyRevision,
            domain_revision => DomainRevision,
            varset => TermVarset
        }),
        CurrencyID = ff_currency:id(Currency),
        valid = unwrap(terms, ff_party:validate_account_creation(Terms, CurrencyID))
    end).

get_identity(Account) ->
    {ok, V} = ff_identity_machine:get(identity(Account)),
    ff_identity_machine:identity(V).

%% State

-spec apply_event(event(), ff_maybe:'maybe'(account())) -> account().
apply_event({created, Account}, undefined) ->
    Account.
