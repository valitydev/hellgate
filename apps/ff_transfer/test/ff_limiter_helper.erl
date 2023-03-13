-module(ff_limiter_helper).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").
-include_lib("ff_cth/include/ct_domain.hrl").

-export([init_per_suite/1]).
-export([get_limit_amount/3]).
-export([get_limit/3]).

-type withdrawal() :: ff_withdrawal:withdrawal_state() | dmsl_wthd_domain_thrift:'Withdrawal'().
-type limit() :: limproto_limiter_thrift:'Limit'().
-type config() :: ct_suite:ct_config().
-type id() :: binary().

-spec init_per_suite(config()) -> _.
init_per_suite(_Config) ->
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object_num(?LIMIT_TURNOVER_NUM_PAYTOOL_ID1)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object_num(?LIMIT_TURNOVER_NUM_PAYTOOL_ID2)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID3)}),
    _ = dmt_client:upsert({limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID4)}),
    ok.

-spec get_limit_amount(id(), withdrawal(), config()) -> integer().
get_limit_amount(LimitID, Withdrawal, Config) ->
    #limiter_Limit{amount = Amount} = get_limit(LimitID, Withdrawal, Config),
    Amount.

-spec get_limit(id(), withdrawal(), config()) -> limit().
get_limit(LimitId, Withdrawal, Config) ->
    MarshaledWithdrawal = maybe_marshal_withdrawal(Withdrawal),
    Context = #limiter_LimitContext{
        withdrawal_processing = #context_withdrawal_Context{
            op = {withdrawal, #context_withdrawal_OperationWithdrawal{}},
            withdrawal = #context_withdrawal_Withdrawal{withdrawal = MarshaledWithdrawal}
        }
    },
    #domain_conf_VersionedObject{version = Version} =
        dmt_client:checkout_versioned_object({'limit_config', #domain_LimitConfigRef{id = LimitId}}),
    {ok, Limit} = ff_ct_limiter_client:get(LimitId, Version, Context, ct_helper:get_woody_ctx(Config)),
    Limit.

maybe_marshal_withdrawal(Withdrawal = #wthd_domain_Withdrawal{}) ->
    Withdrawal;
maybe_marshal_withdrawal(Withdrawal) ->
    ff_limiter:marshal_withdrawal(Withdrawal).

limiter_mk_config_object_num(LimitID) ->
    #domain_LimitConfigObject{
        ref = #domain_LimitConfigRef{id = LimitID},
        data = #limiter_config_LimitConfig{
            processor_type = <<"TurnoverProcessor">>,
            created_at = <<"2000-01-01T00:00:00Z">>,
            started_at = <<"2000-01-01T00:00:00Z">>,
            shard_size = 12,
            time_range_type = {calendar, {month, #limiter_config_TimeRangeTypeCalendarMonth{}}},
            context_type = {withdrawal_processing, #limiter_config_LimitContextTypeWithdrawalProcessing{}},
            type = {turnover, #limiter_config_LimitTypeTurnover{}},
            scopes = [{payment_tool, #limiter_config_LimitScopeEmptyDetails{}}],
            description = <<"description">>,
            op_behaviour = #limiter_config_OperationLimitBehaviour{
                invoice_payment_refund = {subtraction, #limiter_config_Subtraction{}}
            }
        }
    }.

limiter_mk_config_object_amount(LimitID) ->
    #domain_LimitConfigObject{
        ref = #domain_LimitConfigRef{id = LimitID},
        data = #limiter_config_LimitConfig{
            processor_type = <<"TurnoverProcessor">>,
            created_at = <<"2000-01-01T00:00:00Z">>,
            started_at = <<"2000-01-01T00:00:00Z">>,
            shard_size = 12,
            time_range_type = {calendar, {month, #limiter_config_TimeRangeTypeCalendarMonth{}}},
            context_type = {withdrawal_processing, #limiter_config_LimitContextTypeWithdrawalProcessing{}},
            type =
                {turnover, #limiter_config_LimitTypeTurnover{
                    metric = {amount, #limiter_config_LimitTurnoverAmount{currency = <<"RUB">>}}
                }},
            scopes = [{party, #limiter_config_LimitScopeEmptyDetails{}}],
            description = <<"description">>,
            op_behaviour = #limiter_config_OperationLimitBehaviour{
                invoice_payment_refund = {subtraction, #limiter_config_Subtraction{}}
            }
        }
    }.
