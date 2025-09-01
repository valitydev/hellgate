-module(ff_ct_fail_provider).

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
-type party_id() :: dmsl_base_thrift:'ID'().
-type cash() :: dmsl_domain_thrift:'Cash'().
-type currency() :: dmsl_domain_thrift:'Currency'().
-type domain_quote() :: dmsl_wthd_provider_thrift:'Quote'().

-type withdrawal() :: #{
    id => binary(),
    body => cash(),
    destination => destination(),
    sender => party_id(),
    receiver => party_id(),
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

-record(state, {}).

-type state() :: #state{}.

-type transaction_info() :: ff_adapter:transaction_info().

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
process_withdrawal(_Withdrawal, State, _Options) ->
    Failure = #{
        code => <<"authorization_error">>,
        sub => #{code => <<"insufficient_funds">>}
    },
    {ok, #{
        intent => {finish, {failed, Failure}},
        next_state => State
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
handle_callback(_Callback, _Withdrawal, _State, _Options) ->
    erlang:error(not_implemented).
