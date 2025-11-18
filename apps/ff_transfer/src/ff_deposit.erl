%%%
%%% Deposit
%%%

-module(ff_deposit).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-type id() :: binary().
-type description() :: binary().

-define(ACTUAL_FORMAT_VERSION, 3).

-opaque deposit_state() :: #{
    id := id(),
    body := body(),
    is_negative := is_negative(),
    params := transfer_params(),
    domain_revision => domain_revision(),
    created_at => ff_time:timestamp_ms(),
    p_transfer => p_transfer(),
    status => status(),
    metadata => metadata(),
    external_id => id(),
    limit_checks => [limit_check_details()],
    description => description()
}.

-opaque deposit() :: #{
    version := ?ACTUAL_FORMAT_VERSION,
    id := id(),
    body := body(),
    params := transfer_params(),
    domain_revision := domain_revision(),
    created_at := ff_time:timestamp_ms(),
    metadata => metadata(),
    external_id => id(),
    description => description()
}.

-type params() :: #{
    id := id(),
    body := ff_accounting:body(),
    source_id := ff_source:id(),
    party_id := party_id(),
    wallet_id := wallet_id(),
    external_id => external_id(),
    description => description(),
    metadata => metadata()
}.

-type status() ::
    pending
    | succeeded
    | {failed, failure()}.

-type event() ::
    {created, deposit()}
    | {limit_check, limit_check_details()}
    | {p_transfer, ff_postings_transfer:event()}
    | {status_changed, status()}.

-type limit_check_details() ::
    {wallet_receiver, wallet_limit_check_details()}.

-type wallet_limit_check_details() ::
    ok
    | {failed, wallet_limit_check_error()}.

-type wallet_limit_check_error() :: #{
    expected_range := cash_range(),
    balance := cash()
}.

-type create_error() ::
    {source, notfound | unauthorized}
    | {wallet, notfound}
    | {party, notfound}
    | ff_party:validate_deposit_creation_error()
    | {inconsistent_currency, {Deposit :: currency_id(), Source :: currency_id(), Wallet :: currency_id()}}.

-export_type([deposit/0]).
-export_type([deposit_state/0]).
-export_type([id/0]).
-export_type([params/0]).
-export_type([event/0]).
-export_type([create_error/0]).
-export_type([limit_check_details/0]).

%% Accessors

-export([wallet_id/1]).
-export([source_id/1]).
-export([party_id/1]).
-export([id/1]).
-export([body/1]).
-export([negative_body/1]).
-export([is_negative/1]).
-export([status/1]).
-export([external_id/1]).
-export([domain_revision/1]).
-export([created_at/1]).
-export([metadata/1]).
-export([description/1]).

%% API
-export([create/1]).

-export([is_active/1]).
-export([is_finished/1]).

%% Transfer logic callbacks
-export([process_transfer/1]).

%% Event source

-export([apply_event/2]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1, unwrap/2]).

%% Internal types

-type process_result() :: {action(), [event()]}.
-type source_id() :: ff_source:id().
-type source() :: ff_source:source_state().
-type party_id() :: ff_party:id().
-type wallet_id() :: ff_party:wallet_id().
-type wallet() :: ff_party:wallet().
-type body() :: ff_accounting:body().
-type is_negative() :: boolean().
-type cash() :: ff_cash:cash().
-type cash_range() :: ff_range:range(cash()).
-type action() :: machinery:action() | undefined.
-type p_transfer() :: ff_postings_transfer:transfer().
-type currency_id() :: ff_currency:id().
-type external_id() :: id().
-type failure() :: ff_failure:failure().
-type final_cash_flow() :: ff_cash_flow:final_cash_flow().
-type domain_revision() :: ff_domain_config:revision().
-type terms() :: ff_party:terms().
-type metadata() :: ff_entity_context:md().

-type transfer_params() :: #{
    source_id := source_id(),
    party_id := party_id(),
    wallet_id := wallet_id()
}.

