-module(hg_dummy_provider).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_error_thrift.hrl").
-include_lib("damsel/include/dmsl_user_interaction_thrift.hrl").

-behaviour(hg_woody_service_wrapper).

-export([handle_function/3]).

-behaviour(hg_test_proxy).

-export([get_service_spec/0]).
-export([get_http_cowboy_spec/0]).

-export([get_callback_url/0]).
-export([construct_silent_callback/1]).

-export([make_payment_tool/2]).

%% cowboy http callbacks
-export([init/2]).
-export([terminate/3]).

-export_type([payment_tool/0]).

%%

-define(COWBOY_PORT, 9988).

-define(redirect(Uri, Form),
    {redirect, {post_request, #user_interaction_BrowserPostRequest{uri = Uri, form = Form}}}
).

-define(completed, #user_interaction_Completed{}).

-define(sleep(To),
    ?sleep(To, undefined)
).

-define(sleep(To, UI),
    ?sleep(To, UI, undefined)
).

-define(sleep(To, UI, UICompleted),
    {sleep, #proxy_provider_SleepIntent{
        timer = {timeout, To},
        user_interaction = UI,
        user_interaction_completion = UICompleted
    }}
).

-define(suspend(Tag, To),
    ?suspend(Tag, To, undefined)
).

-define(suspend(Tag, To, UI),
    ?suspend(Tag, To, UI, undefined)
).

-define(suspend(Tag, To, UI, TimeoutBehaviour),
    {suspend, #proxy_provider_SuspendIntent{
        tag = Tag,
        timeout = {timeout, To},
        user_interaction = UI,
        timeout_behaviour = TimeoutBehaviour
    }}
).

-define(finish(Status),
    {finish, #proxy_provider_FinishIntent{status = Status}}
).

-define(success(Token),
    {success, #proxy_provider_Success{token = Token}}
).

-define(recurrent_token_finish(Token),
    {finish, #proxy_provider_RecurrentTokenFinishIntent{
        status = {success, #proxy_provider_RecurrentTokenSuccess{token = Token}}
    }}
).

-define(recurrent_token_finish_w_failure(Failure),
    {finish, #proxy_provider_RecurrentTokenFinishIntent{
        status = {failure, Failure}
    }}
).

-define(DEFAULT_SESSION(PaymentTool), {PaymentTool, <<"">>}).
-define(SESSION42(PaymentTool), {PaymentTool, <<"SESSION42">>}).

-spec get_service_spec() -> hg_proto:service_spec().
get_service_spec() ->
    {"/test/proxy/provider/dummy", {dmsl_proxy_provider_thrift, 'ProviderProxy'}}.

-spec get_http_cowboy_spec() -> map().
get_http_cowboy_spec() ->
    Dispatch = cowboy_router:compile([{'_', [{"/", ?MODULE, []}]}]),
    #{
        listener_ref => ?MODULE,
        acceptors_count => 10,
        transport_opts => [{port, ?COWBOY_PORT}],
        proto_opts => #{env => #{dispatch => Dispatch}}
    }.

%%

-define(LAY_LOW_BUDDY, <<"lay low buddy">>).

-define(REC_TOKEN, <<"rec_token">>).

-type form() :: #{binary() => binary() | true}.

-spec construct_silent_callback(form()) -> form().
construct_silent_callback(Form) ->
    Form#{<<"payload">> => ?LAY_LOW_BUDDY}.

-type failure_scenario_step() :: good | temp | fail | error.
-type failure_scenario() :: [failure_scenario_step()].

%%

-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("hellgate/include/payment_events.hrl").

-spec handle_function(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function(
    'GenerateToken',
    {#proxy_provider_RecurrentTokenContext{
        session = #proxy_provider_RecurrentTokenSession{state = State},
        token_info = TokenInfo,
        options = _
    }},
    Opts
) ->
    generate_token(State, TokenInfo, Opts);
handle_function(
    'HandleRecurrentTokenCallback',
    {Payload, #proxy_provider_RecurrentTokenContext{
        session = #proxy_provider_RecurrentTokenSession{state = State},
        token_info = TokenInfo,
        options = _
    }},
    Opts
) ->
    handle_token_callback(Payload, State, TokenInfo, Opts);
