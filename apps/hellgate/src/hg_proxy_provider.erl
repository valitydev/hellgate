-module(hg_proxy_provider).

-include_lib("damsel/include/dmsl_proxy_provider_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([collect_proxy_options/1]).

-export([process_payment/2]).
-export([generate_token/2]).
-export([handle_payment_callback/3]).
-export([handle_recurrent_token_callback/3]).

-export([bind_transaction/2]).
-export([update_proxy_state/2]).
-export([wrap_session_events/2]).

-include("payment_events.hrl").

%%

-type trx_info() :: dmsl_domain_thrift:'TransactionInfo'().
-type route() :: dmsl_domain_thrift:'PaymentRoute'().

-type change() :: dmsl_payproc_thrift:'SessionChangePayload'().
-type proxy_state() :: dmsl_base_thrift:'Opaque'().

%%

-spec collect_proxy_options(route()) -> dmsl_domain_thrift:'ProxyOptions'().
collect_proxy_options(#domain_PaymentRoute{provider = ProviderRef, terminal = TerminalRef}) ->
    Revision = hg_domain:head(),
    Provider = hg_domain:get(Revision, {provider, ProviderRef}),
    Terminal = hg_domain:get(Revision, {terminal, TerminalRef}),
    Proxy = Provider#domain_Provider.proxy,
    ProxyDef = hg_domain:get(Revision, {proxy, Proxy#domain_Proxy.ref}),
    lists:foldl(
        fun
            (undefined, M) ->
                M;
            (M1, M) ->
                maps:merge(M1, M)
        end,
        #{},
        [
            Terminal#domain_Terminal.options,
            Proxy#domain_Proxy.additional,
            ProxyDef#domain_ProxyDefinition.options
        ]
    ).

%%

-spec process_payment(_ProxyContext, route()) -> term().
process_payment(ProxyContext, Route) ->
    issue_call('ProcessPayment', {ProxyContext}, Route).

-spec generate_token(_ProxyContext, route()) -> term().
generate_token(ProxyContext, Route) ->
    issue_call('GenerateToken', {ProxyContext}, Route).

-spec handle_payment_callback(_Payload, _ProxyContext, route()) -> term().
handle_payment_callback(Payload, ProxyContext, Route) ->
    issue_call('HandlePaymentCallback', {Payload, ProxyContext}, Route).

-spec handle_recurrent_token_callback(_Payload, _ProxyContext, route()) -> term().
handle_recurrent_token_callback(Payload, ProxyContext, Route) ->
    issue_call('HandleRecurrentTokenCallback', {Payload, ProxyContext}, Route).

-spec issue_call(woody:func(), woody:args(), route()) -> term().
issue_call(Func, Args, Route) ->
    CallID = hg_utils:unique_id(),
    try hg_woody_wrapper:call(proxy_provider, Func, Args, get_call_options(Route)) of
        Result ->
            _ = notify_fault_detector(finish, Route, CallID),
            Result
    catch
        error:{woody_error, _ErrorType} = Reason:St ->
            _ = notify_fault_detector(error, Route, CallID),
            erlang:raise(error, Reason, St)
    end.

notify_fault_detector(Status, Route, CallID) ->
    ServiceType = adapter_availability,
    ProviderRef = get_route_provider(Route),
    ProviderID = ProviderRef#domain_ProviderRef.id,
    ServiceID = hg_fault_detector_client:build_service_id(ServiceType, ProviderID),
    OperationID = hg_fault_detector_client:build_operation_id(ServiceType, [CallID]),
    hg_fault_detector_client:register_transaction(ServiceType, Status, ServiceID, OperationID).

get_call_options(Route) ->
    Revision = hg_domain:head(),
    Provider = hg_domain:get(Revision, {provider, get_route_provider(Route)}),
    hg_proxy:get_call_options(Provider#domain_Provider.proxy, Revision).

get_route_provider(#domain_PaymentRoute{provider = ProviderRef}) ->
    ProviderRef.

%%

-spec bind_transaction(trx_info(), term()) -> [change()].
bind_transaction(undefined, _Session) ->
    % no transaction yet
    [];
bind_transaction(Trx, #{trx := undefined}) ->
    % got transaction, nothing bound so far
    [?trx_bound(Trx)];
bind_transaction(Trx, #{trx := Trx}) ->
    % got the same transaction as one which has been bound previously
    [];
bind_transaction(Trx, #{trx := TrxWas}) ->
    % got transaction which differs from the bound one
    % verify against proxy contracts
    case Trx#domain_TransactionInfo.id of
        ID when ID =:= TrxWas#domain_TransactionInfo.id ->
            [?trx_bound(Trx)];
        _ ->
            error(proxy_contract_violated)
    end.

%%

-spec update_proxy_state(proxy_state() | undefined, _Session) -> [change()].
update_proxy_state(undefined, _Session) ->
    [];
update_proxy_state(ProxyState, Session) ->
    case get_session_proxy_state(Session) of
        ProxyState ->
            % proxy state did not change, no need to publish an event
            [];
        _WasState ->
            [?proxy_st_changed(ProxyState)]
    end.

get_session_proxy_state(Session) ->
    maps:get(proxy_state, Session, undefined).

%%

-spec wrap_session_events(list(), _Action) -> list().
wrap_session_events(SessionEvents, #{target := Target}) ->
    [?session_ev(Target, Ev) || Ev <- SessionEvents].
