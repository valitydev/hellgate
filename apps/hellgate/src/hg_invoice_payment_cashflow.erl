-module(hg_invoice_payment_cashflow).

-export([create/2]).

-behaviour(hg_state).

-export([make_statem_desc/0]).

-type global_state() :: hg_invoice_payment:st().

-type cashflow() :: #{
    status := session_status(),
    cash_flow => final_cash_flow()
}.

-spec create(target(), global_state()) -> machine_result().
create(Target, GlobalState) ->
    case validate_processing_deadline(GlobalState) of
        ok ->
            {next, {[?session_ev(Target, ?session_started())], hg_machine_action:set_timeout(0, Action)}};
        Failure ->
            {next, {[], hg_machine_action:set_timeout(0, Action)}}
    end.

-spec make_statem_desc() -> hg_state:statem_desc().
make_statem_desc() ->
    ActiveState = hg_state:create_state_desc(#{
        name => created,
        in_state => fun(#{events := Events}) -> check_status(created, collapse_events(Events)) end,
        update => fun(#{events := Events}) -> process_active_session(collapse_events(Events)) end
    }),
    SuspendedState = hg_state:create_state_desc(#{
        name => suspended,
        in_state => fun(#{events := Events}) -> check_status(suspended, collapse_events(Events)) end,
        update => fun(#{events := Events}) -> process_callback_timeout(collapse_events(Events)) end,
        on_event => #{
            name => callback,
            handle => fun(Args, #{events := Events}) -> handle_callback(Args, collapse_events(Events)) end
        }
    }),

    hg_state:add_state(SuspendedState, hg_state:add_state(ActiveState, hg_state:new_desc(?MODULE))).

%% Some examples function implementetion from invoice payment without deps

-spec process_active_session(session()) -> machine_result().
process_active_session(Session) ->
    {ok, ProxyResult} = process_payment_session(St),
    Result = handle_proxy_result(ProxyResult, Action, Events, Session, create_session_context(St)),
    finish_session_processing(Result, St).

-spec process_callback_timeout(action(), session(), events(), st()) -> machine_result().
process_callback_timeout(Session) ->
    case get_session_timeout_behaviour(Session) of
        {callback, Payload} ->
            {ok, CallbackResult} = process_payment_session_callback(Payload, St),
            {_Response, Result} = handle_callback_result(
                CallbackResult, Action, get_activity_session(St), create_session_context(St)
            ),
            finish_session_processing(Result, St);
        {operation_failure, OperationFailure} ->
            SessionEvents = [?session_finished(?session_failed(OperationFailure))],
            Result = {Events ++ wrap_session_events(SessionEvents, Session), Action},
            finish_session_processing(Result, St)
    end.

handle_callback(Payload, St) ->
    {ok, CallbackResult} = process_payment_session_callback(Payload, St),
    {Response, Result} = handle_callback_result(
        CallbackResult, Action, get_activity_session(St), create_session_context(St)
    ),
    {Response, finish_session_processing(Result, St)}.

finish_session_processing({Events, Action}, St) ->
    St1 = collapse_events(Events, St),
    case get_refund_session(RefundSt1) of
        #{status := finished, result := ?session_succeeded()} ->
            NewAction = hg_machine_action:set_timeout(0, Action),
            {next, {Events, NewAction}};
        #{status := finished, result := ?session_failed(Failure)} ->
            {next, {Events, hg_machine_action:set_timeout(0, Action)}}
        #{} ->
            {next, {Events, Action}}
    end.

%%

check_status(Status, #{status := Status}) ->
    true;
check_status(_Status, _) ->
    false.

collapse_events(Events) ->
    list:foldl(fun collapse_event/2, undefined, Events).

collapse_event(?session_ev(Target, ?session_started()), undefined) ->
    create_session(Target, undefined).

create_session(Target, Trx) ->
    #{
        target => Target,
        status => active,
        trx => Trx,
        tags => [],
        timeout_behaviour => {operation_failure, ?operation_timeout()}
    }.
