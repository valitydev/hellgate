-module(ff_claim_committer).

-include_lib("damsel/include/dmsl_claimmgmt_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-include("ff_claim_management.hrl").

-export([filter_ff_modifications/1]).
-export([assert_modifications_applicable/1]).
-export([apply_modifications/1]).

-type changeset() :: dmsl_claimmgmt_thrift:'ClaimChangeset'().
-type modification() :: dmsl_claimmgmt_thrift:'PartyModification'().
-type modifications() :: [modification()].

-export_type([modification/0]).
-export_type([modifications/0]).

-spec filter_ff_modifications(changeset()) -> modifications().
filter_ff_modifications(Changeset) ->
    lists:filtermap(
        fun
            (?cm_identity_modification(_, _, Change, _)) ->
                {true, {identity_modification, Change}};
            (?cm_wallet_modification(_, _, Change, _)) ->
                {true, {wallet_modification, Change}};
            (_) ->
                false
        end,
        Changeset
    ).

%% Used same checks as in identity/wallet create function
-spec assert_modifications_applicable(modifications()) -> ok | no_return().
assert_modifications_applicable([FFChange | Others]) ->
    ok =
        case FFChange of
            ?cm_identity_creation(PartyID, IdentityID, Provider, _Params) ->
                case ff_identity_machine:get(IdentityID) of
                    {ok, _Machine} ->
                        raise_invalid_changeset(?cm_invalid_identity_already_exists(IdentityID), [FFChange]);
                    {error, notfound} ->
                        assert_identity_creation_applicable(PartyID, IdentityID, Provider, FFChange)
                end;
            ?cm_wallet_creation(IdentityID, WalletID, Currency, _Params) ->
                case ff_wallet_machine:get(WalletID) of
                    {ok, _Machine} ->
                        raise_invalid_changeset(?cm_invalid_wallet_already_exists(WalletID), [FFChange]);
                    {error, notfound} ->
                        assert_wallet_creation_modification_applicable(IdentityID, WalletID, Currency, FFChange)
                end
        end,
    assert_modifications_applicable(Others);
assert_modifications_applicable([]) ->
    ok.

-spec apply_modifications(modifications()) -> ok | no_return().
apply_modifications([FFChange | Others]) ->
    ok =
        case FFChange of
            ?cm_identity_creation(_PartyID, IdentityID, _Provider, Params) ->
                #claimmgmt_IdentityParams{metadata = Metadata} = Params,
                apply_identity_creation(IdentityID, Metadata, Params, FFChange);
            ?cm_wallet_creation(_IdentityID, WalletID, _Currency, Params) ->
                #claimmgmt_NewWalletParams{metadata = Metadata} = Params,
                apply_wallet_creation(WalletID, Metadata, Params, FFChange)
        end,
    apply_modifications(Others);
apply_modifications([]) ->
    ok.

%%% Internal functions
assert_identity_creation_applicable(PartyID, IdentityID, Provider, Change) ->
    case ff_identity:check_identity_creation(#{party => PartyID, provider => Provider}) of
        {ok, _} ->
            ok;
        {error, {provider, notfound}} ->
            raise_invalid_changeset(?cm_invalid_identity_provider_not_found(IdentityID), [Change]);
        {error, {party, notfound}} ->
            throw(#claimmgmt_PartyNotFound{});
        {error, {party, {inaccessible, _}}} ->
            raise_invalid_changeset(?cm_invalid_identity_party_inaccessible(IdentityID), [Change])
    end.

apply_identity_creation(IdentityID, Metadata, ChangeParams, Change) ->
    Params = #{party := PartyID} = unmarshal_identity_params(IdentityID, ChangeParams),
    case ff_identity_machine:create(Params, create_context(PartyID, Metadata)) of
        ok ->
            ok;
        {error, {provider, notfound}} ->
            raise_invalid_changeset(?cm_invalid_identity_provider_not_found(IdentityID), [Change]);
        {error, {party, notfound}} ->
            throw(#claimmgmt_PartyNotFound{});
        {error, {party, {inaccessible, _}}} ->
            raise_invalid_changeset(?cm_invalid_identity_party_inaccessible(IdentityID), [Change]);
        {error, exists} ->
            raise_invalid_changeset(?cm_invalid_identity_already_exists(IdentityID), [Change]);
        {error, Error} ->
            woody_error:raise(system, {internal, result_unexpected, woody_error:format_details(Error)})
    end.

assert_wallet_creation_modification_applicable(IdentityID, WalletID, DomainCurrency, Change) ->
    #domain_CurrencyRef{symbolic_code = CurrencyID} = DomainCurrency,
    case ff_wallet:check_creation(#{identity => IdentityID, currency => CurrencyID}) of
        {ok, {Identity, Currency}} ->
            case ff_account:check_account_creation(WalletID, Identity, Currency) of
                {ok, valid} ->
                    ok;
                %% not_allowed_currency
                {error, {terms, _}} ->
                    raise_invalid_changeset(?cm_invalid_wallet_currency_not_allowed(WalletID), [Change]);
                {error, {party, {inaccessible, _}}} ->
                    raise_invalid_changeset(?cm_invalid_wallet_party_inaccessible(WalletID), [Change])
            end;
        {error, {identity, notfound}} ->
            raise_invalid_changeset(?cm_invalid_wallet_identity_not_found(WalletID), [Change]);
        {error, {currency, notfound}} ->
            raise_invalid_changeset(?cm_invalid_wallet_currency_not_found(WalletID), [Change])
    end.

apply_wallet_creation(WalletID, Metadata, ChangeParams, Change) ->
    Params = #{identity := IdentityID} = unmarshal_wallet_params(WalletID, ChangeParams),
    PartyID =
        case ff_identity_machine:get(IdentityID) of
            {ok, Machine} ->
                Identity = ff_identity_machine:identity(Machine),
                ff_identity:party(Identity);
            {error, notfound} ->
                raise_invalid_changeset(?cm_invalid_wallet_identity_not_found(WalletID), [Change])
        end,
    case ff_wallet_machine:create(Params, create_context(PartyID, Metadata)) of
        ok ->
            ok;
        {error, {identity, notfound}} ->
            raise_invalid_changeset(?cm_invalid_wallet_identity_not_found(WalletID), [Change]);
        {error, {currency, notfound}} ->
            raise_invalid_changeset(?cm_invalid_wallet_currency_not_found(WalletID), [Change]);
        {error, {party, _Inaccessible}} ->
            raise_invalid_changeset(?cm_invalid_wallet_party_inaccessible(WalletID), [Change]);
        {error, exists} ->
            raise_invalid_changeset(?cm_invalid_wallet_already_exists(WalletID), [Change]);
        {error, Error} ->
            woody_error:raise(system, {internal, result_unexpected, woody_error:format_details(Error)})
    end.

-spec raise_invalid_changeset(dmsl_claimmgmt_thrift:'InvalidChangesetReason'(), modifications()) -> no_return().
raise_invalid_changeset(Reason, Modifications) ->
    throw(?cm_invalid_changeset(Reason, Modifications)).

unmarshal_identity_params(IdentityID, #claimmgmt_IdentityParams{
    name = Name,
    party_id = PartyID,
    provider = ProviderID,
    metadata = Metadata
}) ->
    genlib_map:compact(#{
        id => IdentityID,
        name => Name,
        party => PartyID,
        provider => ProviderID,
        metadata => maybe_unmarshal_metadata(Metadata)
    }).

unmarshal_wallet_params(WalletID, #claimmgmt_NewWalletParams{
    identity_id = IdentityID,
    name = Name,
    currency = DomainCurrency,
    metadata = Metadata
}) ->
    #domain_CurrencyRef{symbolic_code = CurrencyID} = DomainCurrency,
    genlib_map:compact(#{
        id => WalletID,
        name => Name,
        identity => IdentityID,
        currency => CurrencyID,
        metadata => maybe_unmarshal_metadata(Metadata)
    }).

maybe_unmarshal_metadata(undefined) ->
    undefined;
maybe_unmarshal_metadata(Metadata) when is_map(Metadata) ->
    maps:map(fun(_NS, V) -> ff_adapter_withdrawal_codec:unmarshal_msgpack(V) end, Metadata).

create_context(PartyID, Metadata) ->
    #{
        %% same as used in wapi lib
        <<"com.rbkmoney.wapi">> => genlib_map:compact(#{
            <<"owner">> => PartyID,
            <<"metadata">> => maybe_unmarshal_metadata(Metadata)
        })
    }.