handle_function(
    'ProcessPayment',
    {#proxy_provider_PaymentContext{
        session = #proxy_provider_Session{target = ?refunded(), state = State},
        payment_info = PaymentInfo,
        options = _
    }},
    Opts
) ->
    process_refund(State, PaymentInfo, Opts);
handle_function(
    'ProcessPayment',
    {#proxy_provider_PaymentContext{
        session = #proxy_provider_Session{target = Target, state = State},
        payment_info = PaymentInfo,
        options = Ctx
    }},
    Opts
) ->
    process_payment(Target, State, PaymentInfo, Ctx, Opts);
handle_function(
    'HandlePaymentCallback',
    {Payload, #proxy_provider_PaymentContext{
        session = #proxy_provider_Session{target = Target, state = State},
        payment_info = PaymentInfo,
        options = _
    }},
    Opts
) ->
    handle_payment_callback(Payload, Target, State, PaymentInfo, Opts).

%
% Recurrent tokens
%

generate_token(undefined, #proxy_provider_RecurrentTokenInfo{payment_tool = RecurrentPaytool}, _Opts) ->
    case get_recurrent_paytool_scenario(RecurrentPaytool) of
        forbidden ->
            #proxy_provider_RecurrentTokenProxyResult{
                intent = ?recurrent_token_finish_w_failure(#domain_Failure{code = <<"forbidden">>})
            };
        unexpected_failure ->
            error(unexpected_failure);
        _ ->
            token_result(?sleep(0), <<"sleeping">>)
    end;
generate_token(<<"sleeping">>, #proxy_provider_RecurrentTokenInfo{payment_tool = RecurrentPaytool}, _Opts) ->
    case get_recurrent_paytool_scenario(RecurrentPaytool) of
        {preauth_3ds, Timeout} ->
            Tag = generate_tag(<<"recurrent">>),
            Uri = get_callback_url(),
            UserInteraction = ?redirect(Uri, #{<<"tag">> => Tag}),
            token_result(?suspend(Tag, Timeout, UserInteraction), <<"suspended">>);
        {preauth_3ds_sleep, Timeout} ->
            Tag = generate_tag(<<"recurrent-sleep">>),
            Uri = get_callback_url(),
            UserInteraction = ?redirect(Uri, #{<<"tag">> => Tag}),
            token_result(?suspend(Tag, Timeout, UserInteraction), <<"suspended">>);
        no_preauth_timeout ->
            Tag = generate_tag(<<"recurrent-suspend-timeout">>),
            Callback = {callback, Tag},
            token_result(?suspend(Tag, 1, undefined, Callback), <<"suspended">>);
        no_preauth_timeout_failure ->
            Tag = generate_tag(<<"recurrent-suspend-timeout-failure">>),
            Failure = {operation_failure, failure(preauthorization_failed)},
            token_result(?suspend(Tag, 1, undefined, Failure), <<"suspended">>);
        no_preauth_suspend_default ->
            Tag = generate_tag(<<"recurrent-suspend-timeout-default">>),
            token_result(?suspend(Tag, 1), <<"suspended">>);
        no_preauth ->
            token_result(?sleep(0), <<"finishing">>)
    end;
generate_token(<<"finishing">>, TokenInfo, _Opts) ->
    Token = ?REC_TOKEN,
    token_finish(TokenInfo, Token).

handle_token_callback(<<"recurrent-sleep-", _/binary>>, <<"suspended">>, TokenInfo, _Opts) ->
    token_respond(<<"sure">>, token_finish(TokenInfo, ?REC_TOKEN));
handle_token_callback(_Tag, <<"suspended">>, _TokenInfo, _Opts) ->
    Intent = ?sleep(0, undefined, ?completed),
    token_respond(<<"sure">>, token_result(Intent, <<"finishing">>)).

token_finish(#proxy_provider_RecurrentTokenInfo{payment_tool = PaymentTool}, Token) ->
    #proxy_provider_RecurrentTokenProxyResult{
        intent = ?recurrent_token_finish(Token),
        trx = #domain_TransactionInfo{id = PaymentTool#proxy_provider_RecurrentPaymentTool.id, extra = #{}}
    }.

token_result(Intent, State) ->
    #proxy_provider_RecurrentTokenProxyResult{
        intent = Intent,
        next_state = State
    }.

token_respond(Response, CallbackResult) ->
    #proxy_provider_RecurrentTokenCallbackResult{
        response = Response,
        result = CallbackResult
    }.

%
% Payments
%
process_payment(
    ?processed(),
    undefined,
    _PaymentInfo,
    #{<<"always_fail">> := FailureCode, <<"override">> := ProviderCode},
    _
) ->
    Failure = #domain_Failure{
        code = FailureCode,
        sub = #domain_SubFailure{code = <<"sub failure by ", ProviderCode/binary>>}
    },
    result(?finish({failure, Failure}));
process_payment(?processed(), undefined, PaymentInfo, _Ctx, _) ->
    case get_payment_info_scenario(PaymentInfo) of
        {preauth_3ds, Timeout} ->
            Tag = generate_tag(<<"payment">>),
            Uri = get_callback_url(),
            result(?suspend(Tag, Timeout, ?redirect(Uri, #{<<"tag">> => Tag})), <<"suspended">>);
        no_preauth ->
            %% simple workflow without 3DS
            result(?sleep(0), <<"sleeping">>);
        empty_cvv ->
            %% simple workflow without 3DS
            result(?sleep(0), <<"sleeping">>);
        preauth_3ds_offsite ->
            %% user interaction in sleep intent
            Uri = get_callback_url(),
            UserInteraction = ?redirect(
                Uri,
                #{
                    <<"invoice_id">> => get_invoice_id(PaymentInfo),
                    <<"payment_id">> => get_payment_id(PaymentInfo)
                }
            ),
            result(?sleep(1, UserInteraction), <<"sleeping_with_user_interaction">>);
        terminal ->
            %% workflow for euroset terminal, similar to 3DS workflow
            SPID = get_short_payment_id(PaymentInfo),
            UserInteraction =
                {payment_terminal_reciept, #user_interaction_PaymentTerminalReceipt{
                    short_payment_id = SPID,
                    due = get_invoice_due_date(PaymentInfo)
                }},
            result(?suspend(SPID, 2, UserInteraction), <<"suspended">>);
        digital_wallet ->
            %% simple workflow
            result(?sleep(0), <<"sleeping">>);
        crypto_currency ->
            %% simple workflow
            result(?sleep(0), <<"sleeping">>);
        mobile_commerce ->
            InvoiceID = get_invoice_id(PaymentInfo),
            PaymentID = get_payment_id(PaymentInfo),
            TimeoutBehaviour = {callback, <<"mobile_commerce">>},
            Intent = ?suspend(<<InvoiceID/binary, "/", PaymentID/binary>>, 0, undefined, TimeoutBehaviour),
            result(Intent, <<"suspended">>);
        recurrent ->
            %% simple workflow without 3DS
            result(?sleep(0), <<"sleeping">>);
        unexpected_failure ->
            sleep(1, <<"sleeping">>, undefined, get_payment_id(PaymentInfo));
        unexpected_failure_when_suspended ->
            Intent = ?suspend(generate_tag(<<"payment">>), 0, undefined, {callback, <<"failure">>}),
            result(Intent, <<"suspended">>);
        unexpected_failure_no_trx ->
            error(unexpected_failure);
        {temporary_unavailability, _Scenario} ->
            result(?sleep(0), <<"sleeping">>)
    end;
process_payment(?processed(), <<"sleeping">>, PaymentInfo, _Ctx, _) ->
    case get_payment_info_scenario(PaymentInfo) of
        unexpected_failure ->
            error(unexpected_failure);
        {temporary_unavailability, Scenario} ->
            process_failure_scenario(PaymentInfo, Scenario, get_payment_id(PaymentInfo));
        _ ->
            finish(success(PaymentInfo), get_payment_id(PaymentInfo), mk_trx_extra(PaymentInfo))
    end;
process_payment(?processed(), <<"sleeping_with_user_interaction">>, PaymentInfo, _Ctx, _) ->
    Key = {get_invoice_id(PaymentInfo), get_payment_id(PaymentInfo)},
    case get_transaction_state(Key) of
        processed ->
            finish(success(PaymentInfo), get_payment_id(PaymentInfo), mk_trx_extra(PaymentInfo));
        {pending, Count} when Count > 2 ->
            finish(failure(authorization_failed));
        {pending, Count} ->
            set_transaction_state(Key, {pending, Count + 1}),
            result(?sleep(1), <<"sleeping_with_user_interaction">>);
        undefined ->
            set_transaction_state(Key, {pending, 1}),
            result(?sleep(1), <<"sleeping_with_user_interaction">>)
    end;
process_payment(
    ?captured(),
    undefined,
    PaymentInfo = #proxy_provider_PaymentInfo{capture = Capture},
    _Ctx,
    _Opts
) when Capture =/= undefined ->
    case get_payment_info_scenario(PaymentInfo) of
        {temporary_unavailability, Scenario} ->
            process_failure_scenario(PaymentInfo, Scenario, get_payment_id(PaymentInfo));
        _ ->
            finish(success(PaymentInfo))
    end;
process_payment(?cancelled(), _, PaymentInfo, _Ctx, _) ->
    case get_payment_info_scenario(PaymentInfo) of
        {temporary_unavailability, Scenario} ->
            process_failure_scenario(PaymentInfo, Scenario, get_payment_id(PaymentInfo));
        _ ->
            finish(success(PaymentInfo))
    end.

handle_payment_callback(?LAY_LOW_BUDDY, ?processed(), <<"suspended">>, _PaymentInfo, _Opts) ->
    respond(<<"sure">>, #proxy_provider_PaymentCallbackProxyResult{
        intent = undefined,
        next_state = <<"suspended">>
    });
handle_payment_callback(<<"mobile_commerce">>, ?processed(), <<"suspended">>, PaymentInfo, _Opts) ->
    InvoiceID = get_invoice_id(PaymentInfo),
    PaymentID = get_payment_id(PaymentInfo),
    TimeoutBehaviour =
        case get_mobile_commerce(PaymentInfo) of
            {<<"777">>, <<"0000000000">>} ->
                {callback, <<"mobile_commerce failure">>};
            _Other ->
                {callback, <<"mobile_commerce finish success">>}
        end,
    respond(<<"sure">>, #proxy_provider_PaymentCallbackProxyResult{
        intent = ?suspend(<<InvoiceID/binary, "/", PaymentID/binary>>, 1, undefined, TimeoutBehaviour),
        next_state = <<"start">>
    });
