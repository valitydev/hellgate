-module(ff_services).

-export([get_service/1]).
-export([get_service_path/1]).
-export([get_service_spec/1]).

-export_type([service/0]).
-export_type([service_name/0]).
-export_type([service_spec/0]).

%%

-type service() :: woody:service().
-type service_name() :: atom().
-type service_spec() :: {Path :: string(), service()}.

-spec get_service(service_name()) -> service().

get_service(ff_withdrawal_adapter_host) ->
    {dmsl_wthd_provider_thrift, 'AdapterHost'};
get_service(withdrawal_session_repairer) ->
    {fistful_wthd_session_thrift, 'Repairer'};
get_service(withdrawal_repairer) ->
    {fistful_wthd_thrift, 'Repairer'};
get_service(deposit_repairer) ->
    {fistful_deposit_thrift, 'Repairer'};
get_service(destination_management) ->
    {fistful_destination_thrift, 'Management'};
get_service(source_management) ->
    {fistful_source_thrift, 'Management'};
get_service(withdrawal_management) ->
    {fistful_wthd_thrift, 'Management'};
get_service(withdrawal_session_management) ->
    {fistful_wthd_session_thrift, 'Management'};
get_service(deposit_management) ->
    {fistful_deposit_thrift, 'Management'};
get_service(party_config) ->
    {dmsl_payproc_thrift, 'PartyManagement'};
get_service(ff_claim_committer) ->
    {dmsl_claimmgmt_thrift, 'ClaimCommitter'}.

-spec get_service_spec(service_name()) -> service_spec().
get_service_spec(Name) ->
    {get_service_path(Name), get_service(Name)}.

-spec get_service_path(service_name()) -> string().
get_service_path(ff_withdrawal_adapter_host) ->
    "/v1/ff_withdrawal_adapter_host";
get_service_path(withdrawal_session_repairer) ->
    "/v1/repair/withdrawal/session";
get_service_path(withdrawal_repairer) ->
    "/v1/repair/withdrawal";
get_service_path(deposit_repairer) ->
    "/v1/repair/deposit";
get_service_path(destination_management) ->
    "/v1/destination";
get_service_path(source_management) ->
    "/v1/source";
get_service_path(withdrawal_management) ->
    "/v1/withdrawal";
get_service_path(withdrawal_session_management) ->
    "/v1/withdrawal_session";
get_service_path(deposit_management) ->
    "/v1/deposit".
