-module(hg_party).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%% Party support functions

-export([get_party/1]).
-export([get_party_revision/0]).
-export([checkout/2]).
-export([get_shop/2]).
-export([get_shop/3]).

-export_type([party/0]).
-export_type([party_status/0]).

%%

-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type party_id() :: dmsl_domain_thrift:'PartyID'().
-type party_status() :: dmsl_domain_thrift:'PartyStatus'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type shop_id() :: dmsl_domain_thrift:'ShopID'().

%% Interface

-spec get_party(party_id()) -> party() | hg_domain:get_error().
get_party(PartyID) ->
    checkout(PartyID, get_party_revision()).

-spec get_party_revision() -> hg_domain:revision() | no_return().
get_party_revision() ->
    hg_domain:head().

-spec checkout(party_id(), hg_domain:revision()) -> party() | hg_domain:get_error().
checkout(PartyID, Revision) ->
    case hg_domain:get(Revision, {party_config, #domain_PartyConfigRef{id = PartyID}}) of
        {object_not_found, _Ref} = Error ->
            Error;
        Party ->
            Party
    end.

-spec get_shop(shop_id(), party()) -> shop() | undefined.
get_shop(ID, Party) ->
    get_shop(ID, Party, get_party_revision()).

-spec get_shop(shop_id(), party(), hg_domain:revision()) -> shop() | undefined.
get_shop(ID, #domain_PartyConfig{shops = Shops}, Revision) ->
    Ref = #domain_ShopConfigRef{id = ID},
    case lists:member(Ref, Shops) of
        true ->
            hg_domain:get(Revision, {shop_config, Ref});
        false ->
            undefined
    end.
