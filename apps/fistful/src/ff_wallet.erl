%%%
%%% Wallet
%%%

-module(ff_wallet).

-type id() :: binary().
-type account_id() :: ff_account:id().
-type external_id() :: id() | undefined.
-type metadata() :: ff_entity_context:md().

-define(ACTUAL_FORMAT_VERSION, 2).

-type wallet_state() :: #{
    name := binary(),
    blocking := blocking(),
    account => account(),
    external_id => account_id(),
    metadata => metadata(),
    created_at => ff_time:timestamp_ms()
}.

-type wallet() :: #{
    version := ?ACTUAL_FORMAT_VERSION,
    name := binary(),
    blocking := blocking(),
    external_id => account_id(),
    metadata => metadata(),
    created_at => ff_time:timestamp_ms()
}.

-type event() ::
    {created, wallet()}
    | {account, ff_account:event()}.

-type params() :: #{
    id := account_id(),
    identity := ff_identity_machine:id(),
    name := binary(),
    currency := ff_currency:id(),
    external_id => account_id(),
    metadata => metadata()
}.

-type check_params() :: #{
    identity := ff_identity_machine:id(),
    currency := ff_currency:id()
}.

-type create_error() ::
    {identity, notfound}
    | {currency, notfound}
    | ff_account:create_error().

-type check_error() ::
    {identity, notfound}
    | {currency, notfound}.

-export_type([id/0]).
-export_type([account_id/0]).
-export_type([wallet/0]).
-export_type([wallet_state/0]).
-export_type([event/0]).
-export_type([create_error/0]).
-export_type([params/0]).

-type inaccessibility() ::
    {inaccessible, blocked}.

-export_type([inaccessibility/0]).

-export([account/1]).
-export([id/1]).
-export([identity/1]).
-export([name/1]).
-export([currency/1]).
-export([blocking/1]).
-export([external_id/1]).
-export([created_at/1]).
-export([metadata/1]).

-export([create/1]).
-export([is_accessible/1]).
-export([close/1]).
-export([get_account_balance/1]).
-export([check_creation/1]).
-export([log_balance/1]).

-export([apply_event/2]).

%% Internal types

-type account() :: ff_account:account().
-type identity() :: ff_identity:id().
-type currency() :: ff_currency:id().
-type blocking() :: unblocked | blocked.

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1, unwrap/2]).

%% Accessors

-spec account(wallet_state()) -> account().

-spec id(wallet_state()) -> account_id().
-spec identity(wallet_state()) -> identity().
-spec name(wallet_state()) -> binary().
-spec currency(wallet_state()) -> currency().
-spec blocking(wallet_state()) -> blocking().

account(Wallet) ->
    maps:get(account, Wallet, undefined).

id(Wallet) ->
    ff_account:id(account(Wallet)).

identity(Wallet) ->
    ff_account:identity(account(Wallet)).

name(Wallet) ->
    maps:get(name, Wallet, <<>>).

currency(Wallet) ->
    ff_account:currency(account(Wallet)).

blocking(#{blocking := Blocking}) ->
    Blocking.

-spec external_id(wallet_state()) -> external_id().
external_id(#{external_id := ExternalID}) ->
    ExternalID;
external_id(_Wallet) ->
    undefined.

-spec created_at(wallet_state()) -> ff_time:timestamp_ms().
created_at(#{created_at := CreatedAt}) ->
    CreatedAt.

-spec metadata(wallet_state()) -> metadata() | undefined.
metadata(Wallet) ->
    maps:get(metadata, Wallet, undefined).

%%

-spec create(params()) ->
    {ok, [event()]}
    | {error, create_error()}.
create(Params = #{id := ID, name := Name}) ->
    do(fun() ->
        {Identity, Currency} = unwrap(check_creation(maps:with([identity, currency], Params))),
        Wallet = genlib_map:compact(#{
            version => ?ACTUAL_FORMAT_VERSION,
            name => Name,
            blocking => unblocked,
            created_at => ff_time:now(),
            external_id => maps:get(external_id, Params, undefined),
            metadata => maps:get(metadata, Params, undefined)
        }),
        [{created, Wallet}] ++
            [{account, Ev} || Ev <- unwrap(ff_account:create(ID, Identity, Currency))]
    end).

-spec is_accessible(wallet_state()) ->
    {ok, accessible}
    | {error, inaccessibility()}.
is_accessible(Wallet) ->
    do(fun() ->
        accessible = unwrap(check_accessible(Wallet)),
        accessible = unwrap(ff_account:is_accessible(account(Wallet)))
    end).

-spec close(wallet_state()) ->
    {ok, [event()]}
    | {error,
        inaccessibility()
        | {account, pending}}.
close(Wallet) ->
    do(fun() ->
        accessible = unwrap(is_accessible(Wallet)),
        % TODO
        []
    end).

-spec check_creation(check_params()) ->
    {ok, {ff_identity:identity_state(), ff_currency:currency()}}
    | {error, check_error()}.

check_creation(#{identity := IdentityID, currency := CurrencyID}) ->
    do(fun() ->
        IdentityMachine = unwrap(identity, ff_identity_machine:get(IdentityID)),
        Identity = ff_identity_machine:identity(IdentityMachine),
        Currency = unwrap(currency, ff_currency:get(CurrencyID)),
        {Identity, Currency}
    end).

-spec log_balance(id()) -> ok.
log_balance(WalletID) ->
    case ff_wallet_machine:get(WalletID) of
        {ok, Machine} ->
            Wallet = ff_wallet_machine:wallet(Machine),
            {ok, {Amounts, Currency}} = ff_accounting:balance(account(Wallet)),
            logger:log(notice, "Wallet balance", [], #{
                wallet => #{
                    id => WalletID,
                    balance => #{
                        amount => ff_indef:current(Amounts),
                        currency => Currency
                    }
                }
            }),
            ok;
        {error, notfound} ->
            ok
    end.

%%

-spec apply_event(event(), undefined | wallet_state()) -> wallet_state().
apply_event({created, Wallet}, undefined) ->
    Wallet;
apply_event({account, Ev}, Wallet) ->
    Account = maps:get(account, Wallet, undefined),
    Wallet#{account => ff_account:apply_event(Ev, Account)}.

%% Internal functions

-spec check_accessible(wallet_state()) ->
    {ok, accessible}
    | {error, inaccessibility()}.
check_accessible(Wallet) ->
    case blocking(Wallet) of
        unblocked ->
            {ok, accessible};
        blocked ->
            {error, blocked}
    end.

-spec get_account_balance(wallet_state()) -> {ok, ff_account:account_balance()}.
get_account_balance(Wallet) ->
    Account = ff_wallet:account(Wallet),
    {ok, {Amounts, Currency}} = ff_accounting:balance(Account),
    AccountBalance = #{
        id => ff_account:id(Account),
        currency => Currency,
        expected_min => ff_indef:expmin(Amounts),
        current => ff_indef:current(Amounts),
        expected_max => ff_indef:expmax(Amounts)
    },
    {ok, AccountBalance}.
