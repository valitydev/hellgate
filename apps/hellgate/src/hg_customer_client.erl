-module(hg_customer_client).

-include_lib("damsel/include/dmsl_customer_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").

-export([create_customer/1]).
-export([get_by_parent_payment/2]).
-export([get_recurrent_tokens/2]).
-export([tokens_to_map/1]).
-export([add_payment/3]).
-export([save_recurrent_token/4]).

-export_type([cascade_tokens/0]).

-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type provider_terminal_key() :: dmsl_customer_thrift:'ProviderTerminalKey'().
-type token() :: dmsl_domain_thrift:'Token'().
-type recurrent_token() :: dmsl_customer_thrift:'RecurrentToken'().
-type cascade_tokens() :: #{provider_terminal_key() => token()}.

%%

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

-spec tokens_to_map([recurrent_token()]) -> cascade_tokens().
tokens_to_map(Tokens) ->
    lists:foldl(fun token_to_map_entry/2, #{}, Tokens).

-spec add_payment(dmsl_customer_thrift:'CustomerID'(), invoice_id(), payment_id()) -> ok.
add_payment(CustomerID, InvoiceID, PaymentID) ->
    {ok, ok} = call(customer_management, 'AddPayment', {CustomerID, InvoiceID, PaymentID}),
    ok.

-spec save_recurrent_token(
    dmsl_customer_thrift:'CustomerID'(),
    token(),
    dmsl_domain_thrift:'PaymentRoute'(),
    token()
) -> ok.
save_recurrent_token(
    CustomerID,
    BankCardToken,
    #domain_PaymentRoute{provider = ProviderRef, terminal = TerminalRef},
    RecToken
) ->
    {ok, #customer_BankCard{id = BankCardID}} = call(
        customer_management,
        'AddBankCard',
        {CustomerID, #customer_BankCardParams{bank_card_token = BankCardToken}}
    ),
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

%%

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
