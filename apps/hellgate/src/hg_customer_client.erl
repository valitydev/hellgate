-module(hg_customer_client).

-include_lib("damsel/include/dmsl_customer_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%% BankCard operations
-export([find_or_create_bank_card/2]).
-export([get_recurrent_tokens_by_card/2]).
-export([save_recurrent_token_by_card/3]).
-export([tokens_to_map/1]).

%% Customer operations
-export([create_customer/1]).
-export([get_by_parent_payment/2]).
-export([get_recurrent_tokens/2]).
-export([add_payment/3]).
-export([link_bank_card/2]).

-export_type([cascade_tokens/0]).

-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type provider_terminal_key() :: dmsl_customer_thrift:'ProviderTerminalKey'().
-type token() :: dmsl_domain_thrift:'Token'().
-type recurrent_token() :: dmsl_customer_thrift:'RecurrentToken'().
-type cascade_tokens() :: #{provider_terminal_key() => token()}.

%% BankCard operations

-spec find_or_create_bank_card(dmsl_domain_thrift:'PartyConfigRef'(), token()) ->
    dmsl_customer_thrift:'BankCard'().
find_or_create_bank_card(PartyConfigRef, BankCardToken) ->
    case find_bank_card(PartyConfigRef, BankCardToken) of
        {ok, BankCard} ->
            BankCard;
        {exception, #customer_BankCardNotFound{}} ->
            {ok, BankCard} = call(
                bank_card_storage,
                'Create',
                {PartyConfigRef, #customer_BankCardParams{bank_card_token = BankCardToken}}
            ),
            BankCard
    end.

-spec get_recurrent_tokens_by_card(dmsl_domain_thrift:'PartyConfigRef'(), token()) ->
    [recurrent_token()].
get_recurrent_tokens_by_card(PartyConfigRef, BankCardToken) ->
    case find_bank_card(PartyConfigRef, BankCardToken) of
        {ok, #customer_BankCard{id = BankCardID}} ->
            {ok, Tokens} = call(bank_card_storage, 'GetRecurrentTokens', {BankCardID}),
            Tokens;
        {exception, #customer_BankCardNotFound{}} ->
            []
    end.

-spec save_recurrent_token_by_card(
    dmsl_domain_thrift:'PartyConfigRef'(),
    token(),
    {dmsl_domain_thrift:'PaymentRoute'(), token()}
) -> ok.
save_recurrent_token_by_card(
    PartyConfigRef,
    BankCardToken,
    {#domain_PaymentRoute{provider = ProviderRef, terminal = TerminalRef}, RecToken}
) ->
    #customer_BankCard{id = BankCardID} = find_or_create_bank_card(PartyConfigRef, BankCardToken),
    {ok, _} = call(
        bank_card_storage,
        'AddRecurrentToken',
        {#customer_RecurrentTokenParams{
            bank_card_id = BankCardID,
            provider_ref = ProviderRef,
            terminal_ref = TerminalRef,
            token = RecToken
        }}
    ),
    ok.

-spec tokens_to_map([recurrent_token()]) -> cascade_tokens().
tokens_to_map(Tokens) ->
    lists:foldl(fun token_to_map_entry/2, #{}, Tokens).

%% Customer operations

-spec create_customer(dmsl_domain_thrift:'PartyConfigRef'()) -> dmsl_customer_thrift:'Customer'().
create_customer(PartyConfigRef) ->
    {ok, Customer} = call(customer_management, 'Create', {#customer_CustomerParams{party_ref = PartyConfigRef}}),
    Customer.

-spec get_by_parent_payment(invoice_id(), payment_id()) ->
    {ok, dmsl_customer_thrift:'CustomerState'()} | {exception, term()}.
get_by_parent_payment(InvoiceID, PaymentID) ->
    call(customer_management, 'GetByParentPayment', {InvoiceID, PaymentID}).

-spec get_recurrent_tokens(invoice_id(), payment_id()) -> [recurrent_token()].
get_recurrent_tokens(InvoiceID, PaymentID) ->
    case call(customer_management, 'GetByParentPayment', {InvoiceID, PaymentID}) of
        {ok, #customer_CustomerState{bank_card_refs = BankCardRefs}} ->
            lists:flatmap(fun collect_bank_card_tokens/1, BankCardRefs);
        {exception, #customer_CustomerNotFound{}} ->
            [];
        {exception, #customer_InvalidRecurrentParent{}} ->
            []
    end.

-spec add_payment(dmsl_customer_thrift:'CustomerID'(), invoice_id(), payment_id()) -> ok.
add_payment(CustomerID, InvoiceID, PaymentID) ->
    {ok, ok} = call(customer_management, 'AddPayment', {CustomerID, InvoiceID, PaymentID}),
    ok.

-spec link_bank_card(dmsl_customer_thrift:'CustomerID'(), token()) -> ok.
link_bank_card(CustomerID, BankCardToken) ->
    {ok, _} = call(
        customer_management,
        'AddBankCard',
        {CustomerID, #customer_BankCardParams{bank_card_token = BankCardToken}}
    ),
    ok.

%% Internal

find_bank_card(PartyConfigRef, BankCardToken) ->
    SearchParams = #customer_BankCardSearchParams{
        bank_card_token = BankCardToken,
        party_ref = PartyConfigRef
    },
    call(bank_card_storage, 'Find', {SearchParams}).

collect_bank_card_tokens(#customer_BankCardRef{id = BankCardID}) ->
    {ok, Tokens} = call(bank_card_storage, 'GetRecurrentTokens', {BankCardID}),
    Tokens.

token_to_map_entry(
    #customer_RecurrentToken{
        provider_ref = ProviderRef,
        terminal_ref = TerminalRef,
        token = Token
    },
    Acc
) ->
    Key = #customer_ProviderTerminalKey{
        provider_ref = ProviderRef,
        terminal_ref = TerminalRef
    },
    Acc#{Key => Token}.

call(ServiceName, Function, Args) ->
    Service = hg_proto:get_service(ServiceName),
    Opts = hg_woody_wrapper:get_service_options(ServiceName),
    WoodyContext =
        try
            hg_context:get_woody_context(hg_context:load())
        catch
            error:badarg -> woody_context:new()
        end,
    Request = {Service, Function, Args},
    woody_client:call(
        Request,
        Opts#{
            event_handler => {
                scoper_woody_event_handler,
                genlib_app:env(hellgate, scoper_event_handler_options, #{})
            }
        },
        WoodyContext
    ).
