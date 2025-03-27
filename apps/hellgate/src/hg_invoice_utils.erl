%%% Invoice utils
%%%

-module(hg_invoice_utils).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-export([validate_cost/2]).
-export([validate_currency/2]).
-export([validate_cash_range/1]).
-export([assert_party_operable/1]).
-export([assert_shop_exists/1]).
-export([assert_shop_operable/1]).
-export([assert_cost_payable/2]).
-export([compute_shop_terms/3]).
-export([get_shop_currency/1]).
-export([get_shop_account/1]).
-export([get_cart_amount/1]).
-export([check_deadline/1]).
-export([assert_party_unblocked/1]).
-export([assert_shop_unblocked/1]).

-type account_id() :: dmsl_domain_thrift:'AccountID'().
-type amount() :: dmsl_domain_thrift:'Amount'().
-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type cart() :: dmsl_domain_thrift:'InvoiceCart'().
-type cash_range() :: dmsl_domain_thrift:'CashRange'().
-type party() :: dmsl_domain_thrift:'PartyConfig'().
-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type term_set() :: dmsl_domain_thrift:'TermSet'().
-type payment_service_terms() :: dmsl_domain_thrift:'PaymentsServiceTerms'().
-type varset() :: dmsl_payproc_thrift:'Varset'().
-type revision() :: dmsl_domain_thrift:'DataRevision'().

-spec validate_cost(cash(), shop()) -> ok.
validate_cost(#domain_Cash{currency = Currency, amount = Amount}, Shop) ->
    _ = validate_amount(Amount),
    _ = validate_currency(Currency, Shop),
    ok.

-spec validate_amount(amount()) -> ok.
validate_amount(Amount) when Amount > 0 ->
    ok;
validate_amount(_) ->
    throw(#base_InvalidRequest{errors = [<<"Invalid amount">>]}).

-spec validate_currency(currency(), shop()) -> ok.
validate_currency(Currency, Shop = #domain_ShopConfig{}) ->
    validate_currency_(Currency, get_shop_currency(Shop)).

-spec validate_cash_range(cash_range()) -> ok.
validate_cash_range(#domain_CashRange{
    lower = {LType, #domain_Cash{amount = LAmount, currency = Currency}},
    upper = {UType, #domain_Cash{amount = UAmount, currency = Currency}}
}) when
    LType =/= UType andalso UAmount >= LAmount orelse
        LType =:= UType andalso UAmount > LAmount orelse
        LType =:= UType andalso UType =:= inclusive andalso UAmount == LAmount
->
    ok;
validate_cash_range(_) ->
    throw(#base_InvalidRequest{errors = [<<"Invalid cost range">>]}).

-spec assert_party_operable(party()) -> party().
assert_party_operable(V) ->
    _ = assert_party_unblocked(V),
    _ = assert_party_active(V),
    V.

-spec assert_shop_operable(shop()) -> shop().
assert_shop_operable(V) ->
    _ = assert_shop_unblocked(V),
    _ = assert_shop_active(V),
    V.

-spec assert_shop_exists(shop() | undefined) -> shop().
assert_shop_exists(#domain_ShopConfig{} = V) ->
    V;
assert_shop_exists(undefined) ->
    throw(#payproc_ShopNotFound{}).

-spec assert_cost_payable(cash(), payment_service_terms()) -> cash().
assert_cost_payable(Cost, #domain_PaymentsServiceTerms{cash_limit = CashLimit}) ->
    case any_limit_matches(Cost, CashLimit) of
        true ->
            Cost;
        false ->
            throw(#payproc_InvoiceTermsViolated{
                reason = {invoice_unpayable, #payproc_InvoiceUnpayable{}}
            })
    end.

any_limit_matches(Cash, {value, CashRange}) ->
    hg_cash_range:is_inside(Cash, CashRange) =:= within;
any_limit_matches(Cash, {decisions, Decisions}) ->
    lists:any(
        fun(#domain_CashLimitDecision{then_ = Value}) ->
            any_limit_matches(Cash, Value)
        end,
        Decisions
    ).

-spec compute_shop_terms(revision(), shop(), varset() | hg_varset:varset()) -> term_set().
compute_shop_terms(Revision, #domain_ShopConfig{terms = Ref}, #payproc_Varset{} = Varset) ->
    Args = {Ref, Revision, Varset},
    Opts = hg_woody_wrapper:get_service_options(party_config),
    case hg_woody_wrapper:call(party_config, 'ComputeTerms', Args, Opts) of
        {ok, Terms} ->
            Terms;
        {exception, Exception} ->
            error(Exception)
    end;
compute_shop_terms(Revision, Shop, Varset0) ->
    compute_shop_terms(Revision, Shop, hg_varset:prepare_varset(Varset0)).

validate_currency_(Currency, Currency) ->
    ok;
validate_currency_(_, _) ->
    throw(#base_InvalidRequest{errors = [<<"Invalid currency">>]}).

-spec get_shop_currency(shop()) -> currency().
get_shop_currency(#domain_ShopConfig{currency_configs = Configs}) when is_map(Configs) ->
    %% TODO: fix it when add multi currency support
    [Currency | _] = maps:keys(Configs),
    Currency.

-spec get_shop_account(shop()) -> {account_id(), account_id()}.
get_shop_account(#domain_ShopConfig{currency_configs = Configs}) when is_map(Configs) ->
    %% TODO: fix it when add multi currency support
    [{_Currency, #domain_ShopCurrencyConfig{settlement = SettlementID, guarantee = GuaranteeID}} | _] = maps:to_list(
        Configs
    ),
    {SettlementID, GuaranteeID}.

-spec assert_party_unblocked(party()) -> true | no_return().
assert_party_unblocked(#domain_PartyConfig{blocking = V = {Status, _}}) ->
    Status == unblocked orelse throw(#payproc_InvalidPartyStatus{status = {blocking, V}}).

-spec assert_party_active(party()) -> true | no_return().
assert_party_active(#domain_PartyConfig{suspension = V = {Status, _}}) ->
    Status == active orelse throw(#payproc_InvalidPartyStatus{status = {suspension, V}}).

-spec assert_shop_unblocked(shop()) -> true | no_return().
assert_shop_unblocked(#domain_ShopConfig{blocking = V = {Status, _}}) ->
    Status == unblocked orelse throw(#payproc_InvalidShopStatus{status = {blocking, V}}).

-spec assert_shop_active(shop()) -> true | no_return().
assert_shop_active(#domain_ShopConfig{suspension = V = {Status, _}}) ->
    Status == active orelse throw(#payproc_InvalidShopStatus{status = {suspension, V}}).

-spec get_cart_amount(cart()) -> cash().
get_cart_amount(#domain_InvoiceCart{lines = [FirstLine | Cart]}) ->
    lists:foldl(
        fun(Line, CashAcc) ->
            hg_cash:add(get_line_amount(Line), CashAcc)
        end,
        get_line_amount(FirstLine),
        Cart
    ).

get_line_amount(#domain_InvoiceLine{
    quantity = Quantity,
    price = #domain_Cash{amount = Amount, currency = Currency}
}) ->
    #domain_Cash{amount = Amount * Quantity, currency = Currency}.

-spec check_deadline(Deadline :: binary() | undefined) -> ok | {error, deadline_reached}.
check_deadline(undefined) ->
    ok;
check_deadline(Deadline) ->
    case hg_datetime:compare(Deadline, hg_datetime:format_now()) of
        later ->
            ok;
        _ ->
            {error, deadline_reached}
    end.
