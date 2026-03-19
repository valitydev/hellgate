-module(hg_customer_client).

-include_lib("damsel/include/dmsl_customer_thrift.hrl").

-export([get_cascade_tokens/2]).

-type invoice_id() :: dmsl_domain_thrift:'InvoiceID'().
-type payment_id() :: dmsl_domain_thrift:'InvoicePaymentID'().
-type provider_terminal_key() :: dmsl_customer_thrift:'ProviderTerminalKey'().
-type token() :: dmsl_domain_thrift:'Token'().
-type cascade_tokens() :: #{provider_terminal_key() => token()}.

%%

-spec get_cascade_tokens(invoice_id(), payment_id()) -> cascade_tokens().
get_cascade_tokens(InvoiceID, PaymentID) ->
    try
        get_cascade_tokens_(InvoiceID, PaymentID)
    catch
        error:_ -> #{}
    end.

get_cascade_tokens_(InvoiceID, PaymentID) ->
    case hg_woody_wrapper:call(customer_management, 'GetByParentPayment', {InvoiceID, PaymentID}) of
        {ok, #customer_CustomerState{bank_card_refs = BankCardRefs}} ->
            lists:foldl(fun collect_bank_card_tokens/2, #{}, BankCardRefs);
        {exception, #customer_CustomerNotFound{}} ->
            #{};
        {exception, #customer_InvalidRecurrentParent{}} ->
            #{}
    end.

collect_bank_card_tokens(#customer_BankCardRef{id = BankCardID}, Acc) ->
    case hg_woody_wrapper:call(bank_card_storage, 'GetRecurrentTokens', {BankCardID}) of
        {ok, Tokens} ->
            lists:foldl(fun collect_recurrent_token/2, Acc, Tokens);
        {exception, _} ->
            Acc
    end.

collect_recurrent_token(
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
