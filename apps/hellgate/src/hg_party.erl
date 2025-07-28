-module(hg_party).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%% Party support functions

-export([get_party/1]).
-export([get_party_revision/0]).
-export([checkout/2]).
-export([get_shop/2]).
-export([get_shop/3]).

-export_type([party/0]).
-export_type([party_id/0]).

%%

-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type party_id() :: dmsl_domain_thrift:'PartyID'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type shop_id() :: dmsl_domain_thrift:'ShopID'().

%% Interface

-spec get_party(party_id()) -> {party_id(), party()} | hg_domain:get_error().
get_party(PartyID) ->
    checkout(PartyID, get_party_revision()).

-spec get_party_revision() -> hg_domain:revision() | no_return().
get_party_revision() ->
    hg_domain:head().

-spec checkout(party_id(), hg_domain:revision()) -> {party_id(), party()} | hg_domain:get_error().
checkout(PartyID, Revision) ->
    Ref = {party_config, #domain_PartyConfigRef{id = PartyID}},
    case hg_domain:get(Revision, Ref) of
        {object_not_found, _} = Error ->
            Error;
        PartyConfig ->
            {PartyID, PartyConfig}
    end.

-spec get_shop(shop_id(), party()) -> {shop_id(), shop()} | undefined.
get_shop(ID, Party) ->
    get_shop(ID, Party, get_party_revision()).

-spec get_shop(shop_id(), party(), hg_domain:revision()) -> {shop_id(), shop()} | undefined.
get_shop(ID, #domain_PartyConfig{shops = Shops}, Revision) ->
    Ref = #domain_ShopConfigRef{id = ID},
    case lists:member(Ref, Shops) of
        true ->
            case hg_domain:get(Revision, {shop_config, Ref}) of
                {object_not_found, _} = Error ->
                    Error;
                ShopConfig ->
                    {ID, ShopConfig}
            end;
        false ->
            undefined
    end.
