-module(hg_machine_tag).

-define(BENDER_NS, <<"machinegun-tag">>).

-export([get_machine_id/2]).
-export([bind_machine_id/3]).

-type tag() :: mg_proto_base_thrift:'Tag'().
-type ns() :: hg_machine:ns().
-type machine_id() :: hg_machine:id().
-type machine_ref() :: hg_machine:ref().

%% | {error, not_found}.
-spec get_machine_id(ns(), tag()) -> {ok, machine_ref()}.
get_machine_id(NS, Tag) ->
    WoodyContext = hg_context:get_woody_context(hg_context:load()),
    case bender_client:get_internal_id(tag_to_external_id(NS, Tag), WoodyContext) of
        {ok, InternalID} ->
            {ok, InternalID};
        {ok, InternalID, _} ->
            {ok, InternalID};
        {error, internal_id_not_found} ->
            %% Fall back to machinegun-based tags
            %% TODO: Remove after grace period for migration
            {ok, {tag, Tag}}
    end.

-spec bind_machine_id(ns(), machine_id(), tag()) -> ok | no_return().
bind_machine_id(NS, MachineID, Tag) ->
    WoodyContext = hg_context:get_woody_context(hg_context:load()),
    case bender_client:gen_constant(tag_to_external_id(NS, Tag), MachineID, WoodyContext) of
        {ok, _InternalID} ->
            ok;
        {ok, _InternalID, _} ->
            ok
    end.

%%

tag_to_external_id(NS, Tag) ->
    <<?BENDER_NS/binary, "-", NS/binary, "-", Tag/binary>>.