handle_payment_callback(<<"mobile_commerce failure">>, ?processed(), <<"start">>, PaymentInfo, _Opts) ->
    InvoiceID = get_invoice_id(PaymentInfo),
    PaymentID = get_payment_id(PaymentInfo),
    Failure = #domain_Failure{
        code = <<"authorization_failed">>,
        reason = <<"test">>,
        sub = #domain_SubFailure{code = <<"unknown">>}
    },
    TimeoutBehaviour = {operation_failure, {failure, Failure}},
    respond(<<"sure">>, #proxy_provider_PaymentCallbackProxyResult{
        intent = ?suspend(<<InvoiceID/binary, "/", PaymentID/binary>>, 1, undefined, TimeoutBehaviour),
        next_state = <<"start">>
    });
handle_payment_callback(<<"mobile_commerce finish success">>, ?processed(), <<"start">>, _PaymentInfo, _Opts) ->
    respond(<<"sure">>, #proxy_provider_PaymentCallbackProxyResult{
        intent = ?finish(?success(undefined)),
        next_state = <<"finish">>
    });
handle_payment_callback(Tag, ?processed(), <<"suspended">>, PaymentInfo, _Opts) ->
    {{ok, PaymentInfo}, _} = get_payment_info(Tag),
    case get_payment_info_scenario(PaymentInfo) of
        unexpected_failure_when_suspended ->
            error(unexpected_failure_when_suspended);
        _ ->
            respond(<<"sure">>, #proxy_provider_PaymentCallbackProxyResult{
                intent = ?sleep(1, undefined, ?completed),
                next_state = <<"sleeping">>
            })
    end.

