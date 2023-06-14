-module(ff_woody_event_handler).

-behaviour(woody_event_handler).

%% woody_event_handler behaviour callbacks
-export([handle_event/4]).

-spec handle_event(Event, RpcId, Meta, Opts) -> ok when
    Event :: woody_event_handler:event(),
    RpcId :: woody:rpc_id() | undefined,
    Meta :: woody_event_handler:event_meta(),
    Opts :: woody:options().
handle_event(Event, RpcID, RawMeta, Opts) ->
    FilteredMeta = filter_meta(RawMeta),
    scoper_woody_event_handler:handle_event(Event, RpcID, FilteredMeta, Opts).

filter_meta(RawMeta) ->
    maps:map(fun do_filter_meta/2, RawMeta).

do_filter_meta(args, Args) ->
    filter(Args);
do_filter_meta(_Key, Value) ->
    Value.

%% common
filter(L) when is_list(L) ->
    [filter(E) || E <- L];
filter(T) when is_tuple(T) ->
    list_to_tuple(filter(tuple_to_list(T)));
filter(M) when is_map(M) ->
    genlib_map:truemap(fun(K, V) -> {filter(K), filter(V)} end, maps:without([<<"api-key">>, <<"secret-key">>], M));
%% default
filter(V) ->
    V.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(ARG1, {
    wthd_provider_Withdrawal,
    <<"1686225855930826">>,
    <<"1686225855930826/1">>,
    {wthd_provider_Cash, 4240, {domain_Currency, <<"Russian Ruble">>, <<"RUB">>, 643, 2}},
    {bank_card,
        {domain_BankCard, <<"4150399999000900">>, {domain_PaymentSystemRef, <<"VISA">>}, <<"415039">>,
            <<"****************">>, undefined, undefined, rus, undefined, undefined, undefined,
            {domain_BankCardExpDate, 12, 2025}, <<"ct_cardholder_name">>, undefined}},
    undefined,
    {wthd_domain_Identity, <<"gj9Cn2gOglBQ0aso4jcsiEc38tS">>, undefined, [], [{phone_number, <<"9876543210">>}]},
    {wthd_domain_Identity, <<"gj9Cn2gOglBQ0aso4jcsiEc38tS">>, undefined, [], [{phone_number, <<"9876543210">>}]},
    undefined
}).

-spec test() -> _.

-spec filter_secrets_from_opts_test_() -> _.
filter_secrets_from_opts_test_() ->
    [
        ?_assertEqual(
            #{
                args => {?ARG1, {nl, {msgpack_nil}}, #{}},
                role => client,
                service => 'Adapter'
            },
            filter_meta(
                #{
                    args => {
                        ?ARG1,
                        {nl, {msgpack_nil}},
                        #{<<"api-key">> => <<"secret">>, <<"secret-key">> => <<"secret">>}
                    },
                    role => client,
                    service => 'Adapter'
                }
            )
        )
    ].

-endif.
