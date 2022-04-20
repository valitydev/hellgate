-module(hg_cash).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-include("domain.hrl").

-export([add/2]).
-export([sub/2]).

-type cash() :: dmsl_domain_thrift:'Cash'().

%% Simple arithmetics

-spec add(cash(), cash()) -> cash().
add(?cash(Amount1, Curr), ?cash(Amount2, Curr)) ->
    ?cash(Amount1 + Amount2, Curr);
add(_, _) ->
    error(badarg).

-spec sub(cash(), cash()) -> cash().
sub(?cash(Amount1, Curr), ?cash(Amount2, Curr)) ->
    ?cash(Amount1 - Amount2, Curr);
sub(_, _) ->
    error(badarg).
