-module(ff_deposit_handler).

-behaviour(ff_woody_wrapper).

-include_lib("fistful_proto/include/fistful_deposit_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").

%% ff_woody_wrapper callbacks
-export([handle_function/3]).

%%
%% ff_woody_wrapper callbacks
%%

-spec handle_function(woody:func(), woody:args(), woody:options()) -> {ok, woody:result()} | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(
        deposit,
        #{},
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

%%
%% Internals
%%

handle_function_('Create', {MarshaledParams, MarshaledContext}, Opts) ->
    Params = ff_deposit_codec:unmarshal(deposit_params, MarshaledParams),
    Context = ff_deposit_codec:unmarshal(context, MarshaledContext),
    ok = scoper:add_meta(maps:with([id, wallet_id, source_id, external_id], Params)),
    case ff_deposit_machine:create(Params, Context) of
        ok ->
            handle_function_('Get', {maps:get(id, Params), #'fistful_base_EventRange'{}}, Opts);
        {error, exists} ->
            handle_function_('Get', {maps:get(id, Params), #'fistful_base_EventRange'{}}, Opts);
        {error, {wallet, notfound}} ->
            woody_error:raise(business, #fistful_WalletNotFound{});
        {error, {source, notfound}} ->
            woody_error:raise(business, #fistful_SourceNotFound{});
        {error, {source, unauthorized}} ->
            woody_error:raise(business, #fistful_SourceUnauthorized{});
        {error, {terms_violation, {not_allowed_currency, {DomainCurrency, DomainAllowed}}}} ->
            Currency = ff_dmsl_codec:unmarshal(currency_ref, DomainCurrency),
            Allowed = [ff_dmsl_codec:unmarshal(currency_ref, C) || C <- DomainAllowed],
            woody_error:raise(business, #fistful_ForbiddenOperationCurrency{
                currency = ff_codec:marshal(currency_ref, Currency),
                allowed_currencies = ff_codec:marshal({set, currency_ref}, Allowed)
            });
        {error, {inconsistent_currency, {Deposit, Source, Wallet}}} ->
            woody_error:raise(business, #deposit_InconsistentDepositCurrency{
                deposit_currency = ff_codec:marshal(currency_ref, Deposit),
                source_currency = ff_codec:marshal(currency_ref, Source),
                wallet_currency = ff_codec:marshal(currency_ref, Wallet)
            });
        {error, {bad_deposit_amount, Amount}} ->
            woody_error:raise(business, #fistful_InvalidOperationAmount{
                amount = ff_codec:marshal(cash, Amount)
            })
    end;
handle_function_('Get', {ID, EventRange}, _Opts) ->
    ok = scoper:add_meta(#{id => ID}),
    case ff_deposit_machine:get(ID, ff_codec:unmarshal(event_range, EventRange)) of
        {ok, Machine} ->
            Deposit = ff_deposit_machine:deposit(Machine),
            Context = ff_deposit_machine:ctx(Machine),
            Response = ff_deposit_codec:marshal_deposit_state(Deposit, Context),
            {ok, Response};
        {error, {unknown_deposit, ID}} ->
            woody_error:raise(business, #fistful_DepositNotFound{})
    end;
handle_function_('GetContext', {ID}, _Opts) ->
    ok = scoper:add_meta(#{id => ID}),
    case ff_deposit_machine:get(ID, {undefined, 0}) of
        {ok, Machine} ->
            Context = ff_deposit_machine:ctx(Machine),
            {ok, ff_codec:marshal(context, Context)};
        {error, {unknown_deposit, ID}} ->
            woody_error:raise(business, #fistful_DepositNotFound{})
    end;
handle_function_('GetEvents', {ID, EventRange}, _Opts) ->
    ok = scoper:add_meta(#{id => ID}),
    case ff_deposit_machine:events(ID, ff_codec:unmarshal(event_range, EventRange)) of
        {ok, Events} ->
            {ok, [ff_deposit_codec:marshal(event, E) || E <- Events]};
        {error, {unknown_deposit, ID}} ->
            woody_error:raise(business, #fistful_DepositNotFound{})
    end.
