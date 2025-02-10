-module(ff_identity_handler).

-behaviour(ff_woody_wrapper).

-include_lib("fistful_proto/include/fistful_identity_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").

%% ff_woody_wrapper callbacks
-export([handle_function/3]).

%%
%% ff_woody_wrapper callbacks
%%
-spec handle_function(woody:func(), woody:args(), woody:options()) -> {ok, woody:result()} | no_return().
handle_function(Func, Args, Opts) ->
    IdentityID = get_identity_id(Func, Args),
    scoper:scope(
        identity,
        #{identity_id => IdentityID},
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

%%
%% Internals
%%

handle_function_('Create', {IdentityParams, Context}, Opts) ->
    Params = #{id := IdentityID} = ff_identity_codec:unmarshal_identity_params(IdentityParams),
    case ff_identity_machine:create(Params, ff_identity_codec:unmarshal(ctx, Context)) of
        ok ->
            handle_function_('Get', {IdentityID, #'fistful_base_EventRange'{}}, Opts);
        {error, {provider, notfound}} ->
            woody_error:raise(business, #fistful_ProviderNotFound{});
        {error, {party, notfound}} ->
            woody_error:raise(business, #fistful_PartyNotFound{});
        {error, {party, {inaccessible, _}}} ->
            woody_error:raise(business, #fistful_PartyInaccessible{});
        {error, exists} ->
            handle_function_('Get', {IdentityID, #'fistful_base_EventRange'{}}, Opts);
        {error, Error} ->
            woody_error:raise(system, {internal, result_unexpected, woody_error:format_details(Error)})
    end;
handle_function_('Get', {ID, EventRange}, _Opts) ->
    case ff_identity_machine:get(ID, ff_codec:unmarshal(event_range, EventRange)) of
        {ok, Machine} ->
            Identity = ff_identity:set_blocking(ff_identity_machine:identity(Machine)),
            Context = ff_identity_machine:ctx(Machine),
            Response = ff_identity_codec:marshal_identity_state(Identity, Context),
            {ok, Response};
        {error, notfound} ->
            woody_error:raise(business, #fistful_IdentityNotFound{})
    end;
handle_function_('GetWithdrawalMethods', {ID}, _Opts) ->
    case ff_identity_machine:get(ID) of
        {ok, Machine} ->
            DmslMethods = ff_identity:get_withdrawal_methods(ff_identity_machine:identity(Machine)),
            Methods = lists:map(
                fun(DmslMethod) ->
                    Method = ff_dmsl_codec:unmarshal(payment_method_ref, DmslMethod),
                    ff_codec:marshal(withdrawal_method, Method)
                end,
                DmslMethods
            ),
            {ok, ordsets:from_list(Methods)};
        {error, notfound} ->
            woody_error:raise(business, #fistful_IdentityNotFound{})
    end;
handle_function_('GetContext', {ID}, _Opts) ->
    case ff_identity_machine:get(ID, {undefined, 0}) of
        {ok, Machine} ->
            Ctx = ff_identity_machine:ctx(Machine),
            Response = ff_identity_codec:marshal(ctx, Ctx),
            {ok, Response};
        {error, notfound} ->
            woody_error:raise(business, #fistful_IdentityNotFound{})
    end;
handle_function_('GetEvents', {IdentityID, EventRange}, _Opts) ->
    case ff_identity_machine:events(IdentityID, ff_codec:unmarshal(event_range, EventRange)) of
        {ok, EventList} ->
            Events = [ff_identity_codec:marshal_identity_event(Event) || Event <- EventList],
            {ok, Events};
        {error, notfound} ->
            woody_error:raise(business, #fistful_IdentityNotFound{})
    end.

%% First argument of 'Create' is not a string, but a struct.
%% See fistful-proto/proto/identity.thrift
get_identity_id('Create', {#identity_IdentityParams{id = IdentityID}, _}) ->
    IdentityID;
get_identity_id(_Func, Args) ->
    element(1, Args).
