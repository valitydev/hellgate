-module(hg_client_invoice_templating).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-export([start/1]).
-export([start_link/1]).
-export([stop/1]).

-export([create/2]).
-export([get/2]).
-export([update/3]).
-export([delete/2]).

-export([compute_terms/4]).

%% GenServer

-behaviour(gen_server).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%%

-type id() :: dmsl_domain_thrift:'InvoiceTemplateID'().
-type create_params() :: dmsl_payproc_thrift:'InvoiceTemplateCreateParams'().
-type update_params() :: dmsl_payproc_thrift:'InvoiceTemplateUpdateParams'().
-type invoice_tpl() :: dmsl_domain_thrift:'InvoiceTemplate'().
-type timestamp() :: dmsl_base_thrift:'Timestamp'().
-type term_set() :: dmsl_domain_thrift:'TermSet'().
-type party_revision_param() :: dmsl_payproc_thrift:'PartyRevisionParam'().

-spec start(hg_client_api:t()) -> pid().
start(ApiClient) ->
    start(start, ApiClient).

-spec start_link(hg_client_api:t()) -> pid().
start_link(ApiClient) ->
    start(start_link, ApiClient).

start(Mode, ApiClient) ->
    {ok, Pid} = gen_server:Mode(?MODULE, ApiClient, []),
    Pid.

-spec stop(pid()) -> ok.
stop(Client) ->
    _ = exit(Client, shutdown),
    ok.

%%

-spec create(create_params(), pid()) -> id() | woody_error:business_error().
create(Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Create', [Params]})).

-spec get(id(), pid()) -> invoice_tpl() | woody_error:business_error().
get(ID, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Get', [ID]})).

-spec update(id(), update_params(), pid()) -> invoice_tpl() | woody_error:business_error().
update(ID, Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Update', [ID, Params]})).

-spec delete(id(), pid()) -> ok | woody_error:business_error().
delete(ID, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Delete', [ID]})).

-spec compute_terms(id(), timestamp(), party_revision_param(), pid()) -> term_set().
compute_terms(ID, Timestamp, PartyRevision, Client) ->
    map_result_error(gen_server:call(Client, {call, 'ComputeTerms', [ID, Timestamp, PartyRevision]})).

map_result_error({ok, Result}) ->
    Result;
map_result_error({exception, _} = Exception) ->
    Exception;
map_result_error({error, Error}) ->
    error(Error).

%%

-type event() :: dmsl_payproc_thrift:'Event'().

-record(state, {
    pollers :: #{id() => hg_client_event_poller:st(event())},
    client :: hg_client_api:t()
}).

-type state() :: #state{}.
-type callref() :: {pid(), Tag :: reference()}.

-spec init(hg_client_api:t()) -> {ok, state()}.
init(ApiClient) ->
    {ok, #state{pollers = #{}, client = ApiClient}}.

-spec handle_call(term(), callref(), state()) -> {reply, term(), state()} | {noreply, state()}.
handle_call({call, Function, Args}, _From, St = #state{client = Client}) ->
    {Result, ClientNext} = hg_client_api:call(invoice_templating, Function, Args, Client),
    {reply, Result, St#state{client = ClientNext}};
handle_call({pull_event, InvoiceID, Timeout}, _From, St = #state{client = Client}) ->
    Poller = get_poller(InvoiceID, St),
    {Result, ClientNext, PollerNext} = hg_client_event_poller:poll(1, Timeout, Client, Poller),
    StNext = set_poller(InvoiceID, PollerNext, St#state{client = ClientNext}),
    case Result of
        [] ->
            {reply, timeout, StNext};
        [#payproc_Event{payload = Payload}] ->
            {reply, {ok, Payload}, StNext};
        Error ->
            {reply, Error, StNext}
    end;
handle_call(Call, _From, State) ->
    _ = logger:warning("unexpected call received: ~tp", [Call]),
    {noreply, State}.

-spec handle_cast(_, state()) -> {noreply, state()}.
handle_cast(Cast, State) ->
    _ = logger:warning("unexpected cast received: ~tp", [Cast]),
    {noreply, State}.

-spec handle_info(_, state()) -> {noreply, state()}.
handle_info(Info, State) ->
    _ = logger:warning("unexpected info received: ~tp", [Info]),
    {noreply, State}.

-spec terminate(Reason, state()) -> ok when Reason :: normal | shutdown | {shutdown, term()} | term().
terminate(_Reason, _State) ->
    ok.

-spec code_change(Vsn | {down, Vsn}, state(), term()) -> {error, noimpl} when Vsn :: term().
code_change(_OldVsn, _State, _Extra) ->
    {error, noimpl}.

%%

get_poller(ID, #state{pollers = Pollers}) ->
    maps:get(ID, Pollers, construct_poller(ID)).

set_poller(ID, Poller, St = #state{pollers = Pollers}) ->
    St#state{pollers = maps:put(ID, Poller, Pollers)}.

construct_poller(ID) ->
    hg_client_event_poller:new(
        {invoice_templating, 'GetEvents', [ID]},
        fun(Event) -> Event#payproc_Event.id end
    ).
