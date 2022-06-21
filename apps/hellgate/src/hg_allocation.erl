-module(hg_allocation).

-include("domain.hrl").
-include("allocation.hrl").

%% API
-export([calculate/4]).
-export([calculate/5]).
-export([sub/2]).
-export([assert_allocatable/5]).

-export_type([allocation_prototype/0]).
-export_type([allocation/0]).

-type allocation_prototype() :: dmsl_domain_thrift:'AllocationPrototype'().
-type allocation() :: dmsl_domain_thrift:'Allocation'().
-type transaction() :: dmsl_domain_thrift:'AllocationTransaction'().
-type transaction_proto() :: dmsl_domain_thrift:'AllocationTransactionPrototype'().
-type allocation_terms() :: dmsl_domain_thrift:'PaymentAllocationServiceTerms'().
-type target() :: dmsl_domain_thrift:'AllocationTransactionTarget'().
-type cash() :: dmsl_domain_thrift:'Cash'().

-type party() :: dmsl_domain_thrift:'Party'().
-type shop() :: dmsl_domain_thrift:'Shop'().
-type party_id() :: dmsl_payproc_thrift:'PartyID'().
-type shop_id() :: dmsl_payproc_thrift:'ShopID'().
-type target_map() :: #{
    party_id => party_id(),
    shop_id => shop_id()
}.

-type sub_errors() ::
    {invalid_transaction, transaction(),
        negative_amount
        | currency_mismatch
        | no_transaction_to_sub}.

-type calculate_errors() ::
    allocation_not_allowed
    | amount_exceeded
    | {invalid_transaction, transaction() | transaction_proto(),
        negative_amount
        | zero_amount
        | target_conflict
        | currency_mismatch
        | payment_institutions_mismatch}.

-type allocatable_errors() ::
    allocation_not_allowed
    | {invalid_transaction, transaction_proto(),
        payment_institutions_mismatch
        | currency_mismatch}.

-spec calculate(allocation_prototype(), party(), shop(), cash(), allocation_terms()) ->
    {ok, allocation()} | {error, calculate_errors()}.
