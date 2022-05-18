-module(hg_machine_action).

-export([new/0]).
-export([instant/0]).
-export([set_timeout/1]).
-export([set_timeout/2]).
-export([set_deadline/1]).
-export([set_deadline/2]).
-export([set_timer/1]).
-export([set_timer/2]).
-export([unset_timer/0]).
-export([unset_timer/1]).
-export([mark_removal/1]).

-include_lib("mg_proto/include/mg_proto_state_processing_thrift.hrl").

%%

-type seconds() :: non_neg_integer().
-type datetime_rfc3339() :: binary().
-type datetime() :: calendar:datetime() | datetime_rfc3339().

-type timer() :: mg_proto_base_thrift:'Timer'().
-type t() :: mg_proto_state_processing_thrift:'ComplexAction'().

-export_type([t/0]).

%%

-spec new() -> t().
new() ->
    #mg_stateproc_ComplexAction{}.

-spec instant() -> t().
instant() ->
    set_timeout(0, new()).

-spec set_timeout(seconds()) -> t().
set_timeout(Seconds) ->
    set_timeout(Seconds, new()).

-spec set_timeout(seconds(), t()) -> t().
set_timeout(Seconds, Action) when is_integer(Seconds) andalso Seconds >= 0 ->
    set_timer({timeout, Seconds}, Action).

-spec set_deadline(datetime()) -> t().
set_deadline(Deadline) ->
    set_deadline(Deadline, new()).

-spec set_deadline(datetime(), t()) -> t().
set_deadline(Deadline, Action) ->
    set_timer({deadline, try_format_dt(Deadline)}, Action).

-spec set_timer(timer()) -> t().
set_timer(Timer) ->
    set_timer(Timer, new()).

-spec set_timer(timer(), t()) -> t().
set_timer(Timer, Action = #mg_stateproc_ComplexAction{}) ->
    % TODO pass range and processing timeout explicitly too
    Action#mg_stateproc_ComplexAction{timer = {set_timer, #mg_stateproc_SetTimerAction{timer = Timer}}}.

-spec unset_timer() -> t().
unset_timer() ->
    unset_timer(new()).

-spec unset_timer(t()) -> t().
unset_timer(Action = #mg_stateproc_ComplexAction{}) ->
    Action#mg_stateproc_ComplexAction{timer = {unset_timer, #mg_stateproc_UnsetTimerAction{}}}.

-spec mark_removal(t()) -> t().
mark_removal(Action = #mg_stateproc_ComplexAction{}) ->
    Action#mg_stateproc_ComplexAction{remove = #mg_stateproc_RemoveAction{}}.

%%

try_format_dt(Datetime = {_, _}) ->
    Seconds = genlib_time:daytime_to_unixtime(Datetime),
    genlib_rfc3339:format(Seconds, second);
try_format_dt(Datetime) when is_binary(Datetime) ->
    Datetime.
