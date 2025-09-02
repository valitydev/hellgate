-module(hg_party).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

%% Party support functions

-export([get_party/1]).
-export([get_party_revision/0]).
-export([checkout/2]).
-export([get_shop/2]).
-export([get_shop/3]).
-export([get_shops_by_party_config_ref/2]).

-export_type([party/0]).
-export_type([party_config_ref/0]).

%%

-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type party_config_ref() :: dmsl_domain_thrift:'PartyConfigRef'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type shop_config_ref() :: dmsl_domain_thrift:'ShopConfigRef'().

%% Interface

-spec get_party(party_config_ref()) -> {party_config_ref(), party()} | hg_domain:get_error().
get_party(PartyConfigRef) ->
    checkout(PartyConfigRef, get_party_revision()).

-spec get_party_revision() -> hg_domain:revision() | no_return().
get_party_revision() ->
    hg_domain:head().

-spec checkout(party_config_ref(), hg_domain:revision()) ->
    {party_config_ref(), party()} | hg_domain:get_error().
checkout(PartyConfigRef, Revision) ->
    case hg_domain:get(Revision, {party_config, PartyConfigRef}) of
        {object_not_found, _} = Error ->
            Error;
        PartyConfig ->
            {PartyConfigRef, PartyConfig}
    end.

-spec get_shop(shop_config_ref(), party_config_ref()) -> {shop_config_ref(), shop()} | undefined.
get_shop(ShopConfigRef, PartyConfigRef) ->
    get_shop(ShopConfigRef, PartyConfigRef, get_party_revision()).

-spec get_shop(shop_config_ref(), party_config_ref(), hg_domain:revision()) ->
    {shop_config_ref(), shop()} | undefined.
get_shop(ShopConfigRef, PartyConfigRef, Revision) ->
    try dmt_client:checkout_object(Revision, {shop_config, ShopConfigRef}) of
        #domain_conf_v2_VersionedObject{
            object =
                {shop_config, #domain_ShopConfigObject{
                    data = #domain_ShopConfig{party_ref = PartyConfigRef} = ShopConfig
                }}
        } ->
            {ShopConfigRef, ShopConfig};
        ShopConfig ->
            _ = logger:warning("Shop config ~p not found for party ~p", [ShopConfig, PartyConfigRef]),
            undefined
    catch
        throw:#domain_conf_v2_ObjectNotFound{} ->
            undefined
    end.

-spec get_shops_by_party_config_ref(party_config_ref(), hg_domain:revision()) -> [shop()].
get_shops_by_party_config_ref(PartyConfigRef, Revision) ->
    try dmt_client:checkout_object_with_references(Revision, {party_config, PartyConfigRef}) of
        #domain_conf_v2_VersionedObjectWithReferences{
            referenced_by = ReferencedBy
        } ->
            lists:foldl(
                fun(VersionedObject, Acc) ->
                    case VersionedObject of
                        #domain_conf_v2_VersionedObject{
                            object = {shop_config, _} = Object
                        } ->
                            [Object | Acc];
                        _ ->
                            Acc
                    end
                end,
                [],
                ReferencedBy
            )
    catch
        % If the object is not found, return an empty list
        error:#domain_conf_v2_ObjectNotFound{} ->
            []
    end.
