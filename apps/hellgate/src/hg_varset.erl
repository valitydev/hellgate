-module(hg_varset).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-export([prepare_varset/1]).

-export_type([varset/0]).

-type varset() :: #{
    category => dmsl_domain_thrift:'CategoryRef'(),
    currency => dmsl_domain_thrift:'CurrencyRef'(),
    cost => dmsl_domain_thrift:'Cash'(),
    payment_tool => dmsl_domain_thrift:'PaymentTool'(),
    party_id => dmsl_domain_thrift:'PartyID'(),
    shop_id => dmsl_domain_thrift:'ShopID'(),
    risk_score => hg_inspector:risk_score(),
    flow => instant | {hold, dmsl_domain_thrift:'HoldLifetime'()},
    wallet_id => dmsl_domain_thrift:'WalletID'(),
    identification_level => dmsl_domain_thrift:'ContractorIdentificationLevel'()
}.

-spec prepare_varset(varset()) -> dmsl_payproc_thrift:'Varset'().
prepare_varset(Varset) ->
    #payproc_Varset{
        category = genlib_map:get(category, Varset),
        currency = genlib_map:get(currency, Varset),
        amount = genlib_map:get(cost, Varset),
        wallet_id = genlib_map:get(wallet_id, Varset),
        payment_tool = genlib_map:get(payment_tool, Varset),
        identification_level = genlib_map:get(identification_level, Varset),
        party_id = genlib_map:get(party_id, Varset),
        shop_id = genlib_map:get(shop_id, Varset)
    }.
