-module(hg_invoice_payment_session).

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
            action_or_submachine => #{handler => hg_invoice_payment_session, func => process}
        },
        #{
            name => active,
            action_or_submachine => #{handler => hg_invoice_payment_session, func => finish}
        },
        #{
            name => suspended,
            action_or_submachine => #{handler => hg_invoice_payment_session, func => timeout},
            on_event => [
                #{event_name => callback, action_or_submachine => #{handler => hg_invoice_payment_session, func => callback}}
            ]
        }
    ],
    #{
        handler => hg_invoice_payment_session,
        steps => Steps
    }.
