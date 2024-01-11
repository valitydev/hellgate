-module(hg_cascade).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_user_interaction_thrift.hrl").

-type trigger_status() :: triggered | not_triggered | negative_trigger.
-type cascade_behaviour() :: dmsl_domain_thrift:'CascadeBehaviour'().
-type operation_failure() :: dmsl_domain_thrift:'OperationFailure'().

-export([is_triggered/4]).

-spec is_triggered(
    cascade_behaviour() | undefined,
    operation_failure(),
    hg_route:payment_route(),
    [hg_session:t()]
) ->
    boolean().
is_triggered(undefined, _OperationFailure, Route, Sessions) ->
    handle_trigger_check(is_user_interaction_triggered_(Route, Sessions));
is_triggered(
    #domain_CascadeBehaviour{
        mapped_errors = MappedErrors,
        no_user_interaction = NoUI
    },
    OperationFailure,
    Route,
    Sessions
) ->
    TriggerStatuses = [
        is_mapped_errors_triggered(MappedErrors, OperationFailure),
        is_user_interaction_triggered(NoUI, Route, Sessions)
    ],
    handle_trigger_check(lists:foldl(fun trigger_reduction/2, not_triggered, TriggerStatuses)).

handle_trigger_check(triggered) ->
    true;
handle_trigger_check(not_triggered) ->
    false;
handle_trigger_check(negative_trigger) ->
    false.

is_user_interaction_triggered(undefined, _, _) ->
    not_triggered;
is_user_interaction_triggered(
    #domain_CascadeWhenNoUI{}, Route, Sessions
) ->
    is_user_interaction_triggered_(Route, Sessions).

is_user_interaction_triggered_(Route, Sessions) ->
    lists:foldl(
        fun(Session, Status) ->
            case Session of
                #{route := Route, interaction := Interaction} when Interaction =/= undefined ->
                    negative_trigger;
                _ ->
                    Status
            end
        end,
        triggered,
        Sessions
    ).

is_mapped_errors_triggered(undefined, _) ->
    not_triggered;
is_mapped_errors_triggered(#domain_CascadeOnMappedErrors{error_signatures = Signatures}, {failure, Failure}) ->
    case failure_matches_any_transient(Failure, ordsets:to_list(Signatures)) of
        true ->
            triggered;
        false ->
            negative_trigger
    end;
is_mapped_errors_triggered(#domain_CascadeOnMappedErrors{}, {operation_timeout, _}) ->
    negative_trigger.

failure_matches_any_transient(Failure, TransientErrorsList) ->
    lists:any(
        fun(ExpectNotation) ->
            payproc_errors:match_notation(Failure, fun
                (Notation) when binary_part(Notation, {0, byte_size(ExpectNotation)}) =:= ExpectNotation -> true;
                (_) -> false
            end)
        end,
        TransientErrorsList
    ).

-spec trigger_reduction(trigger_status(), trigger_status()) -> trigger_status().
trigger_reduction(_, negative_trigger) ->
    negative_trigger;
trigger_reduction(negative_trigger, _) ->
    negative_trigger;
trigger_reduction(triggered, _) ->
    triggered;
trigger_reduction(not_triggered, triggered) ->
    triggered;
trigger_reduction(not_triggered, not_triggered) ->
    not_triggered.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec failure_matches_any_transient_test_() -> [_].
failure_matches_any_transient_test_() ->
    TransientErrors = [
        %% 'preauthorization_failed' with all sub failure codes
        <<"preauthorization_failed">>,
        %% only 'rejected_by_inspector:*' sub failure codes
        <<"rejected_by_inspector:">>,
        %% 'authorization_failed:whatsgoingon' with sub failure codes
        <<"authorization_failed:whatsgoingon">>
    ],
    [
        %% Does match
        ?_assert(
            failure_matches_any_transient(
                #domain_Failure{code = <<"preauthorization_failed">>},
                TransientErrors
            )
        ),
        ?_assert(
            failure_matches_any_transient(
                #domain_Failure{code = <<"preauthorization_failed">>, sub = #domain_SubFailure{code = <<"unknown">>}},
                TransientErrors
            )
        ),
        ?_assert(
            failure_matches_any_transient(
                #domain_Failure{code = <<"rejected_by_inspector">>, sub = #domain_SubFailure{code = <<"whatever">>}},
                TransientErrors
            )
        ),
        ?_assert(
            failure_matches_any_transient(
                #domain_Failure{code = <<"authorization_failed">>, sub = #domain_SubFailure{code = <<"whatsgoingon">>}},
                TransientErrors
            )
        ),
        %% Does NOT match
        ?_assertNot(
            failure_matches_any_transient(
                #domain_Failure{code = <<"no_route_found">>},
                TransientErrors
            )
        ),
        ?_assertNot(
            failure_matches_any_transient(
                #domain_Failure{code = <<"no_route_found">>, sub = #domain_SubFailure{code = <<"unknown">>}},
                TransientErrors
            )
        ),
        ?_assertNot(
            failure_matches_any_transient(
                #domain_Failure{code = <<"rejected_by_inspector">>},
                TransientErrors
            )
        ),
        ?_assertNot(
            failure_matches_any_transient(
                #domain_Failure{code = <<"authorization_failed">>, sub = #domain_SubFailure{code = <<"unknown">>}},
                TransientErrors
            )
        )
    ].

-endif.
