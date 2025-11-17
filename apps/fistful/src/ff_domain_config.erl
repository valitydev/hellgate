%%%
%%% Domain config frontend
%%%

-module(ff_domain_config).

-export([object/1]).
-export([object/2]).
-export([head/0]).

-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

-type revision() :: dmt_client:version().
-type object_data() :: tuple().

-export_type([revision/0]).

%%

-spec object(dmt_client:object_ref()) -> {ok, object_data()} | {error, notfound}.
object(ObjectRef) ->
    object(head(), ObjectRef).

-spec object(dmt_client:version(), dmt_client:object_ref()) -> {ok, object_data()} | {error, notfound}.
object(Version, Ref) ->
    try
        {ok, extract_data(dmt_client:checkout_object(Version, Ref))}
    catch
        throw:#domain_conf_v2_ObjectNotFound{} ->
            {error, notfound}
    end.

extract_data(#domain_conf_v2_VersionedObject{object = {_Tag, {_Name, _Ref, Data}}}) ->
    Data.

-spec head() -> revision().
head() ->
    dmt_client:get_latest_version().
