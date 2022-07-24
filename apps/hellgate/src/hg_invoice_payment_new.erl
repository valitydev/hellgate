-module(hg_invoice_payment_new).

-type create_params() ::
    dmsl_payproc_thrift:'InvoicePaymentParams'().

-behaviour(hg_submachine).

-export([make_submachine_desc/0]).
-export([create/1]).
-export([deduce_activity/1]).
-export([apply_event/2]).

-spec make_submachine_desc() -> hg_submachine:submachine_desc().
make_submachine_desc() ->
    Steps = [
        #{
            name => risk_scoring,
            action_or_submachine => #{handler => hg_invoice_payment_new, func => risk_scoring}
        },
        #{
            name => routing,
            action_or_submachine => #{handler => hg_invoice_payment_new, func => routing}
        },
        #{
            name => cash_flow,
            action_or_submachine => #{handler => hg_invoice_payment_new, func => build_cash_flow}
        },
        #{
            name => session,
            action_or_submachine => hg_invoice_payment_session:make_submachine_desc(),
            % on_event => [
            %     #{event_name => timeout, action_or_submachine => [#{handler => hg_action_session, func => timeout}]}
            %     #{event_name => callback, action_or_submachine => [#{handler => hg_action_session, func => callback}]}
            % ]
        },
        #{
            name => commit,
            action_or_submachine => #{handler => hg_invoice_payment_new, func => commit}
        },
        #{
            name => rollback,
            action_or_submachine => #{handler => hg_invoice_payment_new, func => rollback}
        },
        #{
            name => refund,
            action_or_submachine => hg_invoice_payment_refund:make_submachine_desc()
        },
        #{
            name => adjustment,
            action_or_submachine => hg_invoice_payment_adjustment:make_submachine_desc()
        },
        #{
            name => chargeback,
            action_or_submachine => hg_invoice_payment_chargeback:make_submachine_desc()
        }
    ],
    #{
        handler => hg_invoice_payment_new,
        steps => Steps
    }.


-spec create(create_params()) ->
    {ok, submachine()}
    | {error, create_error()}.
create(Params) ->
    #payproc_InvoicePaymentParams{
        payer = PayerParams,
        flow = FlowParams,
        payer_session_info = PayerSessionInfo,
        make_recurrent = MakeRecurrent,
        context = Context,
        external_id = ExternalID,
        processing_deadline = Deadline
    } = Params,
    Revision = hg_domain:head(),
    Party = get_party(Opts),
    Shop = get_shop(Opts),
    Invoice = get_invoice(Opts),
    Cost = get_invoice_cost(Invoice),
    {ok, Payer, VS0} = construct_payer(PayerParams, Shop),
    VS1 = collect_validation_varset(Party, Shop, VS0),
    Payment1 = construct_payment(
        PaymentID,
        CreatedAt,
        Cost,
        Payer,
        FlowParams,
        Party,
        Shop,
        VS1,
        Revision,
        genlib:define(MakeRecurrent, false)
    ),
    Payment2 = Payment1#domain_InvoicePayment{
        payer_session_info = PayerSessionInfo,
        context = Context,
        external_id = ExternalID,
        processing_deadline = Deadline
    },
    {ok, [?payment_started(Payment2)]}.

-spec deduce_activity(state()) -> activity().
deduce_activity(State, Desc = #{handler := Handler}) ->
    Params = #{
        p_transfer => p_transfer_status(State),
        status => status(State),
        limit_check => limit_check_status(State),
        active_adjustment => ff_adjustment_utils:is_active(adjustments_index(State))
    },
    do_deduce_activity(Params).

do_deduce_activity(#{status := pending, p_transfer := undefined}) ->
    p_transfer_start;
do_deduce_activity(#{status := pending, p_transfer := created}) ->
    p_transfer_prepare;
do_deduce_activity(#{status := pending, p_transfer := prepared, limit_check := unknown}) ->
    limit_check;
do_deduce_activity(#{status := pending, p_transfer := prepared, limit_check := ok}) ->
    p_transfer_commit;
do_deduce_activity(#{status := pending, p_transfer := committed, limit_check := ok}) ->
    finish;
do_deduce_activity(#{status := pending, p_transfer := prepared, limit_check := {failed, _}}) ->
    p_transfer_cancel;
do_deduce_activity(#{status := pending, p_transfer := cancelled, limit_check := {failed, _}}) ->
    {fail, limit_check};
do_deduce_activity(#{active_adjustment := true}) ->
    adjustment.

-spec apply_event_(event(), state() | undefined) -> state().
apply_event_({created, T}, undefined) ->
    T;
apply_event_({status_changed, S}, T) ->
    maps:put(status, S, T);
apply_event_({limit_check, Details}, T) ->
    add_limit_check(Details, T);
apply_event_({p_transfer, Ev}, T) ->
    T#{p_transfer => ff_postings_transfer:apply_event(Ev, p_transfer(T))};
apply_event_({adjustment, _Ev} = Event, T) ->
    apply_adjustment_event(Event, T).
