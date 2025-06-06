-module(hg_inspector).

-export([check_blacklist/1]).
-export([inspect/4]).

-export([compare_risk_score/2]).

-export_type([risk_score/0]).
-export_type([blacklist_context/0]).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_proxy_inspector_thrift.hrl").

-type shop() :: dmsl_domain_thrift:'ShopConfig'().
-type invoice() :: dmsl_domain_thrift:'Invoice'().
-type payment() :: dmsl_domain_thrift:'InvoicePayment'().
-type inspector() :: dmsl_domain_thrift:'Inspector'().
-type risk_score() :: dmsl_domain_thrift:'RiskScore'().
-type risk_magnitude() :: integer().
-type domain_revision() :: dmsl_domain_thrift:'DataRevision'().

-type blacklist_context() :: #{
    route => hg_route:t(),
    revision := domain_revision(),
    token => binary(),
    inspector := inspector()
}.

-spec check_blacklist(blacklist_context()) -> boolean().
check_blacklist(#{
    route := Route,
    revision := Revision,
    token := Token,
    inspector := #domain_Inspector{
        proxy = Proxy
    }
}) when Token =/= undefined ->
    #domain_ProviderRef{id = ProviderID} = hg_route:provider_ref(Route),
    #domain_TerminalRef{id = TerminalID} = hg_route:terminal_ref(Route),
    Context = #proxy_inspector_BlackListContext{
        first_id = genlib:to_binary(ProviderID),
        second_id = genlib:to_binary(TerminalID),
        field_name = <<"CARD_TOKEN">>,
        value = Token
    },
    DeadLine = woody_deadline:from_timeout(genlib_app:env(hellgate, inspect_timeout, infinity)),
    {ok, Check} = issue_call(
        'IsBlacklisted',
        {Context},
        hg_proxy:get_call_options(
            Proxy,
            Revision
        ),
        false,
        DeadLine
    ),
    Check;
check_blacklist(_Ctx) ->
    false.

-spec inspect(shop(), invoice(), payment(), inspector()) -> risk_score() | no_return().
inspect(
    Shop,
    Invoice,
    #domain_InvoicePayment{
        domain_revision = Revision
    } = Payment,
    #domain_Inspector{
        fallback_risk_score = FallBackRiskScore0,
        proxy =
            Proxy = #domain_Proxy{
                ref = ProxyRef,
                additional = ProxyAdditional
            }
    }
) ->
    DeadLine = woody_deadline:from_timeout(genlib_app:env(hellgate, inspect_timeout, infinity)),
    ProxyDef = get_proxy_def(ProxyRef, Revision),
    Context = #proxy_inspector_Context{
        payment = get_payment_info(Shop, Invoice, Payment),
        options = maps:merge(ProxyDef#domain_ProxyDefinition.options, ProxyAdditional)
    },
    FallBackRiskScore1 =
        case FallBackRiskScore0 of
            undefined ->
                genlib_app:env(hellgate, inspect_score, high);
            Score ->
                Score
        end,
    {ok, RiskScore} = issue_call(
        'InspectPayment',
        {Context},
        hg_proxy:get_call_options(
            Proxy,
            Revision
        ),
        FallBackRiskScore1,
        DeadLine
    ),
    RiskScore.

get_payment_info(
    #domain_ShopConfig{
        id = ShopID,
        category = CategoryRef,
        details = ShopDetails,
        location = Location
    },
    #domain_Invoice{
        owner_id = PartyID,
        id = InvoiceID,
        created_at = InvoiceCreatedAt,
        due = InvoiceDue,
        details = InvoiceDetails,
        client_info = ClientInfo
    },
    #domain_InvoicePayment{
        id = PaymentID,
        created_at = CreatedAt,
        domain_revision = Revision,
        payer = Payer,
        cost = Cost,
        make_recurrent = MakeRecurrent
    }
) ->
    Party = #proxy_inspector_Party{
        party_id = PartyID
    },
    ShopCategory = hg_domain:get(
        Revision,
        {category, CategoryRef}
    ),
    ProxyShop = #proxy_inspector_Shop{
        id = ShopID,
        category = ShopCategory,
        details = #domain_ShopDetails{
            name = ShopDetails#domain_Details.name,
            description = ShopDetails#domain_Details.description
        },
        location = Location
    },
    ProxyInvoice = #proxy_inspector_Invoice{
        id = InvoiceID,
        created_at = InvoiceCreatedAt,
        due = InvoiceDue,
        details = InvoiceDetails,
        client_info = ClientInfo
    },
    ProxyPayment = #proxy_inspector_InvoicePayment{
        id = PaymentID,
        created_at = CreatedAt,
        payer = Payer,
        cost = Cost,
        make_recurrent = MakeRecurrent
    },
    #proxy_inspector_PaymentInfo{
        party = Party,
        shop = ProxyShop,
        invoice = ProxyInvoice,
        payment = ProxyPayment
    }.

issue_call(Func, Args, CallOpts, Default, DeadLine) ->
    try hg_woody_wrapper:call(proxy_inspector, Func, Args, CallOpts, DeadLine) of
        {ok, _} = RiskScore ->
            RiskScore;
        {exception, Error} ->
            _ = logger:error("Fail to get RiskScore with error ~p", [Error]),
            {ok, Default}
    catch
        error:{woody_error, {_Source, Class, _Details}} = Reason when
            Class =:= resource_unavailable orelse
                Class =:= result_unknown
        ->
            _ = logger:warning("Fail to get RiskScore with error ~p:~p", [error, Reason]),
            {ok, Default};
        error:{woody_error, {_Source, result_unexpected, _Details}} = Reason ->
            _ = logger:error("Fail to get RiskScore with error ~p:~p", [error, Reason]),
            {ok, Default}
    end.

get_proxy_def(Ref, Revision) ->
    hg_domain:get(Revision, {proxy, Ref}).

%%

-spec compare_risk_score(risk_score(), risk_score()) -> risk_magnitude().
compare_risk_score(RS1, RS2) ->
    get_risk_magnitude(RS1) - get_risk_magnitude(RS2).

get_risk_magnitude(RiskScore) ->
    {enum, Info} = dmsl_domain_thrift:enum_info('RiskScore'),
    {RiskScore, Magnitude} = lists:keyfind(RiskScore, 1, Info),
    Magnitude.
