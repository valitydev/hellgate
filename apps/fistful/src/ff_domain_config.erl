%%%
%%% Domain config frontend
%%%

-module(ff_domain_config).

-export([object/1]).
-export([object/2]).
-export([head/0]).

-type revision() :: dmt_client:version().
-type object_data() :: dmt_client:object_data().
-type object_ref() :: dmsl_domain_thrift:'Reference'().

-export_type([revision/0]).
-export_type([object_data/0]).
-export_type([object_ref/0]).

%%

-include_lib("damsel/include/dmsl_domain_config_thrift.hrl").

-spec object(object_ref()) -> {ok, object_data()} | {error, notfound}.
object(ObjectRef) ->
    object(head(), ObjectRef).

-spec object(dmt_client:version(), object_ref()) -> {ok, object_data()} | {error, notfound}.
object(Version, Ref) ->
    case dmt_client:try_checkout_data(Version, Ref) of
        {ok, Data} ->
            {ok, Data};
        {error, object_not_found} ->
            {error, notfound}
    end.

-spec head() -> revision().
head() ->
    dmt_client:get_last_version().
