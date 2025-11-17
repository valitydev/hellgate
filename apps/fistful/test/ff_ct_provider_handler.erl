-module(ff_ct_provider_handler).

-behaviour(woody_server_thrift_handler).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_wthd_domain_thrift.hrl").

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%%
%% woody_server_thrift_handler callbacks
%%

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, woody:result()} | no_return().
handle_function('ProcessWithdrawal', {Withdrawal, InternalState, Options}, _Context, Opts) ->
    Handler = get_handler(Opts),
    DWithdrawal = decode_withdrawal(Withdrawal),
    DState = decode_state(InternalState),
    DOptions = decode_options(Options),
    {ok, ProcessResult} = Handler:process_withdrawal(DWithdrawal, DState, DOptions),
    #{intent := Intent} = ProcessResult,
    NewState = maps:get(next_state, ProcessResult, undefined),
    TransactionInfo = maps:get(transaction_info, ProcessResult, undefined),
    {ok, #wthd_provider_ProcessResult{
        intent = encode_intent(Intent),
        next_state = encode_state(NewState),
        trx = encode_trx(TransactionInfo)
    }};
handle_function('GetQuote', {QuoteParams, Options}, _Context, Opts) ->
    Handler = get_handler(Opts),
    Params = decode_quote_params(QuoteParams),
    DOptions = decode_options(Options),
    {ok, Quote} = Handler:get_quote(Params, DOptions),
    {ok, encode_quote(Quote)};
handle_function('HandleCallback', {Callback, Withdrawal, InternalState, Options}, _Context, Opts) ->
    Handler = get_handler(Opts),
    DCallback = decode_callback(Callback),
    DWithdrawal = decode_withdrawal(Withdrawal),
    DState = decode_state(InternalState),
    DOptions = decode_options(Options),
    {ok, CallbackResult} = Handler:handle_callback(DCallback, DWithdrawal, DState, DOptions),
    #{intent := Intent, response := Response} = CallbackResult,
    NewState = maps:get(next_state, CallbackResult, undefined),
    TransactionInfo = maps:get(transaction_info, CallbackResult, undefined),
    {ok, #wthd_provider_CallbackResult{
        intent = encode_intent(Intent),
        next_state = encode_state(NewState),
        response = encode_callback_response(Response),
        trx = encode_trx(TransactionInfo)
    }}.

%%
%% Internals
%%

decode_withdrawal(#wthd_provider_Withdrawal{
    id = Id,
    body = Body,
    destination = Destination,
    sender = Sender,
    receiver = Receiver,
    quote = Quote,
    auth_data = AuthData
}) ->
    genlib_map:compact(#{
        id => Id,
        body => Body,
        destination => Destination,
        sender => Sender,
        receiver => Receiver,
        quote => Quote,
        auth_data => decode_auth_data(AuthData)
    }).

decode_auth_data(undefined) ->
    undefined;
decode_auth_data(
    {sender_receiver, #wthd_domain_SenderReceiverAuthData{
        sender = Sender,
        receiver = Receiver
    }}
) ->
    genlib_map:compact(#{
        sender => Sender,
        receiver => Receiver
    }).

decode_quote_params(#wthd_provider_GetQuoteParams{
    idempotency_id = IdempotencyID,
    currency_from = CurrencyFrom,
    currency_to = CurrencyTo,
    exchange_cash = Cash,
    destination = Destination
}) ->
    genlib_map:compact(#{
        idempotency_id => IdempotencyID,
        currency_from => CurrencyFrom,
        currency_to => CurrencyTo,
        exchange_cash => Cash,
        destination => Destination
    }).

decode_options(Options) ->
    Options.

decode_state(State) ->
    ff_adapter_withdrawal_codec:unmarshal(adapter_state, State).

decode_callback(#wthd_provider_Callback{tag = Tag, payload = Payload}) ->
    #{tag => Tag, payload => Payload}.

%%

encode_state(State) ->
    ff_adapter_withdrawal_codec:marshal(adapter_state, State).

encode_intent(Intent) ->
    ff_adapter_withdrawal_codec:marshal(intent, Intent).

encode_trx(TrxInfo) ->
    ff_adapter_withdrawal_codec:marshal(transaction_info, TrxInfo).

encode_quote(#{
    cash_from := CashFrom,
    cash_to := CashTo,
    created_at := CreatedAt,
    expires_on := ExpiresOn,
    quote_data := QuoteData
}) ->
    #wthd_provider_Quote{
        cash_from = CashFrom,
        cash_to = CashTo,
        created_at = CreatedAt,
        expires_on = ExpiresOn,
        quote_data = QuoteData
    }.

encode_callback_response(#{payload := Payload}) ->
    #wthd_provider_CallbackResponse{payload = Payload}.

get_handler(Opts) ->
    proplists:get_value(handler, Opts, ff_ct_provider).
