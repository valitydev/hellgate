%%%
%%% Domain config helpers
%%%

-module(ct_domain_config).

-export([head/0]).
-export([get/1]).
-export([get/2]).

-export([commit/2]).
-export([insert/1]).
-export([update/1]).
-export([upsert/1]).
-export([remove/1]).
-export([reset/1]).
-export([cleanup/0]).
-export([bump_revision/0]).

%%

-include_lib("damsel/include/dmsl_domain_conf_v2_thrift.hrl").

-type revision() :: dmt_client:version().
-type object() :: dmsl_domain_thrift:'DomainObject'().
-type ref() :: dmsl_domain_thrift:'Reference'().
-type data() :: _.

-spec head() -> revision().
head() ->
    dmt_client:get_latest_version().

-spec get(ref()) -> data() | no_return().
get(Ref) ->
    get(latest, Ref).

-spec get(dmt_client:version(), ref()) -> data() | no_return().
get(Revision, Ref) ->
    try
        extract_data(dmt_client:checkout_object(Revision, Ref))
    catch
        throw:#domain_conf_v2_ObjectNotFound{} ->
            error({object_not_found, {Revision, Ref}})
    end.

-spec commit(revision(), [dmt_client:operation()]) -> revision() | no_return().
commit(Revision, Operations) ->
    #domain_conf_v2_CommitResponse{version = Version} = dmt_client:commit(Revision, Operations, ensure_stub_author()),
    Version.

-spec insert(object() | [object()]) -> revision() | no_return().
insert(ObjectOrMany) ->
    dmt_client:insert(ObjectOrMany, ensure_stub_author()).

-spec update(object() | [object()]) -> revision() | no_return().
update(NewObjectOrMany) ->
    dmt_client:update(NewObjectOrMany, ensure_stub_author()).

-spec upsert(object() | [object()]) -> revision() | no_return().
upsert(NewObjectOrMany) ->
    upsert(latest, NewObjectOrMany).

-spec upsert(revision(), object() | [object()]) -> revision() | no_return().
upsert(Revision, NewObjectOrMany) ->
    dmt_client:upsert(Revision, NewObjectOrMany, ensure_stub_author()).

-spec remove(object() | [object()]) -> revision() | no_return().
remove(ObjectOrMany) ->
    dmt_client:remove(ObjectOrMany, ensure_stub_author()).

-spec reset(revision()) -> revision() | no_return().
reset(ToRevision) ->
    Objects = dmt_client:checkout_all(ToRevision),
    upsert(unwrap_versioned_objects(Objects)).

-spec cleanup() -> revision() | no_return().
cleanup() ->
    Objects = dmt_client:checkout_all(latest),
    remove(unwrap_versioned_objects(Objects)).

-spec bump_revision() -> revision() | no_return().
bump_revision() ->
    #domain_conf_v2_CommitResponse{version = Version} = dmt_client:commit(latest, [], ensure_stub_author()),
    Version.

%%

extract_data(#domain_conf_v2_VersionedObject{object = {_Tag, {_Name, _Ref, Data}}}) ->
    Data.

ensure_stub_author() ->
    %% TODO DISCUSS Stubs and fallback authors
    ensure_author(~b"unknown", ~b"unknown@local").

ensure_author(Name, Email) ->
    try
        #domain_conf_v2_Author{id = ID} = dmt_client:get_author_by_email(Email),
        ID
    catch
        throw:#domain_conf_v2_AuthorNotFound{} ->
            dmt_client:create_author(Name, Email)
    end.

unwrap_versioned_objects(VersionedObjects) ->
    lists:map(fun(#domain_conf_v2_VersionedObject{object = Object}) -> Object end, VersionedObjects).
