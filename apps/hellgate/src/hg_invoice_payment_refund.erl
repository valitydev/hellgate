-module(hg_invoice_payment_refund).

-behaviour(hg_submachine).

-export([make_submachine_desc/0]).
-export([create/1]).
-export([deduce_activity/1]).
-export([apply_event/2]).

%%

-spec make_submachine_desc() -> hg_submachine:submachine_desc().
make_submachine_desc() ->
    Steps = [
        #{
            name => new,
            action_or_submachine => #{handler => hg_invoice_payment_refund, func => hold}
        },
        #{
            name => session,
            action_or_submachine => hg_invoice_payment_session:make_submachine_desc()
        },
        #{
            name => commit,
            action_or_submachine => #{handler => hg_invoice_payment_refund, func => commit}
        },
        #{
            name => rollback,
            action_or_submachine => #{handler => hg_invoice_payment_refund, func => rollback}
        }
    ],
    #{
        handler => hg_invoice_payment_refund,
        steps => Steps
    }.

-spec create(create_params()) ->
    {ok, submachine()}
    | {error, create_error()}.
create(Params = #{state := GlobalState, target := Target}) ->
    case validate_processing_deadline(GlobalState) of
        ok ->
            {next, {[?session_ev(Target, ?session_started())], hg_machine_action:instant()}};
        Failure ->
            {next, {[], hg_machine_action:instant()}}
    end.
