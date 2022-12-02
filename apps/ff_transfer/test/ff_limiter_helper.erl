-module(ff_limiter_helper).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").
-include_lib("limiter_proto/include/limproto_config_thrift.hrl").
-include_lib("limiter_proto/include/limproto_timerange_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("ff_cth/include/ct_domain.hrl").

-export([init_per_suite/1]).
-export([get_limit_amount/3]).
-export([get_limit/3]).

-type withdrawal() :: ff_withdrawal:withdrawal_state() | dmsl_wthd_domain_thrift:'Withdrawal'().
-type limit() :: limproto_limiter_thrift:'Limit'().
-type config() :: ct_suite:ct_config().
-type id() :: binary().

-spec init_per_suite(config()) -> _.
init_per_suite(Config) ->
    {ok, #config_LimitConfig{}} = ff_ct_limiter_client:create_config(
        limiter_create_num_params(?LIMIT_TURNOVER_NUM_PAYTOOL_ID1),
        ct_helper:get_woody_ctx(Config)
    ),
    {ok, #config_LimitConfig{}} = ff_ct_limiter_client:create_config(
        limiter_create_num_params(?LIMIT_TURNOVER_NUM_PAYTOOL_ID2),
        ct_helper:get_woody_ctx(Config)
    ),
    {ok, #config_LimitConfig{}} = ff_ct_limiter_client:create_config(
        limiter_create_amount_params(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1),
        ct_helper:get_woody_ctx(Config)
    ),
    {ok, #config_LimitConfig{}} = ff_ct_limiter_client:create_config(
        limiter_create_amount_params(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2),
        ct_helper:get_woody_ctx(Config)
    ),
    {ok, #config_LimitConfig{}} = ff_ct_limiter_client:create_config(
        limiter_create_amount_params(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID3),
        ct_helper:get_woody_ctx(Config)
    ),
    {ok, #config_LimitConfig{}} = ff_ct_limiter_client:create_config(
        limiter_create_amount_params(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID4),
        ct_helper:get_woody_ctx(Config)
    ).

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
    {ok, Limit} = ff_ct_limiter_client:get(LimitId, Context, ct_helper:get_woody_ctx(Config)),
    Limit.

maybe_marshal_withdrawal(Withdrawal = #wthd_domain_Withdrawal{}) ->
    Withdrawal;
maybe_marshal_withdrawal(Withdrawal) ->
    ff_limiter:marshal_withdrawal(Withdrawal).

limiter_create_num_params(LimitID) ->
    #config_LimitConfigParams{
        id = LimitID,
        started_at = <<"2000-01-01T00:00:00Z">>,
        shard_size = 12,
        time_range_type = {calendar, {month, #timerange_TimeRangeTypeCalendarMonth{}}},
        context_type = {withdrawal_processing, #config_LimitContextTypeWithdrawalProcessing{}},
        type = {turnover, #config_LimitTypeTurnover{}},
        scope = {single, {payment_tool, #config_LimitScopeEmptyDetails{}}},
        description = <<"description">>,
        op_behaviour = #config_OperationLimitBehaviour{
            invoice_payment_refund = {subtraction, #config_Subtraction{}}
        }
    }.

limiter_create_amount_params(LimitID) ->
    #config_LimitConfigParams{
        id = LimitID,
        started_at = <<"2000-01-01T00:00:00Z">>,
        shard_size = 12,
        time_range_type = {calendar, {month, #timerange_TimeRangeTypeCalendarMonth{}}},
        context_type = {withdrawal_processing, #config_LimitContextTypeWithdrawalProcessing{}},
        type =
            {turnover, #config_LimitTypeTurnover{metric = {amount, #config_LimitTurnoverAmount{currency = <<"RUB">>}}}},
        scope = {single, {party, #config_LimitScopeEmptyDetails{}}},
        description = <<"description">>,
        op_behaviour = #config_OperationLimitBehaviour{
            invoice_payment_refund = {subtraction, #config_Subtraction{}}
        }
    }.