%% NOTE
%% You can stuff TransactionInfo.extra with anything you want.
%% This may prove to be useful when you need to verify in your testcase that specific pieces of
%% information really reached proxies, for example.
mk_trx_extra(#proxy_provider_PaymentInfo{
    payment = Payment
}) ->
    lists:foldl(fun maps:merge/2, #{}, [
        prefix_extra(<<"payment">>, mk_trx_extra(Payment))
    ]);
mk_trx_extra(#proxy_provider_InvoicePayment{
    payment_service = PaymentService,
    payer_session_info = PayerSessionInfo
}) ->
    lists:foldl(fun maps:merge/2, #{}, [
        prefix_extra(<<"payer_session_info">>, mk_trx_extra(PayerSessionInfo)),
        prefix_extra(<<"payment_service">>, mk_trx_extra(PaymentService))
    ]);
mk_trx_extra(R = #domain_PayerSessionInfo{}) ->
    record_to_map(R, record_info(fields, domain_PayerSessionInfo));
mk_trx_extra(#domain_PaymentService{name = Name, brand_name = BrandName}) ->
    #{<<"name">> => Name, <<"brand_name">> => BrandName};
mk_trx_extra(undefined) ->
    #{}.

prefix_extra(Prefix, Extra) ->
    genlib_map:truemap(fun(K, V) -> {hg_utils:join(Prefix, $., K), V} end, Extra).

record_to_map(Record, Fields) ->
    maps:from_list(hg_proto_utils:record_to_proplist(Record, Fields)).

-spec do_failure_scenario_step(failure_scenario(), term()) -> failure_scenario_step().
do_failure_scenario_step(Scenario, Key) ->
    Step =
        case get_transaction_state(Key) of
            {scenario_step, S} ->
                S;
            undefined ->
                1
        end,
    set_transaction_state(Key, {scenario_step, Step + 1}),
    get_failure_scenario_step(Scenario, Step).

-spec get_failure_scenario_step(failure_scenario(), Index :: pos_integer()) -> failure_scenario_step().
get_failure_scenario_step(Scenario, Step) when Step > length(Scenario) ->
    good;
get_failure_scenario_step(Scenario, Step) ->
    lists:nth(Step, Scenario).

process_refund(undefined, PaymentInfo, _) ->
    case get_payment_info_scenario(PaymentInfo) of
        {temporary_unavailability, Scenario} ->
            PaymentId = hg_utils:construct_complex_id([get_payment_id(PaymentInfo), get_refund_id(PaymentInfo)]),
            process_failure_scenario(PaymentInfo, Scenario, PaymentId);
        _ ->
            finish(success(PaymentInfo), get_payment_id(PaymentInfo))
    end.

process_failure_scenario(PaymentInfo, Scenario, PaymentId) ->
    Key = {get_invoice_id(PaymentInfo), get_payment_id(PaymentInfo)},
    case do_failure_scenario_step(Scenario, Key) of
        good ->
            finish(success(PaymentInfo), PaymentId);
        temp ->
            finish(failure(authorization_failed, temporarily_unavailable));
        fail ->
            finish(failure(authorization_failed));
        error ->
            error(planned_scenario_error)
    end.

result(Intent) ->
    result(Intent, undefined).

result(Intent, NextState) ->
    result(Intent, NextState, undefined).

result(Intent, NextState, Trx) ->
    #proxy_provider_PaymentProxyResult{
        intent = Intent,
        next_state = NextState,
        trx = Trx
    }.

finish(Status) ->
    result(?finish(Status)).

finish(Status, TrxID) ->
    finish(Status, TrxID, #{}).

finish(Status, TrxID, Extra) ->
    AdditionalInfo = hg_ct_fixture:construct_dummy_additional_info(),
    Trx = #domain_TransactionInfo{id = TrxID, extra = Extra, additional_info = AdditionalInfo},
    result(?finish(Status), undefined, Trx).

sleep(Timeout, State, UserInteraction, TrxID) ->
    AdditionalInfo = hg_ct_fixture:construct_dummy_additional_info(),
    Trx = #domain_TransactionInfo{id = TrxID, extra = #{}, additional_info = AdditionalInfo},
    result(?sleep(Timeout, UserInteraction), State, Trx).

respond(Response, CallbackResult) ->
    #proxy_provider_PaymentCallbackResult{
        response = Response,
        result = CallbackResult
    }.

success(PaymentInfo) ->
    #proxy_provider_PaymentInfo{payment = #proxy_provider_InvoicePayment{make_recurrent = MakeRecurrent}} = PaymentInfo,
    Token =
        case MakeRecurrent of
            true ->
                ?REC_TOKEN;
            Other when Other =:= false orelse Other =:= undefined ->
                undefined
        end,
    ?success(Token).

failure(Code) when is_atom(Code) ->
    failure(Code, unknown).

failure(Code, Sub) when is_atom(Code), is_atom(Sub) ->
    {failure,
        payproc_errors:construct(
            'PaymentFailure',
            {Code, {Sub, #payproc_error_GeneralFailure{}}}
        )}.

get_payment_id(#proxy_provider_PaymentInfo{payment = Payment}) ->
    Payment#proxy_provider_InvoicePayment.id.

get_refund_id(#proxy_provider_PaymentInfo{refund = Refund}) ->
    Refund#proxy_provider_InvoicePaymentRefund.id.

get_mobile_commerce(#proxy_provider_PaymentInfo{payment = Payment}) ->
    #proxy_provider_InvoicePayment{payment_resource = Resource} = Payment,
    {disposable_payment_resource, #domain_DisposablePaymentResource{payment_tool = PaymentTool}} = Resource,
    {mobile_commerce, #domain_MobileCommerce{phone = MobilePhone}} = PaymentTool,
    #domain_MobilePhone{
        cc = CC,
        ctn = Phone
    } = MobilePhone,
    {CC, Phone}.

get_invoice_id(#proxy_provider_PaymentInfo{invoice = Invoice}) ->
    Invoice#proxy_provider_Invoice.id.

get_payment_info_scenario(
    #proxy_provider_PaymentInfo{payment = #proxy_provider_InvoicePayment{payment_resource = Resource}}
) ->
    get_payment_resource_scenario(Resource).

get_payment_resource_scenario({disposable_payment_resource, PaymentResource}) ->
    PaymentTool = get_payment_tool(PaymentResource),
    get_payment_tool_scenario(PaymentTool);
get_payment_resource_scenario({recurrent_payment_resource, _}) ->
    recurrent.

get_recurrent_paytool_scenario(#proxy_provider_RecurrentPaymentTool{payment_resource = PaymentResource}) ->
    PaymentTool = get_payment_tool(PaymentResource),
    get_payment_tool_scenario(PaymentTool).

get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"no_preauth">>}}) ->
    no_preauth;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"no_preauth_timeout">>}}) ->
    no_preauth_timeout;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"no_preauth_timeout_failure">>}}) ->
    no_preauth_timeout_failure;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"no_preauth_suspend_default">>}}) ->
    no_preauth_suspend_default;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"empty_cvv">>}}) ->
    empty_cvv;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"preauth_3ds:timeout=", Timeout/binary>>}}) ->
    {preauth_3ds, erlang:binary_to_integer(Timeout)};
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"preauth_3ds_offsite">>}}) ->
    preauth_3ds_offsite;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"preauth_3ds_sleep:timeout=", Timeout/binary>>}}) ->
    {preauth_3ds_sleep, erlang:binary_to_integer(Timeout)};
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"forbidden">>}}) ->
    forbidden;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"unexpected_failure_no_trx">>}}) ->
    unexpected_failure_no_trx;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"unexpected_failure">>}}) ->
    unexpected_failure;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"unexpected_failure_when_suspended">>}}) ->
    unexpected_failure_when_suspended;
