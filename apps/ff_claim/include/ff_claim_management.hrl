-ifndef(__ff_claim_management_hrl__).
-define(__ff_claim_management_hrl__, included).

-define(cm_modification_unit(ModID, Timestamp, Mod, UserInfo), #claimmgmt_ModificationUnit{
    modification_id = ModID,
    created_at = Timestamp,
    modification = Mod,
    user_info = UserInfo
}).

-define(cm_wallet_modification(ModID, Timestamp, Mod, UserInfo),
    ?cm_modification_unit(ModID, Timestamp, {wallet_modification, Mod}, UserInfo)
).

-define(cm_identity_modification(ModID, Timestamp, Mod, UserInfo),
    ?cm_modification_unit(ModID, Timestamp, {identity_modification, Mod}, UserInfo)
).

%%% Identity

-define(cm_identity_creation(PartyID, IdentityID, Provider, Params),
    {identity_modification, #claimmgmt_IdentityModificationUnit{
        id = IdentityID,
        modification =
            {creation,
                Params = #claimmgmt_IdentityParams{
                    party_id = PartyID,
                    provider = Provider
                }}
    }}
).

%%% Wallet

-define(cm_wallet_creation(IdentityID, WalletID, Currency, Params),
    {wallet_modification, #claimmgmt_NewWalletModificationUnit{
        id = WalletID,
        modification =
            {creation,
                Params = #claimmgmt_NewWalletParams{
                    identity_id = IdentityID,
                    currency = Currency
                }}
    }}
).

%%% Error

-define(cm_invalid_changeset(Reason, InvalidChangeset), #claimmgmt_InvalidChangeset{
    reason = Reason,
    invalid_changeset = InvalidChangeset
}).

-define(cm_invalid_identity_already_exists(ID),
    {
        invalid_identity_changeset,
        #claimmgmt_InvalidIdentityChangesetReason{
            id = ID,
            reason = {already_exists, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_identity_provider_not_found(ID),
    {
        invalid_identity_changeset,
        #claimmgmt_InvalidIdentityChangesetReason{
            id = ID,
            reason = {provider_not_found, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_identity_party_not_found(ID),
    {
        invalid_identity_changeset,
        #claimmgmt_InvalidIdentityChangesetReason{
            id = ID,
            reason = {party_not_found, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_identity_party_inaccessible(ID),
    {
        invalid_identity_changeset,
        #claimmgmt_InvalidIdentityChangesetReason{
            id = ID,
            reason = {party_inaccessible, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_wallet_already_exists(ID),
    {
        invalid_wallet_changeset,
        #claimmgmt_InvalidNewWalletChangesetReason{
            id = ID,
            reason = {already_exists, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_wallet_identity_not_found(ID),
    {
        invalid_wallet_changeset,
        #claimmgmt_InvalidNewWalletChangesetReason{
            id = ID,
            reason = {identity_not_found, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_wallet_currency_not_found(ID),
    {
        invalid_wallet_changeset,
        #claimmgmt_InvalidNewWalletChangesetReason{
            id = ID,
            reason = {currency_not_found, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_wallet_currency_not_allowed(ID),
    {
        invalid_wallet_changeset,
        #claimmgmt_InvalidNewWalletChangesetReason{
            id = ID,
            reason = {currency_not_allowed, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-define(cm_invalid_wallet_party_inaccessible(ID),
    {
        invalid_wallet_changeset,
        #claimmgmt_InvalidNewWalletChangesetReason{
            id = ID,
            reason = {party_inaccessible, #claimmgmt_InvalidClaimConcreteReason{}}
        }
    }
).

-endif.
