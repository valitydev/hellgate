-module(ff_claim_committer_handler).

-include_lib("damsel/include/dmsl_claimmgmt_thrift.hrl").

-behaviour(ff_woody_wrapper).

-export([handle_function/3]).

-spec handle_function(woody:func(), woody:args(), woody:options()) -> {ok, woody:result()} | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(
        claims,
        #{},
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

handle_function_('Accept', {PartyID, #claimmgmt_Claim{changeset = Changeset}}, _Opts) ->
    ok = scoper:add_meta(#{party_id => PartyID}),
    Modifications = ff_claim_committer:filter_ff_modifications(Changeset),
    ok = ff_claim_committer:assert_modifications_applicable(Modifications),
    {ok, ok};
handle_function_('Commit', {PartyID, Claim}, _Opts) ->
    #claimmgmt_Claim{
        id = ID,
        changeset = Changeset
    } = Claim,
    ok = scoper:add_meta(#{party_id => PartyID, claim_id => ID}),
    Modifications = ff_claim_committer:filter_ff_modifications(Changeset),
    ff_claim_committer:apply_modifications(Modifications),
    {ok, ok}.
