-module(hg_route).

-include_lib("hellgate/include/domain.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([new/6]).

-export([set_fd_overrides/2]).
-export([set_prohibit/2]).
-export([set_accepted/2]).
-export([set_weight/2]).
-export([set_blacklisted/2]).
-export([set_availability/3]).
-export([set_conversion/3]).
-export([set_priority/2]).

-export([route_data/1]).
-export([terminal_ref/1]).
-export([provider_ref/1]).
-export([priority/1]).
-export([weight/1]).
-export([pin/1]).
-export([pin_hash/1]).
-export([fd_overrides/1]).
-export([fd_score/1]).
-export([blacklisted/1]).
-export([rejection_reason/1]).
-export([set_rejection_reason/2]).

-export([score/1]).
-export([equal/2]).

-export([from_payment_route/2]).
-export([to_payment_route/1]).
-export([to_rejected_route/1]).

%%

-type revision() :: hg_domain:revision().
-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().
-type payment_route() :: dmsl_domain_thrift:'PaymentRoute'().

-type fd_overrides() :: dmsl_domain_thrift:'RouteFaultDetectorOverrides'().
-type route_rejection_reason() :: {atom(), term()} | {atom(), term(), term()}.
-type rejected_route() :: {provider_ref(), terminal_ref(), route_rejection_reason()}.

-type t() :: #{
    revision := revision(),
    provider_ref := dmsl_domain_thrift:'ProviderRef'(),
    terminal_ref := dmsl_domain_thrift:'TerminalRef'(),
    route_data := route_data(),
    pin_data => pin_data(),
    fd_overrides => fd_overrides(),
    rejection_reason => route_rejection_reason() | undefined
}.

-type fd_score() :: #{
    availability_condition => integer(),
    conversion_condition => integer(),
    availability => float(),
    conversion => float()
}.

-type route_prohibit() :: boolean() | {boolean(), _DescOrAttrs}.
-type route_accepted() :: boolean() | {boolean(), _DescOrAttrs}.
-type blacklist_condition() :: 0 | 1.

-type route_data() :: #{
    accepted => route_accepted(),
    prohibit => route_prohibit(),
    fd_score => fd_score(),
    priority => integer(),
    weight => integer(),
    pin_score => integer(),
    blacklisted => blacklist_condition()
}.

-type currency() :: dmsl_domain_thrift:'CurrencyRef'().
-type payment_tool() :: dmsl_domain_thrift:'PaymentTool'().
-type client_ip() :: dmsl_domain_thrift:'IPAddress'().
-type email() :: binary().
-type card_token() :: dmsl_domain_thrift:'Token'().

-type pin_data() :: #{
    currency => currency(),
    payment_tool => payment_tool(),
    client_ip => client_ip() | undefined,
    email => email() | undefined,
    card_token => card_token() | undefined
}.

-type score() :: #domain_PaymentRouteScores{}.

-export_type([t/0]).
-export_type([route_data/0]).
-export_type([provider_ref/0]).
-export_type([terminal_ref/0]).
-export_type([payment_route/0]).
-export_type([rejected_route/0]).
-export_type([score/0]).

%%

-spec new(revision(), provider_ref(), terminal_ref(), integer(), integer(), pin_data() | undefined) -> t().
new(Revision, ProviderRef, TerminalRef, Weight, Priority, Pin) ->
    #{
        revision => Revision,
        provider_ref => ProviderRef,
        terminal_ref => TerminalRef,
        route_data => #{
            accepted => true,
            prohibit => false,
            fd_score => #{
                availability_condition => 1,
                availability => 1.0,
                conversion_condition => 1,
                conversion => 1.0
            },
            weight => Weight,
            priority => Priority,
            blacklisted => 0
        },
        pin_data => Pin
    }.

-spec set_fd_overrides(fd_overrides(), t()) ->
    t().
set_fd_overrides(V, R) ->
    R#{fd_overrides => V}.

-spec set_prohibit(route_prohibit(), t()) ->
    t().
