-module(hg_dummy_limiter).

-include_lib("limiter_proto/include/lim_limiter_thrift.hrl").
-include_lib("limiter_proto/include/lim_configurator_thrift.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([new/0]).
-export([get/3]).
-export([hold/3]).
-export([commit/3]).

-export([create_config/2]).
-export([get_config/2]).
-export([init_per_suite/1]).
-export([assert_payment_limit_amount/3]).

-type client() :: woody_context:ctx().

-type limit_id() :: lim_limiter_thrift:'LimitID'().
-type limit_change() :: lim_limiter_thrift:'LimitChange'().
-type limit_context() :: lim_limiter_thrift:'LimitContext'().
-type clock() :: lim_limiter_thrift:'Clock'().
-type limit_config_params() :: lim_configurator_thrift:'LimitCreateParams'().
-type config() :: [{atom(), term()}].

-define(LIMIT_ID, <<"ID">>).
-define(LIMIT_ID2, <<"ID2">>).
-define(LIMIT_ID3, <<"ID3">>).

%%% API

-spec new() -> client().
new() ->
    woody_context:new().

-spec get(limit_id(), limit_context(), client()) -> woody:result() | no_return().
get(LimitID, Context, Client) ->
    call('Get', {LimitID, clock(), Context}, Client).

-spec hold(limit_change(), limit_context(), client()) -> woody:result() | no_return().
hold(LimitChange, Context, Client) ->
    call('Hold', {LimitChange, clock(), Context}, Client).

-spec commit(limit_change(), limit_context(), client()) -> woody:result() | no_return().
commit(LimitChange, Context, Client) ->
    call('Commit', {LimitChange, clock(), Context}, Client).

-spec create_config(limit_config_params(), client()) -> woody:result() | no_return().
create_config(LimitCreateParams, Client) ->
    call_configurator('CreateLegacy', {LimitCreateParams}, Client).

-spec get_config(limit_id(), client()) -> woody:result() | no_return().
get_config(LimitConfigID, Client) ->
    call_configurator('Get', {LimitConfigID}, Client).

-spec init_per_suite(config()) -> _.
init_per_suite(_Config) ->
    {ok, #limiter_config_LimitConfig{}} = hg_dummy_limiter:create_config(
        limiter_create_params(?LIMIT_ID),
        hg_dummy_limiter:new()
    ),
    {ok, #limiter_config_LimitConfig{}} = hg_dummy_limiter:create_config(
        limiter_create_params(?LIMIT_ID2),
        hg_dummy_limiter:new()
    ),
    {ok, #limiter_config_LimitConfig{}} = hg_dummy_limiter:create_config(
        limiter_create_params(?LIMIT_ID3),
        hg_dummy_limiter:new()
    ).

-spec assert_payment_limit_amount(_, _, _) -> _.
assert_payment_limit_amount(AssertAmount, Payment, Invoice) ->
    Context = #limiter_context_LimitContext{
        payment_processing = #limiter_context_payproc_Context{
            op = {invoice_payment, #limiter_context_payproc_OperationInvoicePayment{}},
            invoice = #limiter_context_payproc_Invoice{
                invoice = Invoice,
                payment = #limiter_context_payproc_InvoicePayment{
                    payment = Payment
                }
            }
        }
    },
    {ok, Limit} = hg_dummy_limiter:get(?LIMIT_ID, Context, hg_dummy_limiter:new()),
    ?assertMatch(#limiter_Limit{amount = AssertAmount}, Limit).

%%% Internal functions

-spec call(atom(), tuple(), client()) -> woody:result() | no_return().
call(Function, Args, Client) ->
    Call = {{lim_limiter_thrift, 'Limiter'}, Function, Args},
    Opts = #{
        url => <<"http://limiter:8022/v1/limiter">>,
        event_handler => scoper_woody_event_handler,
        transport_opts => #{
            max_connections => 10000
        }
    },
    woody_client:call(Call, Opts, Client).

-spec call_configurator(atom(), tuple(), client()) -> woody:result() | no_return().
call_configurator(Function, Args, Client) ->
    Call = {{lim_configurator_thrift, 'Configurator'}, Function, Args},
    Opts = #{
        url => <<"http://limiter:8022/v1/configurator">>,
        event_handler => scoper_woody_event_handler,
        transport_opts => #{
            max_connections => 10000
        }
    },
    woody_client:call(Call, Opts, Client).

-spec clock() -> clock().
clock() ->
    {vector, #limiter_VectorClock{state = <<>>}}.

limiter_create_params(LimitID) ->
    #limiter_configurator_LimitCreateParams{
        id = LimitID,
        name = <<"ShopMonthTurnover">>,
        description = <<"description">>,
        started_at = <<"2000-01-01T00:00:00Z">>,
        op_behaviour = #limiter_config_OperationLimitBehaviour{
            invoice_payment_refund = {subtraction, #limiter_config_Subtraction{}}
        }
    }.
