-module(ct_cardstore).

-export([bank_card/2]).

%%

-spec bank_card(binary(), {1..12, 2000..9999}) ->
    #{
        token := binary(),
        bin => binary(),
        masked_pan => binary(),
        exp_date => {integer(), integer()},
        cardholder_name => binary()
    }.
bank_card(PAN, ExpDate) ->
    #{
        token => PAN,
        bin => binary:part(PAN, {0, 6}),
        masked_pan => <<<<"*">> || <<_>> <= PAN>>,
        exp_date => ExpDate,
        cardholder_name => <<"ct_cardholder_name">>
    }.