calculate(AllocationPrototype, Party, Shop, Cost, PaymentAllocationServiceTerms) ->
    case assert_allocatable(AllocationPrototype, PaymentAllocationServiceTerms, Party, Shop, Cost) of
        ok ->
            try calculate(AllocationPrototype, Party#domain_Party.id, Shop#domain_Shop.id, Cost) of
                Result ->
                    {ok, Result}
            catch
                throw:Error ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

-spec sub(allocation(), allocation()) -> {ok, allocation()} | {error, sub_errors()}.
sub(Allocation, SubAllocation) ->
    ?allocation(Transactions) = Allocation,
    ?allocation(SubTransactions) = SubAllocation,
    try sub_trxs(Transactions, SubTransactions) of
        ResTransactions ->
            {ok, ?allocation(ResTransactions)}
    catch
        throw:Error ->
            {error, Error}
    end.

-spec assert_allocatable(allocation_prototype(), allocation_terms(), party(), shop(), cash()) ->
    ok | {error, allocatable_errors()}.
assert_allocatable(
    ?allocation_prototype(Trxs),
    #domain_PaymentAllocationServiceTerms{allow = {constant, true}},
    Party,
    Shop,
    Cash
) ->
    Contract = hg_party:get_contract(Shop#domain_Shop.contract_id, Party),
    PaymentInstitutionRef = Contract#domain_Contract.payment_institution,
    try
        lists:foreach(
            fun(?allocation_trx_prototype(?allocation_trx_target_shop(PartyID, ShopID), _Body) = Proto) ->
                TargetParty = hg_party:get_party(PartyID),
                TargetShop = hg_party:get_shop(ShopID, TargetParty),
                TargetContract = hg_party:get_contract(TargetShop#domain_Shop.contract_id, TargetParty),
                _ =
                    case validate_currency(Cash, TargetShop) of
                        ok ->
                            ok;
                        {error, currency_mismatch} ->
                            throw({invalid_transaction, Proto, currency_mismatch})
                    end,
                case TargetContract#domain_Contract.payment_institution of
                    PaymentInstitutionRef ->
                        ok;
                    _ ->
                        throw({invalid_transaction, Proto, payment_institutions_mismatch})
                end
            end,
            Trxs
        )
    catch
        throw:Error ->
            {error, Error}
    end;
assert_allocatable(_Allocation, _PaymentAllocationServiceTerms, _Party, _Shop, _Cash) ->
    {error, allocation_not_allowed}.

validate_currency(#domain_Cash{currency = Currency}, Shop) ->
    ShopCurrency = hg_invoice_utils:get_shop_currency(Shop),
    validate_currency_(Currency, ShopCurrency).

validate_currency_(Currency, Currency) ->
    ok;
validate_currency_(_Currency1, _Currency2) ->
    {error, currency_mismatch}.

-spec construct_target(target_map()) -> target().
construct_target(#{party_id := PartyID, shop_id := ShopID}) ->
    ?allocation_trx_target_shop(PartyID, ShopID).

-spec calculate(allocation_prototype(), party_id(), shop_id(), cash()) -> allocation().
calculate(AllocationPrototype, PartyID, ShopID, Cost) ->
    FeeTarget = construct_target(#{
        party_id => PartyID,
        shop_id => ShopID
    }),
    calculate(AllocationPrototype, FeeTarget, Cost).

-spec calculate(allocation_prototype(), target(), cash()) -> allocation().
calculate(?allocation_prototype(Transactions), FeeTarget, Cost) ->
    ?allocation(calculate_trxs(Transactions, FeeTarget, Cost)).

sub_trxs(Transactions, SubTransactions) ->
    sub_trxs(Transactions, SubTransactions, []).

sub_trxs(Transactions0, [], Acc0) ->
    Acc1 = Transactions0 ++ Acc0,
    genlib_list:compact(Acc1);
sub_trxs(Transactions0, [ST | SubTransactions], Acc0) ->
    {Transaction, Transactions1} = take_trx(ST, Transactions0),
    ResTransaction = sub_trx(Transaction, ST),
    Acc1 = maybe_push_trx(ResTransaction, Acc0),
    sub_trxs(Transactions1, SubTransactions, Acc1).

take_trx(Transaction0, Transactions) ->
    ?allocation_trx(_ID, Target, _Amount) = Transaction0,
    case lists:keytake(Target, #domain_AllocationTransaction.target, Transactions) of
        {value, Transaction1, RemainingTransactions} ->
            {Transaction1, RemainingTransactions};
        false ->
            throw({no_transaction_to_sub, Transaction0})
    end.

sub_trx(Transaction, SubTransaction) ->
    ?allocation_trx(ID, Target, Amount, Details, Body) = Transaction,
    ?allocation_trx(_ID, Target, SubAmount, _SubDetails, _SubBody) = SubTransaction,
    ResAmount = sub_amount(Amount, SubAmount, SubTransaction),
    ResTransaction = construct_trx(
        ID,
        Target,
        ResAmount,
        %% We do not subtract details because we don't need subtracted details for anything
        Details,
        %% We do not subtract body, because there's no good way to do that with different body types
        %% and we don't prohibit subtracting transactions with different body types
        Body
    ),
    ResTransaction.

sub_amount(Amount, SubAmount, T) ->
    try hg_cash:sub(Amount, SubAmount) of
        Res ->
            Res
    catch
        error:badarg ->
            throw({invalid_transaction, T, currency_mismatch})
    end.

calculate_trxs(Transactions, FeeTarget, Cost) ->
    calculate_trxs(Transactions, FeeTarget, Cost, undefined, 1, []).

calculate_trxs([], FeeTarget, CostLeft, FeeAcc, ID, Acc) ->
    AggregatorCost = validate_fee_cost(CostLeft, FeeAcc),
    AggregatorTrx = construct_trx(erlang:integer_to_binary(ID), FeeTarget, AggregatorCost),
    maybe_push_trx(AggregatorTrx, Acc);
calculate_trxs([Head | Transactions], FeeTarget, CostLeft, FeeAcc, ID0, Acc0) ->
    ?allocation_trx_prototype(Target, Body, Details) = Head,
    {TransactionBody, TransactionAmount, FeeAmount} = calculate_trxs_body(Body, FeeTarget, Head),
    Transaction = construct_positive_trx(
        erlang:integer_to_binary(ID0),
        Target,
        TransactionAmount,
        Details,
        TransactionBody
    ),
    Acc1 = push_trx(Transaction, Acc0),
    ID1 = ID0 + 1,
    calculate_trxs(
        Transactions,
        FeeTarget,
        sub_amount(CostLeft, TransactionAmount, Transaction),
        add_fee(FeeAcc, FeeAmount),
        ID1,
        Acc1
    ).

construct_positive_trx(ID, Target, Amount, Details, Body) ->
    case construct_trx(ID, Target, Amount, Details, Body) of
        undefined ->
            throw({invalid_transaction, ?allocation_trx(ID, Target, Amount, Details, Body), zero_amount});
        Trx ->
            Trx
    end.

construct_trx(ID, Target, Amount) ->
    construct_trx(ID, Target, Amount, undefined, undefined).

construct_trx(ID, Target, ?cash(Amount, _SymCode) = A, Details, Body) when Amount < 0 ->
    throw({invalid_transaction, ?allocation_trx(ID, Target, A, Details, Body), negative_amount});
construct_trx(_ID, _Target, ?cash(Amount, _SymCode), _Details, _Body) when Amount == 0 ->
    undefined;
construct_trx(ID, Target, Amount, Details, Body) ->
    ?allocation_trx(ID, Target, Amount, Details, Body).

maybe_push_trx(undefined, Transactions) ->
    Transactions;
maybe_push_trx(Transaction, Transactions) ->
    push_trx(Transaction, Transactions).

push_trx(?allocation_trx(_ID0, Target, _Amount0) = Transaction, Transactions) ->
    case lists:keymember(Target, #domain_AllocationTransaction.target, Transactions) of
        true ->
            throw({invalid_transaction, Transaction, target_conflict});
        false ->
            [Transaction | Transactions]
    end.

validate_fee_cost(?cash(CostLeft, SymCode), ?cash(FeeCost, SymCode)) when CostLeft /= FeeCost ->
    throw(amount_exceeded);
validate_fee_cost(_CostLeft, FeeCost) ->
    FeeCost.

add_fee(undefined, FeeAmount) ->
    FeeAmount;
add_fee(FeeCost, FeeAmount) ->
    hg_cash:add(FeeCost, FeeAmount).

calculate_trxs_body(?allocation_trx_prototype_body_amount(?cash(_, SymCode) = Amount), _FeeTarget, _TP) ->
    {undefined, Amount, ?cash(0, SymCode)};
calculate_trxs_body(?allocation_trx_prototype_body_total(Total, Fee), FeeTarget, TP) ->
    CalculatedFee = calculate_trxs_fee(Fee, Total),
    TransformedBody = #domain_AllocationTransactionBodyTotal{
        fee_target = FeeTarget,
        total = Total,
        fee_amount = CalculatedFee,
        fee = get_fee_share(Fee)
    },
    {TransformedBody, sub_amount(Total, CalculatedFee, TP), CalculatedFee}.

calculate_trxs_fee(?allocation_trx_prototype_fee_fixed(Amount), _Total) ->
    Amount;
calculate_trxs_fee(?allocation_trx_prototype_fee_share(P, Q, RoundingMethod0), ?cash(Total, SymCode)) ->
    RoundingMethod1 = genlib:define(RoundingMethod0, round_half_away_from_zero),
    R = genlib_rational:new(P * Total, Q),
    Amount = ?cash(genlib_rational:round(R, RoundingMethod1), SymCode),
    Amount.

get_fee_share({fixed, _Fee}) ->
    undefined;
get_fee_share({share, Fee}) ->
    Fee.
