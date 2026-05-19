-module(ff_withdrawal_adapter_host).

-behaviour(ff_woody_wrapper).

-include_lib("damsel/include/dmsl_wthd_provider_thrift.hrl").

%% Exports

-export([handle_function/3]).

%% Types

-type process_callback_result() :: dmsl_wthd_provider_thrift:'ProcessCallbackResult'().

%% Handler

-spec handle_function(woody:func(), woody:args(), woody:options()) -> {ok, woody:result()} | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(ff_withdrawal_adapter_host, #{}, fun() -> handle_function_(Func, Args, Opts) end).

%% Implementation

-spec handle_function_('ProcessCallback', woody:args(), woody:options()) ->
    {ok, process_callback_result()} | no_return().
handle_function_('ProcessCallback', {Callback}, _Opts) ->
    DecodedCallback = unmarshal(callback, Callback),
    case ff_withdrawal_session_machine:process_callback(DecodedCallback) of
        {ok, CallbackResponse} ->
            {ok, marshal(process_callback_result, {succeeded, CallbackResponse})};
        {error, {session_already_finished, Context}} ->
            {ok, marshal(process_callback_result, {finished, Context})};
        {error, {unknown_session, _Ref}} ->
            woody_error:raise(business, #wthd_provider_SessionNotFound{})
    end.

%%

marshal(Type, Value) ->
    ff_adapter_withdrawal_codec:marshal(Type, Value).

unmarshal(Type, Value) ->
    ff_adapter_withdrawal_codec:unmarshal(Type, Value).
