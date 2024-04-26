-module(hg_client_recurrent_paytool).

-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

%% API

-export([start/1]).
-export([start_link/1]).
-export([stop/1]).

-export([create/2]).
-export([get/2]).
-export([get_events/3]).
-export([abandon/2]).

-export([pull_event/2]).
-export([pull_event/3]).

%% GenServer

-behaviour(gen_server).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Types

-type recurrent_paytool_id() :: dmsl_payproc_thrift:'RecurrentPaymentToolID'().
-type recurrent_paytool() :: dmsl_payproc_thrift:'RecurrentPaymentTool'().
-type recurrent_paytool_params() :: dmsl_payproc_thrift:'RecurrentPaymentToolParams'().

-type range() :: dmsl_payproc_thrift:'EventRange'().

%% API

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

-spec create(recurrent_paytool_params(), pid()) -> recurrent_paytool() | woody_error:business_error().
create(Params, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Create', [Params]})).

-spec get(recurrent_paytool_id(), pid()) -> recurrent_paytool() | woody_error:business_error().
get(ID, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Get', [ID]})).

-spec get_events(recurrent_paytool_id(), range(), pid()) -> recurrent_paytool() | woody_error:business_error().
get_events(ID, Range, Client) ->
    map_result_error(gen_server:call(Client, {call, 'GetEvents', [ID, Range]})).

-spec abandon(recurrent_paytool_id(), pid()) -> ok | woody_error:business_error().
abandon(ID, Client) ->
    map_result_error(gen_server:call(Client, {call, 'Abandon', [ID]})).

-define(DEFAULT_NEXT_EVENT_TIMEOUT, 5000).

-spec pull_event(recurrent_paytool_id(), pid()) -> tuple() | timeout | woody_error:business_error().
pull_event(ID, Client) ->
    pull_event(ID, ?DEFAULT_NEXT_EVENT_TIMEOUT, Client).

-spec pull_event(recurrent_paytool_id(), timeout(), pid()) -> tuple() | timeout | woody_error:business_error().
pull_event(ID, Timeout, Client) ->
    % FIXME: infinity sounds dangerous
    gen_server:call(Client, {pull_event, ID, Timeout}, infinity).

map_result_error({ok, Result}) ->
    Result;
map_result_error({exception, _} = Exception) ->
    Exception;
map_result_error({error, Error}) ->
    error(Error).

%%

-define(SERVICE, recurrent_paytool).

-type event() :: dmsl_payproc_thrift:'RecurrentPaymentToolEvent'().

-record(state, {
    pollers :: #{recurrent_paytool_id() => hg_client_event_poller:st(event())},
    client :: hg_client_api:t()
}).

-type state() :: #state{}.

-type callref() :: {pid(), Tag :: reference()}.

-spec init(hg_client_api:t()) -> {ok, state()}.
init(ApiClient) ->
    {ok, #state{pollers = #{}, client = ApiClient}}.

-spec handle_call(term(), callref(), state()) -> {reply, term(), state()} | {noreply, state()}.
handle_call({call, Function, Args}, _From, St = #state{client = Client}) ->
    {Result, ClientNext} = hg_client_api:call(?SERVICE, Function, Args, Client),
    {reply, Result, St#state{client = ClientNext}};
handle_call({pull_event, RecurrentPaytoolID, Timeout}, _From, St = #state{client = Client}) ->
    Poller = get_poller(RecurrentPaytoolID, St),
    {Result, ClientNext, PollerNext} = hg_client_event_poller:poll(1, Timeout, Client, Poller),
    StNext = set_poller(RecurrentPaytoolID, PollerNext, St#state{client = ClientNext}),
    case Result of
        [] ->
            {reply, timeout, StNext};
        [Event] ->
            {reply, {ok, get_event_payload(Event)}, StNext};
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
    hg_client_event_poller:new({?SERVICE, 'GetEvents', [ID]}, fun get_event_id/1).

get_event_id(#payproc_RecurrentPaymentToolEvent{id = ID}) ->
    ID.

get_event_payload(#payproc_RecurrentPaymentToolEvent{payload = Payload}) ->
    Payload.