get_payment_tool_scenario({'bank_card', #domain_BankCard{token = <<"scenario_", BinScenario/binary>>}}) ->
    Scenario = decode_failure_scenario(BinScenario),
    {temporary_unavailability, Scenario};
get_payment_tool_scenario(
    {'payment_terminal', #domain_PaymentTerminal{payment_service = #domain_PaymentServiceRef{id = <<"euroset-ref">>}}}
) ->
    terminal;
get_payment_tool_scenario(
    {'digital_wallet', #domain_DigitalWallet{payment_service = #domain_PaymentServiceRef{id = <<"qiwi-ref">>}}}
) ->
    digital_wallet;
get_payment_tool_scenario({'crypto_currency', #domain_CryptoCurrencyRef{id = <<"bitcoin-ref">>}}) ->
    crypto_currency;
get_payment_tool_scenario(
    {'mobile_commerce', #domain_MobileCommerce{operator = #domain_MobileOperatorRef{id = <<"mts-ref">>}}}
) ->
    mobile_commerce.

-type tokenized_bank_card_payment_system() ::
    {
        dmsl_domain_thrift:'PaymentSystemRef'(),
        dmsl_domain_thrift:'BankCardTokenServiceRef'(),
        dmsl_domain_thrift:'TokenizationMethod'()
    }.
-type payment_system() ::
    dmsl_domain_thrift:'PaymentServiceRef'()
    | dmsl_domain_thrift:'PaymentSystemRef'()
    | dmsl_domain_thrift:'MobileOperatorRef'()
    | dmsl_domain_thrift:'CryptoCurrencyRef'()
    | tokenized_bank_card_payment_system().
-type payment_tool() :: {dmsl_domain_thrift:'PaymentTool'(), dmsl_domain_thrift:'PaymentSessionID'()}.
-type payment_tool_code() ::
    terminal
    | digital_wallet
    | tokenized_bank_card
    | crypto_currency
    | {mobile_commerce, failure}
    | {mobile_commerce, success}
    | preauth_3ds_offsite
    | forbidden
    | unexpected_failure
    | unexpected_failure_no_trx
    | preauth_3ds
    | no_preauth
    | no_preauth_timeout
    | no_preauth_timeout_failure
    | no_preauth_suspend_default
    | empty_cvv
    | {scenario, failure_scenario()}
    | {preauth_3ds, integer()}
    | {preauth_3ds_sleep, integer()}.

-spec make_payment_tool(payment_tool_code(), payment_system()) -> payment_tool().
make_payment_tool(Code, PSys) when
    Code =:= no_preauth orelse
        Code =:= no_preauth_timeout orelse
        Code =:= no_preauth_timeout_failure orelse
        Code =:= no_preauth_suspend_default orelse
        Code =:= preauth_3ds_offsite orelse
        Code =:= forbidden orelse
        Code =:= unexpected_failure orelse
        Code =:= unexpected_failure_when_suspended orelse
        Code =:= unexpected_failure_no_trx
->
    ?SESSION42(make_bank_card_payment_tool(atom_to_binary(Code, utf8), PSys));
make_payment_tool(empty_cvv, PSys) ->
    {_, BCard} = make_bank_card_payment_tool(<<"empty_cvv">>, PSys),
    ?SESSION42({bank_card, BCard#domain_BankCard{is_cvv_empty = true}});
make_payment_tool(preauth_3ds, PSys) ->
    make_payment_tool({preauth_3ds, 3}, PSys);
make_payment_tool({Code, Timeout}, PSys) when Code =:= preauth_3ds orelse Code =:= preauth_3ds_sleep ->
    Token = atom_to_binary(Code, utf8),
    TimeoutBin = erlang:integer_to_binary(Timeout),
    ?SESSION42(make_bank_card_payment_tool(<<Token/binary, ":timeout=", TimeoutBin/binary>>, PSys));
make_payment_tool({scenario, Scenario}, PSys) ->
    BinScenario = encode_failure_scenario(Scenario),
    ?SESSION42(make_bank_card_payment_tool(<<"scenario_", BinScenario/binary>>, PSys));
make_payment_tool(terminal, PSrv = #domain_PaymentServiceRef{}) ->
    ?DEFAULT_SESSION({payment_terminal, #domain_PaymentTerminal{payment_service = PSrv}});
make_payment_tool(digital_wallet, PSrv = #domain_PaymentServiceRef{}) ->
    ?DEFAULT_SESSION(make_digital_wallet_payment_tool(PSrv));
make_payment_tool(tokenized_bank_card, {PSys, Provider, Method}) ->
    {_, BCard} = make_bank_card_payment_tool(<<"no_preauth">>, PSys),
    ?SESSION42({bank_card, BCard#domain_BankCard{payment_token = Provider, tokenization_method = Method}});
make_payment_tool(crypto_currency, Type = #domain_CryptoCurrencyRef{}) ->
    ?DEFAULT_SESSION({crypto_currency, Type});
make_payment_tool({mobile_commerce, Exp}, Operator = #domain_MobileOperatorRef{}) ->
    ?DEFAULT_SESSION(make_mobile_commerce_payment_tool(Operator, phone(Exp))).

make_digital_wallet_payment_tool(PSrv) ->
    Wallet = #domain_DigitalWallet{
        id = <<"+79876543210">>,
        token = <<"some_token">>,
        payment_service = PSrv
    },
    {digital_wallet, Wallet}.

make_mobile_commerce_payment_tool(Operator, Phone) ->
    Mob = #domain_MobileCommerce{
        operator = Operator,
        phone = Phone
    },
    {mobile_commerce, Mob}.

phone(success) ->
    #domain_MobilePhone{
        cc = <<"7">>,
        ctn = <<"9876543210">>
    };
phone(failure) ->
    #domain_MobilePhone{
        cc = <<"777">>,
        ctn = <<"0000000000">>
    }.

make_bank_card_payment_tool(Token, PSys) ->
    BCard = #domain_BankCard{
        token = Token,
        bin = <<"424242">>,
        last_digits = <<"4242">>,
        payment_system = PSys
    },
    {bank_card, BCard}.

get_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

get_short_payment_id(#proxy_provider_PaymentInfo{invoice = Invoice, payment = Payment}) ->
    <<(Invoice#proxy_provider_Invoice.id)/binary, ".", (Payment#proxy_provider_InvoicePayment.id)/binary>>.

get_invoice_due_date(#proxy_provider_PaymentInfo{invoice = Invoice}) ->
    Invoice#proxy_provider_Invoice.due.

-spec encode_failure_scenario(failure_scenario()) -> binary().
encode_failure_scenario(Scenario) ->
    <<<<(encode_failure_scenario_step(S)):8>> || S <- Scenario>>.

-spec decode_failure_scenario(binary()) -> failure_scenario().
decode_failure_scenario(BinScenario) ->
    [decode_failure_scenario_step(B) || <<B:8>> <= BinScenario].

-spec encode_failure_scenario_step(failure_scenario_step()) -> byte().
encode_failure_scenario_step(good) ->
    $g;
encode_failure_scenario_step(temp) ->
    $t;
encode_failure_scenario_step(fail) ->
    $f;
encode_failure_scenario_step(error) ->
    $e.

-spec decode_failure_scenario_step(byte()) -> failure_scenario_step().
decode_failure_scenario_step($g) ->
    good;
decode_failure_scenario_step($t) ->
    temp;
decode_failure_scenario_step($f) ->
    fail;
decode_failure_scenario_step($e) ->
    error.

%%

-spec init(cowboy_req:req(), list()) -> {ok, cowboy_req:req(), list()}.
init(Req, Opts) ->
    Method = cowboy_req:method(Req),
    Req2 = handle_user_interaction_response(Method, Req),
    {ok, Req2, Opts}.

-spec terminate(term(), cowboy_req:req(), state) -> ok.
terminate(_Reason, _Req, _State) ->
    ok.

-spec get_callback_url() -> binary().
get_callback_url() ->
    genlib:to_binary("http://127.0.0.1:" ++ integer_to_list(?COWBOY_PORT)).

handle_user_interaction_response(<<"POST">>, Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    Form = maps:from_list(cow_qs:parse_qs(Body)),
    RespCode =
        case maps:get(<<"tag">>, Form, undefined) of
            %% sleep intent
            undefined ->
                InvoiceID = maps:get(<<"invoice_id">>, Form),
                PaymentID = maps:get(<<"payment_id">>, Form),
                set_transaction_state({InvoiceID, PaymentID}, processed),
                200;
            %% suspend intent
            Tag ->
                Payload = maps:get(<<"payload">>, Form, Tag),
                callback_to_hell(Tag, Payload)
        end,
    cowboy_req:reply(RespCode, #{<<"content-type">> => <<"text/plain; charset=utf-8">>}, <<>>, Req2);
handle_user_interaction_response(_, Req) ->
    %% Method not allowed.
    cowboy_req:reply(405, Req).

callback_to_hell(Tag, Payload) ->
    % This case emulate precisely current proxy behaviour. HOLY MACKEREL!
    Fun =
        case Tag of
            <<"payment-", _Rest/binary>> ->
                'ProcessPaymentCallback';
            <<"recurrent-", _Rest/binary>> ->
                'ProcessRecurrentTokenCallback';
            % FIXME adhoc for old tests, probably can be safely removed
            _ ->
                'ProcessPaymentCallback'
        end,
    case
        hg_client_api:call(
            proxy_host_provider,
            Fun,
            [Tag, Payload],
            hg_client_api:new(hg_ct_helper:get_hellgate_url())
        )
    of
        {{ok, _Response}, _} ->
            200;
        {{error, _}, _} ->
            500;
        {{exception, #base_InvalidRequest{}}, _} ->
            400
    end.

generate_tag(Prefix) ->
    ID = hg_utils:unique_id(),
    <<Prefix/binary, "-", ID/binary>>.

get_payment_info(Tag) ->
    hg_client_api:call(
        proxy_host_provider,
        'GetPayment',
        [Tag],
        hg_client_api:new(hg_ct_helper:get_hellgate_url())
    ).

set_transaction_state(Key, Value) ->
    hg_kv_store:put(Key, Value).

get_transaction_state(Key) ->
    hg_kv_store:get(Key).
