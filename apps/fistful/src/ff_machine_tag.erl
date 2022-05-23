-module(ff_machine_tag).

-define(BENDER_NS, <<"machinegun-tag">>).

-export([get_binding/2]).
-export([create_binding/3]).

-type tag() :: mg_proto_base_thrift:'Tag'().
-type ns() :: machinery:namespace().
-type entity_id() :: dmsl_base_thrift:'ID'().

-spec get_binding(ns(), tag()) -> {ok, entity_id()} | {error, not_found}.
get_binding(NS, Tag) ->
    WoodyContext = ff_context:get_woody_context(ff_context:load()),
    case bender_client:get_internal_id(tag_to_external_id(NS, Tag), WoodyContext) of
        {ok, EntityID} ->
            {ok, EntityID};
        {error, internal_id_not_found} ->
            {error, not_found}
    end.

-spec create_binding(ns(), tag(), entity_id()) -> ok | no_return().
create_binding(NS, Tag, EntityID) ->
    create_binding_(NS, Tag, EntityID, undefined).

%%

create_binding_(NS, Tag, EntityID, Context) ->
    WoodyContext = ff_context:get_woody_context(ff_context:load()),
    case bender_client:gen_constant(tag_to_external_id(NS, Tag), EntityID, WoodyContext, Context) of
        {ok, EntityID} ->
            ok
    end.

tag_to_external_id(NS, Tag) ->
    BinNS = atom_to_binary(NS, utf8),
    <<?BENDER_NS/binary, "-", BinNS/binary, "-", Tag/binary>>.