-type activity() ::
    p_transfer_start
    | p_transfer_prepare
    | p_transfer_commit
    | p_transfer_cancel
    | limit_check
    | {fail, fail_type()}
    | finish.

-type fail_type() ::
    limit_check.

%% Accessors

-spec id(deposit_state()) -> id().
id(#{id := V}) ->
    V.

-spec wallet_id(deposit_state()) -> wallet_id().
wallet_id(T) ->
    maps:get(wallet_id, params(T)).

-spec source_id(deposit_state()) -> source_id().
source_id(T) ->
    maps:get(source_id, params(T)).

-spec party_id(deposit_state()) -> party_id().
party_id(T) ->
    maps:get(party_id, params(T)).

-spec body(deposit_state()) -> body().
body(#{body := V}) ->
    V.

-spec negative_body(deposit_state()) -> body().
negative_body(#{body := {Amount, Currency}, is_negative := true}) ->
    {-1 * Amount, Currency};
negative_body(T) ->
    body(T).

-spec is_negative(deposit_state()) -> is_negative().
is_negative(#{is_negative := V}) ->
    V;
is_negative(_T) ->
    false.

-spec status(deposit_state()) -> status() | undefined.
status(Deposit) ->
    maps:get(status, Deposit, undefined).

-spec p_transfer(deposit_state()) -> p_transfer() | undefined.
p_transfer(Deposit) ->
    maps:get(p_transfer, Deposit, undefined).

-spec external_id(deposit_state()) -> external_id() | undefined.
external_id(Deposit) ->
    maps:get(external_id, Deposit, undefined).

-spec domain_revision(deposit_state()) -> domain_revision() | undefined.
domain_revision(T) ->
    maps:get(domain_revision, T, undefined).

-spec created_at(deposit_state()) -> ff_time:timestamp_ms() | undefined.
created_at(T) ->
    maps:get(created_at, T, undefined).

-spec metadata(deposit_state()) -> metadata() | undefined.
metadata(T) ->
    maps:get(metadata, T, undefined).

-spec description(deposit_state()) -> description() | undefined.
description(Deposit) ->
    maps:get(description, Deposit, undefined).

%% API

-spec create(params()) ->
    {ok, [event()]}
    | {error, create_error()}.
create(Params) ->
    do(fun() ->
        #{id := ID, source_id := SourceID, party_id := PartyID, wallet_id := WalletID, body := Body} = Params,
        Machine = unwrap(source, ff_source_machine:get(SourceID)),
        Source = ff_source_machine:source(Machine),
        CreatedAt = ff_time:now(),
        DomainRevision = ff_domain_config:head(),
        Wallet = unwrap(
            wallet,
            ff_party:get_wallet(
                WalletID,
                #domain_PartyConfigRef{id = PartyID},
                DomainRevision
            )
        ),
        {_Amount, Currency} = Body,
        Varset = genlib_map:compact(#{
            currency => ff_dmsl_codec:marshal(currency_ref, Currency),
            cost => ff_dmsl_codec:marshal(cash, Body),
            wallet_id => WalletID
        }),

        Terms = ff_party:get_terms(DomainRevision, Wallet, Varset),

        valid = unwrap(validate_deposit_creation(Terms, Params, Source, Wallet, DomainRevision)),
        TransferParams = #{
            wallet_id => WalletID,
            source_id => SourceID,
            party_id => PartyID
        },
        [
            {created,
                genlib_map:compact(#{
                    version => ?ACTUAL_FORMAT_VERSION,
                    id => ID,
                    body => Body,
                    params => TransferParams,
                    domain_revision => DomainRevision,
                    created_at => CreatedAt,
                    external_id => maps:get(external_id, Params, undefined),
                    metadata => maps:get(metadata, Params, undefined),
                    description => maps:get(description, Params, undefined)
                })},
            {status_changed, pending}
        ]
    end).

-spec process_transfer(deposit_state()) -> process_result().
process_transfer(Deposit) ->
    Activity = deduce_activity(Deposit),
    do_process_transfer(Activity, Deposit).

-spec is_active(deposit_state()) -> boolean().
is_active(#{status := succeeded}) ->
    false;
is_active(#{status := {failed, _}}) ->
    false;
is_active(#{status := pending}) ->
    true.

%% Сущность завершила свою основную задачу по переводу денег. Дальше её состояние будет меняться только
%% изменением дочерних сущностей, например запуском adjustment.
-spec is_finished(deposit_state()) -> boolean().
is_finished(#{status := succeeded}) ->
    true;
is_finished(#{status := {failed, _}}) ->
    true;
is_finished(#{status := pending}) ->
    false.

%% Events utils

-spec apply_event(event(), deposit_state() | undefined) -> deposit_state().
apply_event(Ev, T0) ->
    apply_event_(Ev, T0).

-spec apply_event_(event(), deposit_state() | undefined) -> deposit_state().
apply_event_({created, T}, undefined) ->
    apply_negative_body(T);
apply_event_({status_changed, S}, T) ->
    maps:put(status, S, T);
apply_event_({limit_check, Details}, T) ->
    add_limit_check(Details, T);
apply_event_({p_transfer, Ev}, T) ->
    T#{p_transfer => ff_postings_transfer:apply_event(Ev, p_transfer(T))}.

apply_negative_body(#{body := {Amount, Currency}} = T) when Amount < 0 ->
    T#{body => {-1 * Amount, Currency}, is_negative => true};
apply_negative_body(T) ->
    T.

%% Internals

-spec params(deposit_state()) -> transfer_params().
params(#{params := V}) ->
    V.

-spec deduce_activity(deposit_state()) -> activity().
deduce_activity(Deposit) ->
    Params = #{
        p_transfer => p_transfer_status(Deposit),
        status => status(Deposit),
        limit_check => limit_check_status(Deposit)
    },
    do_deduce_activity(Params).

do_deduce_activity(#{status := pending, p_transfer := undefined}) ->
    p_transfer_start;
do_deduce_activity(#{status := pending, p_transfer := created}) ->
    p_transfer_prepare;
do_deduce_activity(#{status := pending, p_transfer := prepared, limit_check := unknown}) ->
    limit_check;
do_deduce_activity(#{status := pending, p_transfer := prepared, limit_check := ok}) ->
    p_transfer_commit;
do_deduce_activity(#{status := pending, p_transfer := committed, limit_check := ok}) ->
    finish;
do_deduce_activity(#{status := pending, p_transfer := prepared, limit_check := {failed, _}}) ->
    p_transfer_cancel;
do_deduce_activity(#{status := pending, p_transfer := cancelled, limit_check := {failed, _}}) ->
    {fail, limit_check}.

-spec do_process_transfer(activity(), deposit_state()) -> process_result().
do_process_transfer(p_transfer_start, Deposit) ->
    create_p_transfer(Deposit);
do_process_transfer(p_transfer_prepare, Deposit) ->
    {ok, Events} = ff_pipeline:with(p_transfer, Deposit, fun ff_postings_transfer:prepare/1),
    {continue, Events};
do_process_transfer(p_transfer_commit, Deposit) ->
    {ok, Events} = ff_pipeline:with(p_transfer, Deposit, fun ff_postings_transfer:commit/1),
    {ok, Wallet} = ff_party:get_wallet(
        wallet_id(Deposit),
        #domain_PartyConfigRef{id = party_id(Deposit)},
        domain_revision(Deposit)
    ),
    ok = ff_party:wallet_log_balance(wallet_id(Deposit), Wallet),
    {continue, Events};
do_process_transfer(p_transfer_cancel, Deposit) ->
    {ok, Events} = ff_pipeline:with(p_transfer, Deposit, fun ff_postings_transfer:cancel/1),
    {continue, Events};
do_process_transfer(limit_check, Deposit) ->
    process_limit_check(Deposit);
do_process_transfer({fail, Reason}, Deposit) ->
    process_transfer_fail(Reason, Deposit);
do_process_transfer(finish, Deposit) ->
    process_transfer_finish(Deposit).

-spec create_p_transfer(deposit_state()) -> process_result().
create_p_transfer(Deposit) ->
    FinalCashFlow = make_final_cash_flow(Deposit),
    PTransferID = construct_p_transfer_id(id(Deposit)),
    {ok, PostingsTransferEvents} = ff_postings_transfer:create(PTransferID, FinalCashFlow),
    {continue, [{p_transfer, Ev} || Ev <- PostingsTransferEvents]}.

-spec process_limit_check(deposit_state()) -> process_result().
process_limit_check(Deposit) ->
    Body = body(Deposit),
    WalletID = wallet_id(Deposit),
    DomainRevision = domain_revision(Deposit),
    {ok, Wallet} = ff_party:get_wallet(
        WalletID,
        #domain_PartyConfigRef{id = party_id(Deposit)},
        DomainRevision
    ),
    {_Amount, Currency} = Body,
    Varset = genlib_map:compact(#{
        currency => ff_dmsl_codec:marshal(currency_ref, Currency),
        cost => ff_dmsl_codec:marshal(cash, Body),
        wallet_id => WalletID
    }),
    Terms = ff_party:get_terms(DomainRevision, Wallet, Varset),
    Events =
        case validate_wallet_limits(Terms, Wallet) of
            {ok, valid} ->
                [{limit_check, {wallet_receiver, ok}}];
            {error, {terms_violation, {wallet_limit, {cash_range, {Cash, Range}}}}} ->
                Details = #{
                    expected_range => Range,
                    balance => Cash
                },
                [{limit_check, {wallet_receiver, {failed, Details}}}]
        end,
    {continue, Events}.

-spec process_transfer_finish(deposit_state()) -> process_result().
process_transfer_finish(_Deposit) ->
    {undefined, [{status_changed, succeeded}]}.

-spec process_transfer_fail(fail_type(), deposit_state()) -> process_result().
process_transfer_fail(limit_check, Deposit) ->
    Failure = build_failure(limit_check, Deposit),
    {undefined, [{status_changed, {failed, Failure}}]}.

-spec make_final_cash_flow(deposit_state()) -> final_cash_flow().
make_final_cash_flow(Deposit) ->
    WalletID = wallet_id(Deposit),
    SourceID = source_id(Deposit),
    Body = body(Deposit),
    DomainRevision = domain_revision(Deposit),
    {ok, Wallet} = ff_party:get_wallet(
        WalletID,
        #domain_PartyConfigRef{id = party_id(Deposit)},
        DomainRevision
    ),
    WalletRealm = ff_party:get_wallet_realm(Wallet, DomainRevision),
    {AccountID, Currency} = ff_party:get_wallet_account(Wallet),
    WalletAccount = ff_account:build(party_id(Deposit), WalletRealm, AccountID, Currency),
    {ok, SourceMachine} = ff_source_machine:get(SourceID),
    Source = ff_source_machine:source(SourceMachine),
    SourceAccount = ff_source:account(Source),
    Constants = #{
        operation_amount => Body
    },
    Accounts =
        case is_negative(Deposit) of
            true ->
                #{
                    {wallet, sender_source} => WalletAccount,
                    {wallet, receiver_settlement} => SourceAccount
                };
            false ->
                #{
                    {wallet, sender_source} => SourceAccount,
                    {wallet, receiver_settlement} => WalletAccount
                }
        end,
    CashFlowPlan = #{
        postings => [
            #{
                sender => {wallet, sender_source},
                receiver => {wallet, receiver_settlement},
                volume => {share, {{1, 1}, operation_amount, default}}
            }
        ]
    },
    {ok, FinalCashFlow} = ff_cash_flow:finalize(CashFlowPlan, Accounts, Constants),
    FinalCashFlow.

%% Internal getters and setters

-spec p_transfer_status(deposit_state()) -> ff_postings_transfer:status() | undefined.
p_transfer_status(Deposit) ->
    case p_transfer(Deposit) of
        undefined ->
            undefined;
        Transfer ->
            ff_postings_transfer:status(Transfer)
    end.

%% Deposit validators

-spec validate_deposit_creation(terms(), params(), source(), wallet(), domain_revision()) ->
    {ok, valid}
    | {error, create_error()}.
validate_deposit_creation(Terms, Params, Source, Wallet, DomainRevision) ->
    #{body := Body} = Params,
    do(fun() ->
        valid = unwrap(ff_party:validate_deposit_creation(Terms, Body)),
        valid = unwrap(validate_deposit_currency(Body, Source, Wallet, DomainRevision))
    end).

-spec validate_deposit_currency(body(), source(), wallet(), domain_revision()) ->
    {ok, valid}
    | {error, {inconsistent_currency, {currency_id(), currency_id(), currency_id()}}}.
validate_deposit_currency(Body, Source, Wallet, DomainRevision) ->
    SourceCurrencyID = ff_account:currency(ff_source:account(Source)),
    WalletCurrencyID = ff_account:currency(ff_party:build_account_for_wallet(Wallet, DomainRevision)),
    case Body of
        {_Amount, DepositCurencyID} when
            DepositCurencyID =:= SourceCurrencyID andalso
                DepositCurencyID =:= WalletCurrencyID
        ->
            {ok, valid};
        {_Amount, DepositCurencyID} ->
            {error, {inconsistent_currency, {DepositCurencyID, SourceCurrencyID, WalletCurrencyID}}}
    end.

%% Limit helpers

-spec limit_checks(deposit_state()) -> [limit_check_details()].
limit_checks(Deposit) ->
    maps:get(limit_checks, Deposit, []).

-spec add_limit_check(limit_check_details(), deposit_state()) -> deposit_state().
add_limit_check(Check, Deposit) ->
    Checks = limit_checks(Deposit),
    Deposit#{limit_checks => [Check | Checks]}.

-spec limit_check_status(deposit_state()) -> ok | {failed, limit_check_details()} | unknown.
limit_check_status(#{limit_checks := Checks}) ->
    case lists:dropwhile(fun is_limit_check_ok/1, Checks) of
        [] ->
            ok;
        [H | _Tail] ->
            {failed, H}
    end;
limit_check_status(Deposit) when not is_map_key(limit_checks, Deposit) ->
    unknown.

-spec is_limit_check_ok(limit_check_details()) -> boolean().
is_limit_check_ok({wallet_receiver, ok}) ->
    true;
is_limit_check_ok({wallet_receiver, {failed, _Details}}) ->
    false.

-spec validate_wallet_limits(terms(), wallet()) ->
    {ok, valid}
    | {error, {terms_violation, {wallet_limit, {cash_range, {cash(), cash_range()}}}}}.
validate_wallet_limits(Terms, Wallet) ->
    case ff_party:validate_wallet_limits(Terms, Wallet) of
        {ok, valid} = Result ->
            Result;
        {error, {terms_violation, {cash_range, {Cash, CashRange}}}} ->
            {error, {terms_violation, {wallet_limit, {cash_range, {Cash, CashRange}}}}};
        {error, {invalid_terms, _Details} = Reason} ->
            erlang:error(Reason)
    end.

%% Helpers

-spec construct_p_transfer_id(id()) -> id().
construct_p_transfer_id(ID) ->
    <<"ff/deposit/", ID/binary>>.

-spec build_failure(fail_type(), deposit_state()) -> failure().
build_failure(limit_check, Deposit) ->
    {failed, Details} = limit_check_status(Deposit),
    #{
        code => <<"account_limit_exceeded">>,
        reason => genlib:format(Details),
        sub => #{
            code => <<"amount">>
        }
    }.
