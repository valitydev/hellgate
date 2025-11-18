%%%
%%% Copyright 2020 RBKmoney
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%

-module(ff_withdrawal_route_attempt_utils).

-export([new/0]).
-export([new_route/2]).
-export([next_route/3]).
-export([next_routes/3]).
-export([get_index/1]).
-export([get_current_session/1]).
-export([get_current_p_transfer/1]).
-export([get_current_p_transfer_status/1]).
-export([get_current_limit_checks/1]).
-export([update_current_session/2]).
-export([update_current_p_transfer/2]).
-export([update_current_limit_checks/2]).

-export([get_sessions/1]).
-export([get_attempt/1]).
-export([get_terminals/1]).
-export([get_current_terminal/1]).

-opaque attempts() :: #{
    attempts := #{route_key() => attempt()},
    inversed_routes := [route_key()],
    attempt := non_neg_integer(),
    current => route_key(),
    index := index()
}.

-type index() :: non_neg_integer().
-define(DEFAULT_INDEX, 1).

-export_type([attempts/0]).

%% Iternal types

-type p_transfer() :: ff_postings_transfer:transfer().
-type p_transfer_status() :: ff_postings_transfer:status().
-type limit_check_details() :: ff_withdrawal:limit_check_details().
-type route() :: ff_withdrawal_routing:route().
-type route_key() :: {ff_payouts_provider:id(), ff_payouts_terminal:id()} | unknown.
-type session() :: ff_withdrawal:session().
-type attempt_limit() :: ff_party:attempt_limit().

-type attempt() :: #{
    session => session(),
    p_transfer => p_transfer(),
    limit_checks => [limit_check_details()]
}.

%% API

-spec new() -> attempts().
new() ->
    #{
        attempts => #{},
        inversed_routes => [],
        attempt => 0,
        index => ?DEFAULT_INDEX
    }.

-spec new_route(route(), attempts()) -> attempts().
new_route(Route, undefined) ->
    new_route(Route, new());
new_route(Route, Existing) ->
    RouteKey = route_key(Route),
    add_route(RouteKey, Existing).

-spec next_route([route()], attempts(), attempt_limit()) ->
    {ok, route()} | {error, route_not_found | attempt_limit_exceeded}.
next_route(Routes, Attempts, AttemptLimit) ->
    case next_routes(Routes, Attempts, AttemptLimit) of
        {ok, [Route | _]} ->
            {ok, Route};
        {ok, []} ->
            {error, route_not_found};
        {error, Reason} ->
            {error, Reason}
    end.

-spec next_routes([route()], attempts(), attempt_limit()) ->
    {ok, [route()]} | {error, attempt_limit_exceeded}.
next_routes(_Routes, #{attempt := Attempt}, AttemptLimit) when
    is_integer(AttemptLimit) andalso Attempt == AttemptLimit
->
    {error, attempt_limit_exceeded};
next_routes(Routes, #{attempts := Existing}, _AttemptLimit) ->
    {ok,
        lists:filter(
            fun(R) ->
                not maps:is_key(route_key(R), Existing)
            end,
            Routes
        )}.

-spec get_index(attempts() | undefined) -> index().
get_index(undefined) ->
    ?DEFAULT_INDEX;
get_index(#{index := Index}) ->
    Index.

-spec get_current_session(attempts()) -> undefined | session().
get_current_session(Attempts) ->
    Attempt = current(Attempts),
    maps:get(session, Attempt, undefined).

-spec get_current_p_transfer(attempts()) -> undefined | p_transfer().
get_current_p_transfer(Attempts) ->
    Attempt = current(Attempts),
    maps:get(p_transfer, Attempt, undefined).

-spec get_current_p_transfer_status(attempts()) -> undefined | p_transfer_status().
get_current_p_transfer_status(Attempts) ->
    Attempt = current(Attempts),
    maps:get(status, maps:get(p_transfer, Attempt, #{}), undefined).

-spec get_current_limit_checks(attempts()) -> undefined | [limit_check_details()].
get_current_limit_checks(Attempts) ->
    Attempt = current(Attempts),
    maps:get(limit_checks, Attempt, undefined).

-spec update_current_session(session(), attempts()) -> attempts().
update_current_session(Session, Attempts) ->
    Attempt = current(Attempts),
    Updated = Attempt#{
        session => Session
    },
    update_current(Updated, Attempts).

-spec update_current_p_transfer(p_transfer(), attempts()) -> attempts().
update_current_p_transfer(PTransfer, #{index := Index} = Attempts) ->
    Attempt = current(Attempts),
    Updated = Attempt#{
        p_transfer => PTransfer
    },
    NewIndex =
        case maps:get(status, PTransfer, undefined) of
            committed -> Index + 1;
            cancelled -> Index + 1;
            _ -> Index
        end,
    update_current(Updated, Attempts#{index => NewIndex}).

-spec update_current_limit_checks([limit_check_details()], attempts()) -> attempts().
update_current_limit_checks(LimitChecks, Routes) ->
    Attempt = current(Routes),
    Updated = Attempt#{
        limit_checks => LimitChecks
    },
    update_current(Updated, Routes).

-spec get_sessions(attempts()) -> [session()].
get_sessions(undefined) ->
    [];
get_sessions(#{attempts := Attempts, inversed_routes := InvRoutes}) ->
    lists:foldl(
        fun(ID, Acc) ->
            Route = maps:get(ID, Attempts),
            case maps:get(session, Route, undefined) of
                undefined ->
                    Acc;
                Session ->
                    [Session | Acc]
            end
        end,
        [],
        InvRoutes
    ).

-spec get_attempt(attempts()) -> non_neg_integer().
get_attempt(#{attempt := Attempt}) ->
    Attempt.

-spec get_terminals(attempts()) -> [ff_payouts_terminal:id()].
get_terminals(#{attempts := Attempts}) ->
    lists:map(fun({_, TerminalID}) -> TerminalID end, maps:keys(Attempts));
get_terminals(_) ->
    [].

-spec get_current_terminal(attempts()) -> undefined | ff_payouts_terminal:id().
get_current_terminal(#{current := {_, TerminalID}}) ->
    TerminalID;
get_current_terminal(_) ->
    undefined.

%% Internal

-spec route_key(route()) -> route_key().
route_key(Route) ->
    {ff_withdrawal_routing:get_provider(Route), ff_withdrawal_routing:get_terminal(Route)}.

-spec add_route(route_key(), attempts()) -> attempts().
add_route(RouteKey, R) ->
    #{
        attempts := Attempts,
        inversed_routes := InvRoutes,
        attempt := Attempt
    } = R,
    R#{
        current => RouteKey,
        attempt => Attempt + 1,
        inversed_routes => [RouteKey | InvRoutes],
        attempts => Attempts#{RouteKey => #{}}
    }.

%% @private
current(#{current := Route, attempts := Attempts}) ->
    maps:get(Route, Attempts);
current(_) ->
    #{}.

%% @private
update_current(Attempt, #{current := Route, attempts := Attempts} = R) ->
    R#{
        attempts => Attempts#{
            Route => Attempt
        }
    }.
