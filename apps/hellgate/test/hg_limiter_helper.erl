-module(hg_limiter_helper).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").
-include_lib("limiter_proto/include/limproto_config_thrift.hrl").
-include_lib("limiter_proto/include/limproto_configurator_thrift.hrl").

-include_lib("stdlib/include/assert.hrl").

-export([init_per_suite/1]).
-export([assert_payment_limit_amount/3]).
-export([get_payment_limit_amount/3]).

-type config() :: ct_suite:ct_config().

-define(LIMIT_ID, <<"ID">>).
-define(LIMIT_ID2, <<"ID2">>).
-define(LIMIT_ID3, <<"ID3">>).

-spec init_per_suite(config()) -> _.
init_per_suite(_Config) ->
    {ok, #config_LimitConfig{}} = hg_dummy_limiter:create_config(
        limiter_create_params(?LIMIT_ID),
        hg_dummy_limiter:new()
    ),
    {ok, #config_LimitConfig{}} = hg_dummy_limiter:create_config(
        limiter_create_params(?LIMIT_ID2),
        hg_dummy_limiter:new()
    ),
    {ok, #config_LimitConfig{}} = hg_dummy_limiter:create_config(
        limiter_create_params(?LIMIT_ID3),
        hg_dummy_limiter:new()
    ).

-spec assert_payment_limit_amount(_, _, _) -> _.
assert_payment_limit_amount(AssertAmount, Payment, Invoice) ->
    {ok, Limit} = get_payment_limit_amount(?LIMIT_ID, Payment, Invoice),
    ?assertMatch(#limiter_Limit{amount = AssertAmount}, Limit).

-spec get_payment_limit_amount(_, _, _) -> _.
get_payment_limit_amount(LimitId, Payment, Invoice) ->
    Context = #context_limiter_LimitContext{
        payment_processing = #context_payproc_Context{
            op = {invoice_payment, #context_payproc_OperationInvoicePayment{}},
            invoice = #context_payproc_Invoice{
                invoice = Invoice,
                payment = #context_payproc_InvoicePayment{
                    payment = Payment
                }
            }
        }
    },
    hg_dummy_limiter:get(LimitId, Context, hg_dummy_limiter:new()).

limiter_create_params(LimitID) ->
    #configurator_LimitCreateParams{
        id = LimitID,
        name = <<"ShopMonthTurnover">>,
        description = <<"description">>,
        started_at = <<"2000-01-01T00:00:00Z">>,
        op_behaviour = #config_OperationLimitBehaviour{
            invoice_payment_refund = {subtraction, #config_Subtraction{}}
        }
    }.
