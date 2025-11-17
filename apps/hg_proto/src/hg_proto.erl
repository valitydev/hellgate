-module(hg_proto).

-export([get_service/1]).

-export([get_service_spec/1]).
-export([get_service_spec/2]).

-export_type([service/0]).
-export_type([service_spec/0]).

%%

-define(VERSION_PREFIX, "/v1").

-type service() :: woody:service().
-type service_spec() :: {Path :: string(), service()}.

-spec get_service(Name :: atom()) -> service().
get_service(party_management) ->
    {dmsl_payproc_thrift, 'PartyManagement'};
get_service(invoicing) ->
    {dmsl_payproc_thrift, 'Invoicing'};
get_service(invoice_templating) ->
    {dmsl_payproc_thrift, 'InvoiceTemplating'};
get_service(proxy_provider) ->
    {dmsl_proxy_provider_thrift, 'ProviderProxy'};
get_service(proxy_inspector) ->
    {dmsl_proxy_inspector_thrift, 'InspectorProxy'};
get_service(proxy_host_provider) ->
    {dmsl_proxy_provider_thrift, 'ProviderProxyHost'};
get_service(accounter) ->
    {dmsl_accounter_thrift, 'Accounter'};
get_service(automaton) ->
    {mg_proto_state_processing_thrift, 'Automaton'};
get_service(processor) ->
    {mg_proto_state_processing_thrift, 'Processor'};
get_service(eventsink) ->
    {mg_proto_state_processing_thrift, 'EventSink'};
get_service(fault_detector) ->
    {fd_proto_fault_detector_thrift, 'FaultDetector'};
get_service(limiter) ->
    {limproto_limiter_thrift, 'Limiter'};
get_service(party_config) ->
    {dmsl_payproc_thrift, 'PartyManagement'}.

-spec get_service_spec(Name :: atom()) -> service_spec().
get_service_spec(Name) ->
    get_service_spec(Name, #{}).

-spec get_service_spec(Name :: atom(), Opts :: #{namespace => binary()}) -> service_spec().
get_service_spec(invoicing = Name, #{}) ->
    {?VERSION_PREFIX ++ "/processing/invoicing", get_service(Name)};
get_service_spec(invoice_templating = Name, #{}) ->
    {?VERSION_PREFIX ++ "/processing/invoice_templating", get_service(Name)};
get_service_spec(processor = Name, #{namespace := Ns}) when is_binary(Ns) ->
    {?VERSION_PREFIX ++ "/stateproc/" ++ binary_to_list(Ns), get_service(Name)};
get_service_spec(proxy_host_provider = Name, #{}) ->
    {?VERSION_PREFIX ++ "/proxyhost/provider", get_service(Name)}.
