-module(hg_limiter_helper).

-include_lib("limiter_proto/include/limproto_limiter_thrift.hrl").
-include_lib("limiter_proto/include/limproto_context_payproc_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_limiter_config_thrift.hrl").

-include_lib("stdlib/include/assert.hrl").

-export([init_per_suite/1]).
-export([get_amount/1]).
-export([assert_payment_limit_amount/5]).
-export([maybe_uninitialized_limit/1]).
-export([get_payment_limit_amount/4]).
-export([mk_config_object/2, mk_config_object/3, mk_config_object/4]).
-export([mk_context_type/1]).
-export([mk_scopes/1]).

-type config() :: ct_suite:ct_config().

-define(LIMIT_ID, <<"ID">>).
-define(LIMIT_ID2, <<"ID2">>).
-define(LIMIT_ID3, <<"ID3">>).
-define(LIMIT_ID4, <<"ID4">>).
-define(SHOPLIMIT_ID, <<"SHOPLIMITID">>).

-define(PLACEHOLDER_UNINITIALIZED_LIMIT_ID, <<"uninitialized limit">>).
-define(PLACEHOLDER_OPERATION_GET_LIMIT_VALUES, <<"get values">>).

-spec init_per_suite(config()) -> dmt_client:vsn().
init_per_suite(_Config) ->
    dmt_client:upsert(
        latest,
        [
            {limit_config, mk_config_object(?LIMIT_ID)},
            {limit_config, mk_config_object(?LIMIT_ID2)},
            {limit_config, mk_config_object(?LIMIT_ID3)},
            {limit_config, mk_config_object(?LIMIT_ID4)},
            {limit_config, mk_config_object(?SHOPLIMIT_ID)}
        ],
        dmt_client:create_author(genlib:unique(), genlib:unique()),
        #{}
    ).

-spec get_amount(_) -> pos_integer().
get_amount(#limiter_Limit{amount = Amount}) ->
    Amount.

-spec assert_payment_limit_amount(_, _, _, _, _) -> _.
assert_payment_limit_amount(LimitID, Version, AssertAmount, Payment, Invoice) ->
Result  = get_payment_limit_amount(LimitID, Version, Payment, Invoice),
    Limit = maybe_uninitialized_limit(Result),
    #limiter_Limit{amount = CurrentAmount} = Limit,
    ?assertEqual(AssertAmount, CurrentAmount, {LimitID, Result}).

-spec maybe_uninitialized_limit({ok, _} | {exception, _}) -> _Limit.
maybe_uninitialized_limit({ok, Limit}) ->
    Limit;
maybe_uninitialized_limit({exception, _}) ->
    #limiter_Limit{
        id = ?PLACEHOLDER_UNINITIALIZED_LIMIT_ID,
        amount = 0,
        creation_time = undefined,
        description = undefined
    }.

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
    LimitRequest = #limiter_LimitRequest{
        operation_id = ?PLACEHOLDER_OPERATION_GET_LIMIT_VALUES,
        limit_changes = [#limiter_LimitChange{id = LimitId, version = Version}]
    },
    try hg_limiter_client:get_values(LimitRequest, Context) of
        [L] ->
            {ok, L};
        _ ->
            {exception, #limiter_LimitNotFound{}}
    catch
        error:not_found ->
            {exception, #limiter_LimitNotFound{}}
    end.

mk_config_object(LimitID) ->
    mk_config_object(LimitID, <<"RUB">>).

-spec mk_config_object(_, _) -> _.
mk_config_object(LimitID, Currency) ->
    mk_config_object(LimitID, Currency, mk_context_type(payment)).

-spec mk_config_object(_, _, _) -> _.
mk_config_object(LimitID, Currency, ContextType) ->
    mk_config_object(LimitID, Currency, ContextType, mk_scopes([shop])).

-spec mk_config_object(_, _, _, _) -> _.
mk_config_object(LimitID, Currency, ContextType, Scopes) ->
    #domain_LimitConfigObject{
        ref = #domain_LimitConfigRef{id = LimitID},
        data = #limiter_config_LimitConfig{
            processor_type = <<"TurnoverProcessor">>,
            created_at = <<"2000-01-01T00:00:00Z">>,
            started_at = <<"2000-01-01T00:00:00Z">>,
            shard_size = 12,
            time_range_type = {calendar, {month, #limiter_config_TimeRangeTypeCalendarMonth{}}},
            context_type = ContextType,
            type =
                {turnover, #limiter_config_LimitTypeTurnover{
                    metric = {amount, #limiter_config_LimitTurnoverAmount{currency = Currency}}
                }},
            scopes = Scopes,
            description = <<"description">>,
            op_behaviour = #limiter_config_OperationLimitBehaviour{
                invoice_payment_refund = {subtraction, #limiter_config_Subtraction{}}
            }
        }
    }.

-spec mk_context_type(payment | withdrawal) -> _.
mk_context_type(withdrawal) ->
    {withdrawal_processing, #limiter_config_LimitContextTypeWithdrawalProcessing{}};
mk_context_type(payment) ->
    {payment_processing, #limiter_config_LimitContextTypePaymentProcessing{}}.

-spec mk_scopes(_) -> _.
mk_scopes(ScopeTags) ->
    ordsets:from_list([{Tag, #limiter_config_LimitScopeEmptyDetails{}} || Tag <- ScopeTags]).
