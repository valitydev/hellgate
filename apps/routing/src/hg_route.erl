-module(hg_route).

-include_lib("hellgate/include/domain.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([new/2]).
-export([new/4]).
-export([new/5]).
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
-export([payment_route/1]).
-export([priority/1]).
-export([weight/1]).
-export([pin/1]).
-export([pin_hash/1]).
-export([fd_overrides/1]).
-export([fd_score/1]).
-export([blacklisted/1]).

-export([score/1]).
-export([equal/2]).

-export([from_payment_route/1]).
-export([to_payment_route/1]).
-export([to_rejected_route/2]).

%%

-type t() :: #{
    provider_ref := provider_ref(),
    terminal_ref := terminal_ref(),
    route_data := route_data(),
    pin_data => pin(),
    fd_overrides => fd_overrides()
}.
-type payment_route() :: dmsl_domain_thrift:'PaymentRoute'().
-type score() :: dmsl_domain_thrift:'PaymentRouteScores'().
-type route_rejection_reason() :: {atom(), term()} | {atom(), term(), term()}.
-type rejected_route() :: {provider_ref(), terminal_ref(), route_rejection_reason()}.
-type provider_ref() :: dmsl_domain_thrift:'ProviderRef'().
-type terminal_ref() :: dmsl_domain_thrift:'TerminalRef'().
-type fd_overrides() :: dmsl_domain_thrift:'RouteFaultDetectorOverrides'().

-type fd_score() :: #{
    availability_condition => integer(),
    conversion_condition => integer(),
    availability => float(),
    conversion => float()
}.

-type route_prohibit() :: boolean() | {boolean(), term()}.
-type route_accepted() :: boolean() | {boolean(), term()}.

-type route_data() :: #{
    accepted => route_accepted(),
    prohibit => route_prohibit(),
    fd_score => fd_score(),
    priority => integer(),
    weight => integer(),
    blacklisted => integer()
}.

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
-export_type([score/0]).
-export_type([rejected_route/0]).
-export_type([route_data/0]).

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
    #{
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
        pin_data => Pin,
        fd_overrides => FdOverrides
    }.

-spec set_fd_overrides(fd_overrides(), t()) -> t().
set_fd_overrides(FdOverrides, Route) ->
    Route#{fd_overrides => FdOverrides}.

-spec set_prohibit(route_prohibit(), t()) -> t().
set_prohibit(Prohibit, #{route_data := Data} = Route) ->
    Route#{route_data => Data#{prohibit => Prohibit}}.

-spec set_accepted(route_accepted(), t()) -> t().
set_accepted(Accepted, #{route_data := Data} = Route) ->
    Route#{route_data => Data#{accepted => Accepted}}.

-spec set_weight(integer(), t()) -> t().
set_weight(Weight, #{route_data := Data} = Route) ->
    Route#{route_data => Data#{weight => Weight}}.

-spec set_blacklisted(boolean(), t()) -> t().
set_blacklisted(true, #{route_data := Data} = Route) ->
    Route#{route_data => Data#{blacklisted => 1}};
set_blacklisted(false, #{route_data := Data} = Route) ->
    Route#{route_data => Data#{blacklisted => 0}}.

-spec set_availability(integer(), float(), t()) -> t().
set_availability(Condition, Value, #{route_data := Data = #{fd_score := Score}} = Route) ->
    Route#{route_data => Data#{fd_score => Score#{availability_condition => Condition, availability => Value}}}.

-spec set_conversion(integer(), float(), t()) -> t().
set_conversion(Condition, Value, #{route_data := Data = #{fd_score := Score}} = Route) ->
    Route#{route_data => Data#{fd_score => Score#{conversion_condition => Condition, conversion => Value}}}.

-spec set_priority(integer(), t()) -> t().
set_priority(Priority, #{route_data := Data} = Route) ->
    Route#{route_data => Data#{priority => Priority}}.

-spec provider_ref(t()) -> provider_ref().
provider_ref(#{provider_ref := Ref}) ->
    Ref.

-spec route_data(t()) -> route_data().
route_data(#{route_data := Data}) ->
    Data.

-spec terminal_ref(t()) -> terminal_ref().
terminal_ref(#{terminal_ref := Ref}) ->
    Ref.

-spec payment_route(t()) -> payment_route().
payment_route(Route) ->
    to_payment_route(Route).

-spec priority(t()) -> integer().
priority(#{route_data := #{priority := Priority}}) ->
    Priority.

-spec weight(t()) -> integer().
weight(#{route_data := #{weight := Weight}}) ->
    Weight.

-spec pin(t()) -> pin() | undefined.
pin(#{pin_data := Pin}) ->
    Pin;
pin(_) ->
    #{}.

-spec pin_hash(t()) -> integer().
pin_hash(#{pin_data := Pin}) when map_size(Pin) > 0 ->
    erlang:phash2(Pin);
pin_hash(_) ->
    0.

-spec fd_overrides(t()) -> fd_overrides().
fd_overrides(#{fd_overrides := FdOverrides}) ->
    FdOverrides;
fd_overrides(_) ->
    #domain_RouteFaultDetectorOverrides{}.

-spec fd_score(t()) -> fd_score().
fd_score(#{route_data := #{fd_score := Score}}) ->
    Score;
fd_score(_) ->
    undefined.

-spec blacklisted(t()) -> integer().
blacklisted(#{route_data := #{blacklisted := Blacklisted}}) ->
    Blacklisted;
blacklisted(_) ->
    0.

-spec score(t()) -> score().
score(Route) ->
    #{
        availability_condition := AvailabilityCondition,
        conversion_condition := ConversionCondition,
        availability := Availability,
        conversion := Conversion
    } = fd_score(Route),
    #domain_PaymentRouteScores{
        availability_condition = AvailabilityCondition,
        conversion_condition = ConversionCondition,
        terminal_priority_rating = priority(Route),
        route_pin = pin_hash(Route),
        random_condition = weight(Route),
        availability = Availability,
        conversion = Conversion,
        blacklist_condition = blacklisted(Route)
    }.

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
to_payment_route(Route) ->
    ?route(provider_ref(Route), terminal_ref(Route)).

-spec to_rejected_route(t(), route_rejection_reason()) -> rejected_route().
to_rejected_route(Route, Reason) ->
    {provider_ref(Route), terminal_ref(Route), Reason}.

%%

routes_equal_(A, A) when A =/= undefined ->
    true;
routes_equal_(_A, _B) ->
    false.

route_ref(#{provider_ref := Prv, terminal_ref := Trm}) ->
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
