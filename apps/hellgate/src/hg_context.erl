-module(hg_context).

-export([create/0]).
-export([create/1]).
-export([save/1]).
-export([load/0]).
-export([cleanup/0]).

-export([get_woody_context/1]).
-export([set_woody_context/2]).
-export([get_party_client_context/1]).
-export([set_party_client_context/2]).
-export([get_party_client/1]).
-export([set_party_client/2]).

-opaque context() :: #{
    woody_context := woody_context(),
    party_client_context := party_client_context(),
    party_client => party_client()
}.

-type options() :: #{
    party_client => party_client(),
    woody_context => woody_context(),
    party_client_context => party_client_context()
}.

-export_type([context/0]).
-export_type([options/0]).

%% Internal types

-type woody_context() :: woody_context:ctx().
-type party_client() :: party_client:client().
-type party_client_context() :: party_client:context().

-define(REGISTRY_KEY, {p, l, stored_hg_context}).

%% API

-spec create() -> context().
create() ->
    create(#{}).

-spec create(options()) -> context().
create(Options0) ->
    Options1 = ensure_woody_context_exists(Options0),
    ensure_party_context_exists(Options1).

-spec save(context()) -> ok.
save(Context) ->
    true =
        try
            gproc:reg(?REGISTRY_KEY, Context)
        catch
            error:badarg ->
                gproc:set_value(?REGISTRY_KEY, Context)
        end,
    ok.

-spec load() -> context() | no_return().
load() ->
    gproc:get_value(?REGISTRY_KEY).

-spec cleanup() -> ok.
cleanup() ->
    true = gproc:unreg(?REGISTRY_KEY),
    ok.

-spec get_woody_context(context()) -> woody_context().
get_woody_context(#{woody_context := WoodyContext}) ->
    WoodyContext.

-spec set_woody_context(woody_context(), context()) -> context().
set_woody_context(WoodyContext, Context) ->
    Context#{woody_context => WoodyContext}.

-spec get_party_client(context()) -> party_client().
get_party_client(#{party_client := PartyClient}) ->
    PartyClient;
get_party_client(Context) ->
    error(no_party_client, [Context]).

-spec set_party_client(party_client(), context()) -> context().
set_party_client(PartyClient, Context) ->
    Context#{party_client => PartyClient}.

-spec get_party_client_context(context()) -> party_client_context().
get_party_client_context(#{party_client_context := PartyContext}) ->
    PartyContext.

-spec set_party_client_context(party_client_context(), context() | options()) -> context().
set_party_client_context(PartyContext, Context) ->
    Context#{party_client_context => PartyContext}.

%% Internal functions

-spec ensure_woody_context_exists(options()) -> options().
ensure_woody_context_exists(#{woody_context := _WoodyContext} = Options) ->
    Options;
ensure_woody_context_exists(Options) ->
    Options#{woody_context => woody_context:new()}.

-spec ensure_party_context_exists(options()) -> options().
ensure_party_context_exists(#{party_client_context := _PartyContext} = Options) ->
    Options;
ensure_party_context_exists(#{woody_context := WoodyContext} = Options) ->
    set_party_client_context(party_client:create_context(#{woody_context => WoodyContext}), Options).
