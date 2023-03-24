-module(hg_limiter_helper).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_conf_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").

-include_lib("stdlib/include/assert.hrl").

-export([init_per_suite/1]).
-export([get_amount/1]).
-export([assert_payment_limit_amount/3]).
-export([assert_payment_limit_amount/4]).
-export([get_payment_limit_amount/4]).

-type config() :: ct_suite:ct_config().

-define(LIMIT_ID, <<"ID">>).
-define(LIMIT_ID2, <<"ID2">>).
-define(LIMIT_ID3, <<"ID3">>).
-define(LIMIT_ID4, <<"ID4">>).

-spec init_per_suite(config()) -> _.
init_per_suite(_Config) ->
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object(?LIMIT_ID)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object(?LIMIT_ID2)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object(?LIMIT_ID3)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object(?LIMIT_ID4)}).

-spec get_amount(_) -> pos_integer().
get_amount(#limiter_Limit{amount = Amount}) ->
    Amount.

-spec assert_payment_limit_amount(_, _, _) -> _.
assert_payment_limit_amount(AssertAmount, Payment, Invoice) ->
    assert_payment_limit_amount(?LIMIT_ID, AssertAmount, Payment, Invoice).

-spec assert_payment_limit_amount(_, _, _, _) -> _.
assert_payment_limit_amount(LimitID, AssertAmount, Payment, Invoice) ->
    L =
        dmt_client:checkout_versioned_object({'limit_config', #domain_LimitConfigRef{id = LimitID}}),
    #domain_conf_VersionedObject{version = Version} = L,
    {ok, Limit} = get_payment_limit_amount(LimitID, Version, Payment, Invoice),
    ?assertMatch(#limiter_Limit{amount = AssertAmount}, Limit).

-spec get_payment_limit_amount(_, _, _, _) -> _.
get_payment_limit_amount(LimitId, Version, Payment, Invoice) ->
    Context = #limiter_LimitContext{
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
    hg_dummy_limiter:get(LimitId, Version, Context, hg_dummy_limiter:new()).

limiter_mk_config_object(LimitID) ->
    #domain_LimitConfigObject{
        ref = #domain_LimitConfigRef{id = LimitID},
        data = #limiter_config_LimitConfig{
            processor_type = <<"TurnoverProcessor">>,
            created_at = <<"2000-01-01T00:00:00Z">>,
            started_at = <<"2000-01-01T00:00:00Z">>,
            shard_size = 12,
            time_range_type = {calendar, {month, #limiter_config_TimeRangeTypeCalendarMonth{}}},
            context_type = {payment_processing, #limiter_config_LimitContextTypePaymentProcessing{}},
            type =
                {turnover, #limiter_config_LimitTypeTurnover{
                    metric = {amount, #limiter_config_LimitTurnoverAmount{currency = <<"RUB">>}}
                }},
            scopes = [{shop, #limiter_config_LimitScopeEmptyDetails{}}],
            description = <<"description">>,
            op_behaviour = #limiter_config_OperationLimitBehaviour{
                invoice_payment_refund = {subtraction, #limiter_config_Subtraction{}}
            }
        }
    }.
