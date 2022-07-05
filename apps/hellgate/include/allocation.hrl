-ifndef(__hellgate_allocation__).
-define(__hellgate_allocation__, true).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%% Prototypes

-define(allocation_prototype(Transactions), #domain_AllocationPrototype{
    transactions = Transactions
}).

-define(allocation_trx_prototype(Target, Body), #domain_AllocationTransactionPrototype{
    target = Target,
    body = Body
}).

-define(allocation_trx_prototype(Target, Body, Details), #domain_AllocationTransactionPrototype{
    target = Target,
    body = Body,
    details = Details
}).

-define(allocation_trx_prototype_body_amount(Amount),
    {amount, #domain_AllocationTransactionPrototypeBodyAmount{
        amount = Amount
    }}
).

-define(allocation_trx_prototype_body_total(Total, Fee),
    {total, #domain_AllocationTransactionPrototypeBodyTotal{
        total = Total,
        fee = Fee
    }}
).

-define(allocation_trx_prototype_fee_fixed(Amount),
    {fixed, #domain_AllocationTransactionPrototypeFeeFixed{
        amount = Amount
    }}
).

-define(allocation_trx_prototype_fee_share(P, Q), {share, ?allocation_trx_fee_share(P, Q)}).

-define(allocation_trx_prototype_fee_share(P, Q, RoundingMethod),
    {share, ?allocation_trx_fee_share(P, Q, RoundingMethod)}
).

%% Final

-define(allocation(Transactions), #domain_Allocation{
    transactions = Transactions
}).

-define(allocation_trx(ID, Target, Amount), #domain_AllocationTransaction{
    id = ID,
    target = Target,
    amount = Amount
}).

-define(allocation_trx(ID, Target, Amount, Details), #domain_AllocationTransaction{
    id = ID,
    target = Target,
    amount = Amount,
    details = Details
}).

-define(allocation_trx(ID, Target, Amount, Details, Body), #domain_AllocationTransaction{
    id = ID,
    target = Target,
    amount = Amount,
    details = Details,
    body = Body
}).

-define(allocation_trx_target_shop(OwnerID, ShopID),
    {shop, #domain_AllocationTransactionTargetShop{
        owner_id = OwnerID,
        shop_id = ShopID
    }}
).

-define(allocation_trx_details(Cart), #domain_AllocationTransactionDetails{
    cart = Cart
}).

-define(allocation_trx_body_total(FeeTarget, Total, FeeAmount), #domain_AllocationTransactionBodyTotal{
    fee_target = FeeTarget,
    total = Total,
    fee_amount = FeeAmount
}).

-define(allocation_trx_body_total(FeeTarget, Total, FeeAmount, Fee), #domain_AllocationTransactionBodyTotal{
    fee_target = FeeTarget,
    total = Total,
    fee_amount = FeeAmount,
    fee = Fee
}).

-define(allocation_trx_fee_share(P, Q), #domain_AllocationTransactionFeeShare{
    parts = #base_Rational{
        p = P,
        q = Q
    }
}).

-define(allocation_trx_fee_share(P, Q, RoundingMethod), #domain_AllocationTransactionFeeShare{
    parts = #base_Rational{
        p = P,
        q = Q
    },
    rounding_method = RoundingMethod
}).

-endif.
