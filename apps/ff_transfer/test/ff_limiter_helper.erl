-module(ff_limiter_helper).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_withdrawal_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").
-include_lib("ff_cth/include/ct_domain.hrl").

-export([init_per_suite/1]).
-export([get_limit_amount/4]).
-export([get_limit/4]).

-type withdrawal() :: ff_withdrawal:withdrawal_state() | dmsl_wthd_domain_thrift:'Withdrawal'().
-type limit() :: limproto_limiter_thrift:'Limit'().
-type config() :: ct_suite:ct_config().
-type id() :: binary().

-spec init_per_suite(config()) -> _.
init_per_suite(Config) ->
    SenderScopes = [{sender, #limiter_config_LimitScopeEmptyDetails{}}],
    LimitsRevision = dmt_client:upsert(
        [
            {limit_config, limiter_mk_config_object_num(?LIMIT_TURNOVER_NUM_PAYTOOL_ID1)},
            {limit_config, limiter_mk_config_object_num(?LIMIT_TURNOVER_NUM_PAYTOOL_ID2)},
            {limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID1)},
            {limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID2)},
            {limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID3)},
            {limit_config, limiter_mk_config_object_amount(?LIMIT_TURNOVER_AMOUNT_PAYTOOL_ID4)},
            {limit_config, limiter_mk_config_object_num(?LIMIT_TURNOVER_NUM_SENDER_ID1, SenderScopes)}
        ],
        dmt_client:create_author(genlib:unique(), genlib:unique())
    ),
    [{'$limits_domain_revision', LimitsRevision} | Config].

-spec get_limit_amount(id(), dmt_client:vsn(), withdrawal(), config()) -> integer().
get_limit_amount(LimitID, Version, Withdrawal, Config) ->
    #limiter_Limit{amount = Amount} = get_limit(LimitID, Version, Withdrawal, Config),
    Amount.

-spec get_limit(id(), dmt_client:vsn(), withdrawal(), config()) -> limit().
get_limit(LimitID, Version, Withdrawal, Config) ->
    MarshaledWithdrawal = maybe_marshal_withdrawal(Withdrawal),
    Context = #limiter_LimitContext{
        withdrawal_processing = #context_withdrawal_Context{
            op = {withdrawal, #context_withdrawal_OperationWithdrawal{}},
            withdrawal = #context_withdrawal_Withdrawal{withdrawal = MarshaledWithdrawal}
        }
    },
    maybe_uninitialized_limit(
        LimitID,
        ff_ct_limiter_client:get(LimitID, Version, Context, ct_helper:get_woody_ctx(Config))
    ).

-spec maybe_uninitialized_limit(limproto_limiter_thrift:'LimitID'(), {ok, _} | {exception, _}) -> _Limit.
maybe_uninitialized_limit(_LimitID, {ok, Limit}) ->
    Limit;
maybe_uninitialized_limit(LimitID, {exception, _}) ->
    #limiter_Limit{
        id = LimitID,
        amount = 0,
        creation_time = undefined,
        description = undefined
    }.

maybe_marshal_withdrawal(#wthd_domain_Withdrawal{} = Withdrawal) ->
    Withdrawal;
maybe_marshal_withdrawal(Withdrawal) ->
    ff_limiter:marshal_withdrawal(Withdrawal).

limiter_mk_config_object_num(LimitID) ->
    limiter_mk_config_object_num(LimitID, [{payment_tool, #limiter_config_LimitScopeEmptyDetails{}}]).

limiter_mk_config_object_num(LimitID, Scopes) ->
    #domain_LimitConfigObject{
        ref = #domain_LimitConfigRef{id = LimitID},
        data = #limiter_config_LimitConfig{
            processor_type = <<"TurnoverProcessor">>,
            started_at = <<"2000-01-01T00:00:00Z">>,
            shard_size = 12,
            time_range_type = {calendar, {month, #limiter_config_TimeRangeTypeCalendarMonth{}}},
            context_type = {withdrawal_processing, #limiter_config_LimitContextTypeWithdrawalProcessing{}},
            type = {turnover, #limiter_config_LimitTypeTurnover{}},
            scopes = Scopes,
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