set_prohibit(V, #{route_data := Data} = R) ->
    R#{route_data => Data#{prohibit => V}}.

-spec set_accepted(route_accepted(), t()) ->
    t().
set_accepted(V, #{route_data := Data} = R) ->
    R#{route_data => Data#{accepted => V}}.

-spec set_weight(integer(), t()) -> t().
set_weight(Weight, #{route_data := Data} = R) ->
    R#{route_data => Data#{weight => Weight}}.

-spec set_blacklisted(boolean() | blacklist_condition(), t()) ->
    t().
set_blacklisted(true, R) ->
    set_blacklisted(1, R);
set_blacklisted(false, R) ->
    set_blacklisted(0, R);
set_blacklisted(V, #{route_data := Data} = R) ->
    R#{route_data => Data#{blacklisted => V}}.

-spec set_availability(integer(), float(), t()) ->
    t().
set_availability(C, V, #{route_data := Data = #{fd_score := Score}} = R) ->
    R#{route_data => Data#{fd_score => Score#{availability_condition => C, availability => V}}}.

-spec set_conversion(integer(), float(), t()) ->
    t().
set_conversion(C, V, #{route_data := Data = #{fd_score := Score}} = R) ->
    R#{route_data => Data#{fd_score => Score#{conversion_condition => C, conversion => V}}}.

-spec set_priority(integer(), t()) ->
    t().
set_priority(V, #{route_data := Data} = R) ->
    R#{route_data => Data#{priority => V}}.

-spec provider_ref(t()) -> provider_ref().
provider_ref(#{provider_ref := Ref}) ->
    Ref.

-spec route_data(t()) -> route_data().
route_data(#{route_data := V}) ->
    V.

-spec terminal_ref(t()) -> terminal_ref().
terminal_ref(#{terminal_ref := Ref}) ->
    Ref.

-spec priority(t()) -> integer().
priority(#{route_data := #{priority := Priority}}) ->
    Priority.

-spec weight(t()) -> integer().
weight(#{route_data := #{weight := Weight}}) ->
    Weight.

-spec pin(t()) -> pin_data() | undefined.
pin(#{pin_data := Pin}) ->
    Pin.

-spec pin_hash(t()) -> non_neg_integer().
pin_hash(#{pin_data := Pin}) when map_size(Pin) > 0 ->
    erlang:phash2(Pin);
pin_hash(_) ->
    0.

-spec fd_overrides(t()) -> fd_overrides().
fd_overrides(#{fd_overrides := FdOverrides}) ->
    FdOverrides.

-spec fd_score(t()) -> fd_score().
fd_score(#{route_data := #{fd_score := V}}) ->
    V;
fd_score(_) ->
    undefined.

-spec blacklisted(t()) ->
    blacklist_condition().
blacklisted(#{route_data := #{blacklisted := V}}) ->
    V;
blacklisted(_) ->
    0.

-spec rejection_reason(t()) ->
    route_rejection_reason().
rejection_reason(#{rejection_reason := V}) ->
    V;
rejection_reason(_) ->
    undefined.

-spec set_rejection_reason(route_rejection_reason(), t()) ->
    t().
set_rejection_reason(Reason, R) ->
    R#{rejection_reason => Reason}.

-spec score(t()) -> score().
score(R) ->
    #{
        availability_condition := AvailabilityCondition,
        conversion_condition := ConversionCondition,
        availability := Availability,
        conversion := Conversion
    } = fd_score(R),
    #domain_PaymentRouteScores{
        availability_condition = AvailabilityCondition,
        conversion_condition = ConversionCondition,
        terminal_priority_rating = priority(R),
        route_pin = pin_hash(R),
        random_condition = weight(R),
        availability = Availability,
        conversion = Conversion,
        blacklist_condition = blacklisted(R)
    }.

-spec equal(R, R) -> boolean() when
    R :: t() | payment_route() | rejected_route() | {provider_ref(), terminal_ref()}.
equal(A, B) ->
    routes_equal_(route_ref(A), route_ref(B)).

%%

routes_equal_(A, A) when A =/= undefined ->
    true;
routes_equal_(_A, _B) ->
    false.

route_ref(#{provider_ref := Prv, terminal_ref := Trm}) ->
    {Prv, Trm};
route_ref(#domain_PaymentRoute{provider = Prv, terminal = Trm}) ->
    {Prv, Trm};
route_ref({Prv, Trm, _Reason}) ->
    {Prv, Trm};
route_ref({Prv, Trm}) ->
    {Prv, Trm};
route_ref(_) ->
    undefined.

-spec from_payment_route(revision(), payment_route()) -> t().
from_payment_route(Revision, Route) ->
    ?route(ProviderRef, TerminalRef) = Route,
    new(Revision, ProviderRef, TerminalRef, 0, 1000, undefined).

-spec to_payment_route(t()) -> payment_route().
to_payment_route(Route) ->
    ?route(provider_ref(Route), terminal_ref(Route)).

-spec to_rejected_route(t()) -> rejected_route().
to_rejected_route(Route) ->
    {provider_ref(Route), terminal_ref(Route), rejection_reason(Route)}.

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
        fun(X) -> {provider_ref(X), terminal_ref(X)} end
    ],
    A = new(1, Prv1, Trm1, 1, 1, #{}),
    B = new(1, Prv2, Trm2, 1, 1, #{}),
    lists:flatten([[{F1(A), F2(B)} || F1 <- Fs] || F2 <- Fs]).

-endif.
