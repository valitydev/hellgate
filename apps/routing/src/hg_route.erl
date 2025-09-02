-module(hg_route).

-include_lib("hellgate/include/domain.hrl").

-export([new/2]).
-export([new/4]).
-export([new/5]).
-export([new/6]).
-export([provider_ref/1]).
-export([terminal_ref/1]).
-export([priority/1]).
-export([weight/1]).
-export([set_weight/2]).
-export([pin/1]).
-export([fd_overrides/1]).

-export([equal/2]).

-export([from_payment_route/1]).
-export([to_payment_route/1]).
-export([to_rejected_route/2]).

%%

-record(route, {
    provider_ref :: dmsl_domain_thrift:'ProviderRef'(),
    terminal_ref :: dmsl_domain_thrift:'TerminalRef'(),
    priority :: integer(),
    pin :: pin(),
    weight :: integer(),
    fd_overrides :: fd_overrides()
}).

-type t() :: #route{}.
-type payment_route() :: dmsl_domain_thrift:'PaymentRoute'().
-type route_rejection_reason() :: {atom(), term()} | {atom(), term(), term()}.
-type rejected_route() :: {provider_ref(), terminal_ref(), route_rejection_reason()}.
-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().
-type fd_overrides() :: dmsl_domain_thrift:'RouteFaultDetectorOverrides'().

-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type client_ip() :: dmsl_domain_thrift:'IPAddress'().
-type email() :: binary().
-type card_token() :: dmsl_domain_thrift:'Token'().

-type pin() :: #{
    currency => currency(),
    payment_tool => payment_tool(),
    client_ip => client_ip() | undefined,
    email => email() | undefined,
    card_token => card_token() | undefined
}.

-export_type([t/0]).
-export_type([provider_ref/0]).
-export_type([terminal_ref/0]).
-export_type([payment_route/0]).
-export_type([rejected_route/0]).

%%

-spec new(provider_ref(), terminal_ref()) -> t().
new(ProviderRef, TerminalRef) ->
    new(
        ProviderRef,
        TerminalRef,
        ?DOMAIN_CANDIDATE_WEIGHT,
        ?DOMAIN_CANDIDATE_PRIORITY
    ).

-spec new(provider_ref(), terminal_ref(), integer() | undefined, integer()) -> t().
new(ProviderRef, TerminalRef, Weight, Priority) ->
    new(ProviderRef, TerminalRef, Weight, Priority, #{}).

-spec new(provider_ref(), terminal_ref(), integer() | undefined, integer(), pin()) -> t().
new(ProviderRef, TerminalRef, undefined, Priority, Pin) ->
    new(ProviderRef, TerminalRef, ?DOMAIN_CANDIDATE_WEIGHT, Priority, Pin);
new(ProviderRef, TerminalRef, Weight, Priority, Pin) ->
    new(ProviderRef, TerminalRef, Weight, Priority, Pin, #domain_RouteFaultDetectorOverrides{}).

-spec new(provider_ref(), terminal_ref(), integer(), integer(), pin(), fd_overrides()) -> t().
new(ProviderRef, TerminalRef, Weight, Priority, Pin, FdOverrides) ->
    #route{
        provider_ref = ProviderRef,
        terminal_ref = TerminalRef,
        weight = Weight,
        priority = Priority,
        pin = Pin,
        fd_overrides = FdOverrides
    }.

-spec provider_ref(t()) -> provider_ref().
provider_ref(#route{provider_ref = Ref}) ->
    Ref.

-spec terminal_ref(t()) -> terminal_ref().
terminal_ref(#route{terminal_ref = Ref}) ->
    Ref.

-spec priority(t()) -> integer().
priority(#route{priority = Priority}) ->
    Priority.

-spec weight(t()) -> integer().
weight(#route{weight = Weight}) ->
    Weight.

-spec pin(t()) -> pin() | undefined.
pin(#route{pin = Pin}) ->
    Pin.

-spec fd_overrides(t()) -> fd_overrides().
fd_overrides(#route{fd_overrides = FdOverrides}) ->
    FdOverrides.

-spec set_weight(integer(), t()) -> t().
set_weight(Weight, Route) ->
    Route#route{weight = Weight}.

-spec equal(R, R) -> boolean() when
    R :: t() | rejected_route() | payment_route() | {provider_ref(), terminal_ref()}.
equal(A, B) ->
    routes_equal_(route_ref(A), route_ref(B)).

%%

-spec from_payment_route(payment_route()) -> t().
from_payment_route(Route) ->
    ?route(ProviderRef, TerminalRef) = Route,
    new(ProviderRef, TerminalRef).

-spec to_payment_route(t()) -> payment_route().
to_payment_route(#route{} = Route) ->
    ?route(provider_ref(Route), terminal_ref(Route)).

-spec to_rejected_route(t(), route_rejection_reason()) -> rejected_route().
to_rejected_route(Route, Reason) ->
    {provider_ref(Route), terminal_ref(Route), Reason}.

%%

routes_equal_(A, A) when A =/= undefined ->
    true;
routes_equal_(_A, _B) ->
    false.

route_ref(#route{provider_ref = Prv, terminal_ref = Trm}) ->
    {Prv, Trm};
route_ref(#domain_PaymentRoute{provider = Prv, terminal = Trm}) ->
    {Prv, Trm};
route_ref({Prv, Trm}) ->
    {Prv, Trm};
route_ref({Prv, Trm, _RejectionReason}) ->
    {Prv, Trm};
route_ref(_) ->
    undefined.

%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(prv(ID), #domain_ProviderRef{id = ID}).
-define(trm(ID), #domain_TerminalRef{id = ID}).

-spec test() -> _.

-spec routes_equality_test_() -> [_].
routes_equality_test_() ->
    lists:flatten([
        [?_assert(equal(A, B)) || {A, B} <- route_pairs({?prv(1), ?trm(1)}, {?prv(1), ?trm(1)})],
        [?_assertNot(equal(A, B)) || {A, B} <- route_pairs({?prv(1), ?trm(1)}, {?prv(1), ?trm(2)})],
        [?_assertNot(equal(A, B)) || {A, B} <- route_pairs({?prv(1), ?trm(1)}, {?prv(2), ?trm(1)})],
        [?_assertNot(equal(A, B)) || {A, B} <- route_pairs({?prv(1), ?trm(1)}, {?prv(2), ?trm(2)})]
    ]).

route_pairs({Prv1, Trm1}, {Prv2, Trm2}) ->
    Fs = [
        fun(X) -> X end,
        fun to_payment_route/1,
        fun(X) -> to_rejected_route(X, {test, <<"whatever">>}) end,
        fun(X) -> {provider_ref(X), terminal_ref(X)} end
    ],
    A = new(Prv1, Trm1),
    B = new(Prv2, Trm2),
    lists:flatten([[{F1(A), F2(B)} || F1 <- Fs] || F2 <- Fs]).

-endif.
