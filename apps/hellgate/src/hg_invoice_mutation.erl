-module(hg_invoice_mutation).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([make_mutations/2]).
-export([get_mutated_cost/2]).
-export([validate_mutations/2]).
-export([apply_mutations/2]).

-type mutation_params() :: dmsl_domain_thrift:'InvoiceMutationParams'().
-type mutation() :: dmsl_domain_thrift:'InvoiceMutation'().
-type mutation_context() :: #{
    cost := hg_cash:cash()
}.

-export_type([mutation_params/0]).
-export_type([mutation/0]).

%%

-spec get_mutated_cost([mutation()], Cost) -> Cost when Cost :: hg_cash:cash().
get_mutated_cost(Mutations, Cost) ->
    lists:foldl(
        fun
            ({amount, #domain_InvoiceAmountMutation{mutated = MutatedAmount}}, C) ->
                C#domain_Cash{amount = MutatedAmount};
            (_, C) ->
                C
        end,
        Cost,
        Mutations
    ).

-type invoice_details() :: dmsl_domain_thrift:'InvoiceDetails'().
-type invoice_template_details() :: dmsl_domain_thrift:'InvoiceTemplateDetails'().

-spec validate_mutations([mutation_params()], invoice_details() | invoice_template_details()) -> ok.
validate_mutations(Mutations, #domain_InvoiceDetails{cart = #domain_InvoiceCart{} = Cart}) ->
    validate_mutations_w_cart(Mutations, Cart);
validate_mutations(Mutations, {cart, #domain_InvoiceCart{} = Cart}) ->
    validate_mutations_w_cart(Mutations, Cart);
validate_mutations(_Mutations, _Details) ->
    ok.

validate_mutations_w_cart(Mutations, #domain_InvoiceCart{lines = Lines}) ->
    Mutations1 = genlib:define(Mutations, []),
    amount_mutation_is_present(Mutations1) andalso cart_is_valid_for_mutation(Lines) andalso
        throw(#base_InvalidRequest{
            errors = [<<"Amount mutation with multiline cart or multiple items in a line is not allowed">>]
        }),
    ok.

amount_mutation_is_present(Mutations) ->
    lists:any(
        fun
            ({amount, _}) -> true;
            (_) -> false
        end,
        Mutations
    ).

cart_is_valid_for_mutation(Lines) ->
    length(Lines) > 1 orelse (hd(Lines))#domain_InvoiceLine.quantity =/= 1.

-spec apply_mutations([mutation_params()] | undefined, Invoice) -> Invoice when Invoice :: hg_invoice:invoice().
apply_mutations(MutationsParams, Invoice) ->
    lists:foldl(fun apply_mutation/2, Invoice, genlib:define(MutationsParams, [])).

apply_mutation(Mutation = {amount, #domain_InvoiceAmountMutation{mutated = NewAmount}}, Invoice) ->
    #domain_Invoice{cost = Cost, mutations = Mutations} = Invoice,
    update_invoice_details_price(NewAmount, Invoice#domain_Invoice{
        cost = Cost#domain_Cash{amount = NewAmount},
        mutations = genlib:define(Mutations, []) ++ [Mutation]
    });
apply_mutation(_, Invoice) ->
    Invoice.

update_invoice_details_price(NewAmount, Invoice) ->
    #domain_Invoice{details = Details} = Invoice,
    #domain_InvoiceDetails{cart = Cart} = Details,
    #domain_InvoiceCart{lines = [Line]} = Cart,
    NewLines = [update_invoice_line_price(NewAmount, Line)],
    NewCart = Cart#domain_InvoiceCart{lines = NewLines},
    Invoice#domain_Invoice{details = Details#domain_InvoiceDetails{cart = NewCart}}.

update_invoice_line_price(NewAmount, Line = #domain_InvoiceLine{price = Price}) ->
    Line#domain_InvoiceLine{price = Price#domain_Cash{amount = NewAmount}}.

-spec make_mutations([mutation_params()], mutation_context()) -> [mutation()].
make_mutations(MutationsParams, Context) ->
    {Mutations, _} = lists:foldl(fun make_mutation/2, {[], Context}, genlib:define(MutationsParams, [])),
    lists:reverse(Mutations).

-define(SATISFY_RANDOMIZATION_CONDITION(P, Amount),
    %% Multiplicity check
    (P#domain_RandomizationMutationParams.amount_multiplicity_condition =:= undefined orelse
        Amount rem P#domain_RandomizationMutationParams.amount_multiplicity_condition =:= 0) andalso
        %% Min amount
        (P#domain_RandomizationMutationParams.min_amount_condition =:= undefined orelse
            P#domain_RandomizationMutationParams.min_amount_condition =< Amount) andalso
        %% Max amount
        (P#domain_RandomizationMutationParams.max_amount_condition =:= undefined orelse
            P#domain_RandomizationMutationParams.max_amount_condition >= Amount)
).

make_mutation(
    {amount, {randomization, Params = #domain_RandomizationMutationParams{}}},
    {Mutations, Context = #{cost := #domain_Cash{amount = Amount}}}
) when ?SATISFY_RANDOMIZATION_CONDITION(Params, Amount) ->
    NewMutation =
        {amount, #domain_InvoiceAmountMutation{original = Amount, mutated = calc_new_amount(Amount, Params)}},
    {[NewMutation | Mutations], Context};
make_mutation(_, {Mutations, Context}) ->
    {Mutations, Context}.

calc_new_amount(Amount, #domain_RandomizationMutationParams{
    deviation = MaxDeviation,
    precision = Precision,
    rounding = RoundingMethod
}) ->
    Deviation = calc_deviation(RoundingMethod, MaxDeviation, trunc(math:pow(10, Precision))),
    Sign = trunc(math:pow(-1, rand:uniform(2))),
    Amount + Sign * Deviation.

calc_deviation(RoundingMethod, MaxDeviation, PrecisionFactor) ->
    RoundingFun = rounding_fun(RoundingMethod),
    Deviation0 = rand:uniform(MaxDeviation + 1) - 1,
    RoundingFun(Deviation0 / PrecisionFactor) * PrecisionFactor.

rounding_fun(RoundingMethod) ->
    case RoundingMethod of
        round_half_towards_zero -> fun round/1;
        round_half_away_from_zero -> fun round/1;
        round_down -> fun floor/1;
        round_up -> fun ceil/1
    end.

%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-define(mutations(Deviation, Precision, Rounding, Min, Max, Multiplicity), [
    {amount,
        {randomization, #domain_RandomizationMutationParams{
            deviation = Deviation,
            precision = Precision,
            rounding = Rounding,
            min_amount_condition = Min,
            max_amount_condition = Max,
            amount_multiplicity_condition = Multiplicity
        }}}
]).

-define(cash(Amount), #domain_Cash{amount = Amount, currency = ?currency()}).

-define(currency(), #domain_CurrencyRef{symbolic_code = <<"RUB">>}).

-define(invoice(Amount, Lines, Mutations), #domain_Invoice{
    id = <<"invoice">>,
    shop_id = <<"shop_id">>,
    owner_id = <<"owner_id">>,
    created_at = <<"1970-01-01T00:00:00Z">>,
    status = {unpaid, #domain_InvoiceUnpaid{}},
    cost = ?cash(Amount),
    due = <<"1970-01-01T00:00:00Z">>,
    details = #domain_InvoiceDetails{
        product = <<"rubberduck">>,
        cart = #domain_InvoiceCart{lines = Lines}
    },
    mutations = Mutations
}).

-define(mutated_invoice(OriginalAmount, MutatedAmount, Lines),
    ?invoice(MutatedAmount, Lines, [
        {amount, #domain_InvoiceAmountMutation{original = OriginalAmount, mutated = MutatedAmount}}
    ])
).

-define(not_mutated_invoice(Amount, Lines), ?invoice(Amount, Lines, undefined)).

-define(cart_line(Price), #domain_InvoiceLine{
    product = <<"product">>,
    quantity = 1,
    price = ?cash(Price),
    metadata = #{}
}).

-spec apply_mutations_test_() -> [_TestGen].
apply_mutations_test_() ->
    lists:flatten([
        %% Didn't mutate because of conditions
        ?_assertEqual(
            ?not_mutated_invoice(1000_00, [?cart_line(1000_00)]),
            apply_mutations(
                make_mutations(?mutations(100_00, 2, round_half_away_from_zero, 0, 100_00, 1_00), #{
                    cost => ?cash(1000_00)
                }),
                ?not_mutated_invoice(1000_00, [?cart_line(1000_00)])
            )
        ),
        ?_assertEqual(
            ?not_mutated_invoice(1234_00, [?cart_line(1234_00)]),
            apply_mutations(
                make_mutations(?mutations(100_00, 2, round_half_away_from_zero, 0, 1000_00, 7_00), #{
                    cost => ?cash(1234_00)
                }),
                ?not_mutated_invoice(1234_00, [?cart_line(1234_00)])
            )
        ),

        %% No deviation, stil did mutate, but amount is same
        ?_assertEqual(
            ?mutated_invoice(100_00, 100_00, [?cart_line(100_00)]),
            apply_mutations(
                make_mutations(?mutations(0, 2, round_half_away_from_zero, 0, 1000_00, 1_00), #{
                    cost => ?cash(100_00)
                }),
                ?not_mutated_invoice(100_00, [?cart_line(100_00)])
            )
        ),

        %% Deviate only with 2 other possible values
        [
            ?_assertMatch(
                ?mutated_invoice(100_00, A, [?cart_line(A)]) when
                    A =:= 0 orelse A =:= 100_00 orelse A =:= 200_00,
                apply_mutations(
                    make_mutations(Mutations, #{cost => ?cash(100_00)}),
                    ?not_mutated_invoice(100_00, [?cart_line(100_00)])
                )
            )
         || Mutations <- lists:duplicate(10, ?mutations(100_00, 4, round_half_away_from_zero, 0, 1000_00, 1_00))
        ],

        %% Deviate in segment [900_00, 1100_00] without minor units
        [
            ?_assertMatch(
                ?mutated_invoice(1000_00, A, [?cart_line(A)]) when
                    A >= 900_00 andalso A =< 1100_00 andalso A rem 100 =:= 0,
                apply_mutations(
                    make_mutations(Mutations, #{cost => ?cash(1000_00)}),
                    ?not_mutated_invoice(1000_00, [?cart_line(1000_00)])
                )
            )
         || Mutations <- lists:duplicate(10, ?mutations(100_00, 2, round_half_away_from_zero, 0, 1000_00, 1_00))
        ]
    ]).

-endif.
