-module(ff_ct_sleepy_provider).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_provider_thrift.hrl").

%% API
-export([start/0]).
-export([start/1]).

%% Processing callbacks
-export([process_withdrawal/3]).
-export([get_quote/2]).
-export([handle_callback/4]).

%%
%% Internal types
%%

-type destination() :: dmsl_wthd_domain_thrift:'Destination'().
-type identity() :: dmsl_wthd_domain_thrift:'Identity'().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type currency() :: dmsl_domain_thrift:'Currency'().
-type domain_quote() :: dmsl_wthd_provider_thrift:'Quote'().

-type withdrawal() :: #{
    id => binary(),
    body => cash(),
    destination => destination(),
    sender => identity(),
    receiver => identity(),
    quote => domain_quote()
}.

-type quote_params() :: #{
    idempotency_id => binary(),
    currency_from := currency(),
    currency_to := currency(),
    exchange_cash := cash()
}.

-type quote() :: #{
    cash_from := cash(),
    cash_to := cash(),
    created_at := binary(),
    expires_on := binary(),
    quote_data := any()
}.

-type callback() :: ff_withdrawal_callback:callback().

-type state() :: any().

-type transaction_info() :: ff_adapter:transaction_info().

%%

-define(DUMMY_QUOTE_ERROR_FATAL, {obj, #{{str, <<"test">>} => {str, <<"fatal">>}}}).

%%
%% API
%%

-spec start() -> {ok, pid()}.
start() ->
    start([]).

-spec start(list()) -> {ok, pid()}.
start(Opts) ->
    {ok, Pid} = supervisor:start_link(ff_ct_provider_sup, Opts),
    _ = erlang:unlink(Pid),
    {ok, Pid}.

%%
%% Processing callbacks
%%

-spec process_withdrawal(withdrawal(), state(), map()) ->
    {ok, #{
        intent := ff_adapter_withdrawal:intent(),
        next_state => state(),
        transaction_info => transaction_info()
    }}.
process_withdrawal(#{id := _}, nil, _Options) ->
    {ok, #{
        intent => {sleep, #{timer => {timeout, 1}}},
        next_state => <<"sleeping">>,
        transaction_info => #{id => <<"SleepyID">>, extra => #{}}
    }};
process_withdrawal(#{id := WithdrawalID}, <<"sleeping">>, _Options) ->
    CallbackTag = <<"cb_", WithdrawalID/binary>>,
    Deadline = calendar:system_time_to_universal_time(erlang:system_time(millisecond) + 5000, millisecond),
    {ok, #{
        intent => {sleep, #{timer => {deadline, {Deadline, 0}}, tag => CallbackTag}},
        next_state => <<"callback_processing">>,
        transaction_info => #{id => <<"SleepyID">>, extra => #{}}
    }}.

-dialyzer({nowarn_function, get_quote/2}).

-spec get_quote(quote_params(), map()) -> {ok, quote()}.
get_quote(_Quote, _Options) ->
    erlang:error(not_implemented).

-dialyzer({nowarn_function, handle_callback/4}).

-spec handle_callback(callback(), withdrawal(), state(), map()) ->
    {ok, #{
        intent := ff_adapter_withdrawal:intent(),
        response := any(),
        next_state => state(),
        transaction_info => transaction_info()
    }}.
handle_callback(_Callback, #{quote := #wthd_provider_Quote{quote_data = QuoteData}}, _State, _Options) when
    QuoteData =:= ?DUMMY_QUOTE_ERROR_FATAL
->
    erlang:error(spanish_inquisition);
handle_callback(#{payload := Payload}, _Withdrawal, <<"callback_processing">>, _Options) ->
    TransactionInfo = #{id => <<"SleepyID">>, extra => #{}},
    {ok, #{
        intent => {finish, {success, TransactionInfo}},
        next_state => <<"callback_finished">>,
        response => #{payload => Payload},
        transaction_info => TransactionInfo
    }}.
