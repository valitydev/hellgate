%%% Invoice template machine

-module(hg_invoice_template).

-include_lib("damsel/include/dmsl_base_thrift.hrl").
-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payproc_thrift.hrl").

-define(NS, <<"invoice_template">>).

%% Woody handler called by hg_woody_service_wrapper
-behaviour(hg_woody_service_wrapper).

-export([handle_function/3]).

%% Machine callbacks
-behaviour(hg_machine).

-export([namespace/0]).

-export([init/2]).
-export([process_signal/2]).
-export([process_call/2]).
-export([process_repair/2]).

%% API

-export([get/1]).

-type tpl_id() :: dmsl_domain_thrift:'InvoiceTemplateID'().
-type tpl() :: dmsl_domain_thrift:'InvoiceTemplate'().

%% Internal types

-type invoice_template_change() :: dmsl_payproc_thrift:'InvoiceTemplateChange'().

%% API

-spec get(tpl_id()) -> tpl().
get(TplId) ->
    get_invoice_template(TplId).

get_invoice_template(ID) ->
    History = get_history(ID),
    _ = assert_invoice_template_not_deleted(lists:last(History)),
    collapse_history(History).

%% Woody handler

-spec handle_function(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function(Func, Args, Opts) ->
    scoper:scope(
        invoice_templating,
        fun() ->
            handle_function_(Func, Args, Opts)
        end
    ).

-spec handle_function_(woody:func(), woody:args(), hg_woody_service_wrapper:handler_opts()) -> term() | no_return().
handle_function_('Create', {Params}, _Opts) ->
    TplID = Params#payproc_InvoiceTemplateCreateParams.template_id,
    _ = set_meta(TplID),
    _Party = get_party(Params#payproc_InvoiceTemplateCreateParams.party_id),
    Shop = get_shop(
        Params#payproc_InvoiceTemplateCreateParams.shop_id,
        Params#payproc_InvoiceTemplateCreateParams.party_id
    ),
    ok = validate_create_params(Params, Shop),
    ok = start(TplID, Params),
    get_invoice_template(TplID);
handle_function_('Get', {TplID}, _Opts) ->
    _ = set_meta(TplID),
    get_invoice_template(TplID);
handle_function_('Update' = Fun, {TplID, Params} = Args, _Opts) ->
    _ = set_meta(TplID),
    Tpl = get_invoice_template(TplID),
    _ = get_party(Tpl#domain_InvoiceTemplate.party_ref),
    Shop = get_shop(Tpl#domain_InvoiceTemplate.shop_ref, Tpl#domain_InvoiceTemplate.party_ref),
    ok = validate_update_params(Params, Shop),
    call(TplID, Fun, Args);
handle_function_('Delete' = Fun, {TplID} = Args, _Opts) ->
    Tpl = get_invoice_template(TplID),
    _ = get_party(Tpl#domain_InvoiceTemplate.party_ref),
    _ = get_shop(Tpl#domain_InvoiceTemplate.shop_ref, Tpl#domain_InvoiceTemplate.party_ref),
    _ = set_meta(TplID),
    call(TplID, Fun, Args);
handle_function_('ComputeTerms', {TplID}, _Opts) ->
    _ = set_meta(TplID),
    Tpl = get_invoice_template(TplID),
    Cost =
        case Tpl#domain_InvoiceTemplate.details of
            {product, #domain_InvoiceTemplateProduct{price = {fixed, Cash}}} ->
                Cash;
            _ ->
                undefined
        end,
    Revision = hg_party:get_party_revision(),
    {PartyConfigRef, Party} = hg_party:checkout(Tpl#domain_InvoiceTemplate.party_ref, Revision),
    {#domain_ShopConfigRef{id = ShopConfigID}, Shop} = hg_party:get_shop(
        Tpl#domain_InvoiceTemplate.shop_ref,
        Tpl#domain_InvoiceTemplate.party_ref,
        Revision
    ),
    _ = assert_party_shop_operable(Shop, Party),
    VS = #{
        cost => Cost,
        shop_id => ShopConfigID,
        party_config_ref => PartyConfigRef,
        category => Shop#domain_ShopConfig.category,
        currency => hg_invoice_utils:get_shop_currency(Shop)
    },
    hg_invoice_utils:compute_shop_terms(
        Revision,
        Shop,
        VS
    ).

assert_party_shop_operable(Shop, Party) ->
    _ = hg_invoice_utils:assert_party_operable(Party),
    _ = hg_invoice_utils:assert_shop_operable(Shop),
    ok.

get_party(PartyConfigRef) ->
    {PartyConfigRef, Party} = hg_party:get_party(PartyConfigRef),
    _ = hg_invoice_utils:assert_party_operable(Party),
    Party.

get_shop(ShopConfigRef, PartyConfigRef) ->
    {ShopConfigRef, Shop} = hg_invoice_utils:assert_shop_exists(
        hg_party:get_shop(ShopConfigRef, PartyConfigRef, hg_party:get_party_revision())
    ),
    _ = hg_invoice_utils:assert_shop_operable(Shop),
    Shop.

set_meta(ID) ->
    scoper:add_meta(#{invoice_template_id => ID}).

validate_create_params(#payproc_InvoiceTemplateCreateParams{details = Details, mutations = Mutations}, Shop) ->
    ok = validate_details(Details, Mutations, Shop).

validate_update_params(#payproc_InvoiceTemplateUpdateParams{details = undefined}, _) ->
    ok;
validate_update_params(#payproc_InvoiceTemplateUpdateParams{details = Details, mutations = Mutations}, Shop) ->
    ok = validate_details(Details, Mutations, Shop).

validate_details({cart, #domain_InvoiceCart{}} = Details, Mutations, _) ->
    hg_invoice_mutation:validate_mutations(Mutations, Details);
validate_details({product, #domain_InvoiceTemplateProduct{price = Price}}, _, Shop) ->
    validate_price(Price, Shop).

validate_price({fixed, Cash}, Shop) ->
    hg_invoice_utils:validate_cost(Cash, Shop);
validate_price(
    {range,
        Range = #domain_CashRange{
            lower = {_, LowerCost},
            upper = {_, UpperCost}
        }},
    Shop
) ->
    ok = hg_invoice_utils:validate_cash_range(Range),
    ok = hg_invoice_utils:validate_cost(LowerCost, Shop),
    ok = hg_invoice_utils:validate_cost(UpperCost, Shop);
validate_price({unlim, _}, _Shop) ->
    ok.

start(ID, Params) ->
    EncodedParams = marshal_invoice_template_params(Params),
    map_start_error(hg_machine:start(?NS, ID, EncodedParams)).

call(ID, Function, Args) ->
    case hg_machine:thrift_call(?NS, ID, invoice_templating, {'InvoiceTemplating', Function}, Args) of
        ok ->
            ok;
        {ok, Reply} ->
            Reply;
        {exception, Exception} ->
            erlang:throw(Exception);
        {error, Error} ->
            map_error(Error)
    end.

get_history(TplID) ->
    unmarshal_history(map_history_error(hg_machine:get_history(?NS, TplID))).

-spec map_error(notfound | any()) -> no_return().
map_error(notfound) ->
    throw(#payproc_InvoiceTemplateNotFound{});
map_error(Reason) ->
    error(Reason).

map_start_error({ok, _}) ->
    ok;
map_start_error({error, Reason}) ->
    error(Reason).

map_history_error({ok, Result}) ->
    Result;
map_history_error({error, notfound}) ->
    throw(#payproc_InvoiceTemplateNotFound{}).

%% Machine

-type create_params() :: dmsl_payproc_thrift:'InvoiceTemplateCreateParams'().
-type call() :: hg_machine:thrift_call().

-define(tpl_created(InvoiceTpl),
    {invoice_template_created, #payproc_InvoiceTemplateCreated{invoice_template = InvoiceTpl}}
).

-define(tpl_updated(Diff),
    {invoice_template_updated, #payproc_InvoiceTemplateUpdated{diff = Diff}}
).

-define(tpl_deleted(),
    {invoice_template_deleted, #payproc_InvoiceTemplateDeleted{}}
).

assert_invoice_template_not_deleted({_, _, [?tpl_deleted()]}) ->
    throw(#payproc_InvoiceTemplateRemoved{});
assert_invoice_template_not_deleted(_) ->
    ok.

-spec namespace() -> hg_machine:ns().
namespace() ->
    ?NS.

-spec init(binary(), hg_machine:machine()) -> hg_machine:result().
init(EncodedParams, #{id := ID}) ->
    Params = unmarshal_invoice_template_params(EncodedParams),
    Tpl = create_invoice_template(ID, Params),
    #{events => [marshal_event_payload([?tpl_created(Tpl)])]}.

create_invoice_template(ID, P) ->
    #domain_InvoiceTemplate{
        id = ID,
        party_ref = P#payproc_InvoiceTemplateCreateParams.party_id,
        shop_ref = P#payproc_InvoiceTemplateCreateParams.shop_id,
        invoice_lifetime = P#payproc_InvoiceTemplateCreateParams.invoice_lifetime,
        product = P#payproc_InvoiceTemplateCreateParams.product,
        name = P#payproc_InvoiceTemplateCreateParams.name,
        description = P#payproc_InvoiceTemplateCreateParams.description,
        created_at = hg_datetime:format_now(),
        details = P#payproc_InvoiceTemplateCreateParams.details,
        context = P#payproc_InvoiceTemplateCreateParams.context,
        mutations = P#payproc_InvoiceTemplateCreateParams.mutations
    }.

-spec process_repair(hg_machine:args(), hg_machine:machine()) -> no_return().
process_repair(_Args, _Machine) ->
    erlang:error({not_implemented, repair}).

-spec process_signal(hg_machine:signal(), hg_machine:machine()) -> hg_machine:result().
process_signal(timeout, _Machine) ->
    #{};
process_signal({repair, _}, _Machine) ->
    #{}.

-spec process_call(call(), hg_machine:machine()) -> {hg_machine:response(), hg_machine:result()}.
process_call(Call, #{history := History}) ->
    St = collapse_history(unmarshal_history(History)),
    try handle_call(Call, St) of
        {ok, Changes} ->
            {ok, #{events => [marshal_event_payload(Changes)]}};
        {Reply, Changes} ->
            {{ok, Reply}, #{events => [marshal_event_payload(Changes)]}}
    catch
        throw:Exception ->
            {{exception, Exception}, #{}}
    end.

handle_call({{'InvoiceTemplating', 'Update'}, {_TplID, Params}}, Tpl) ->
    Changes = [?tpl_updated(Params)],
    {merge_changes(Changes, Tpl), Changes};
handle_call({{'InvoiceTemplating', 'Delete'}, {_TplID}}, _Tpl) ->
    {ok, [?tpl_deleted()]}.

collapse_history(History) ->
    lists:foldl(
        fun({_ID, _, Ev}, Tpl) -> merge_changes(Ev, Tpl) end,
        undefined,
        History
    ).

merge_changes([?tpl_created(Tpl)], _) ->
    Tpl;
merge_changes(
    [
        ?tpl_updated(#payproc_InvoiceTemplateUpdateParams{
            name = Name,
            invoice_lifetime = InvoiceLifetime,
            product = Product,
            description = Description,
            details = Details,
            context = Context,
            mutations = Mutations
        })
    ],
    Tpl
) ->
    Diff = [
        {name, Name},
        {invoice_lifetime, InvoiceLifetime},
        {product, Product},
        {description, Description},
        {details, Details},
        {context, Context},
        {mutations, Mutations}
    ],
    lists:foldl(fun update_field/2, Tpl, Diff).

update_field({_, undefined}, Tpl) ->
    Tpl;
update_field({invoice_lifetime, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{invoice_lifetime = V};
update_field({product, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{product = V};
update_field({name, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{name = V};
update_field({description, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{description = V};
update_field({details, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{details = V};
update_field({context, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{context = V};
update_field({mutations, V}, Tpl) ->
    Tpl#domain_InvoiceTemplate{mutations = V}.

%% Marshaling

-spec marshal_invoice_template_params(create_params()) -> binary().
marshal_invoice_template_params(Params) ->
    Type = {struct, struct, {dmsl_payproc_thrift, 'InvoiceTemplateCreateParams'}},
    hg_proto_utils:serialize(Type, Params).

-spec marshal_event_payload([invoice_template_change()]) -> hg_machine:event_payload().
marshal_event_payload(Changes) when is_list(Changes) ->
    wrap_event_payload({invoice_template_changes, Changes}).

wrap_event_payload(Payload) ->
    Type = {struct, union, {dmsl_payproc_thrift, 'EventPayload'}},
    Bin = hg_proto_utils:serialize(Type, Payload),
    #{
        format_version => 1,
        data => {bin, Bin}
    }.

%% Unmashaling

-spec unmarshal_invoice_template_params(binary()) -> create_params().
unmarshal_invoice_template_params(EncodedParams) ->
    Type = {struct, struct, {dmsl_payproc_thrift, 'InvoiceTemplateCreateParams'}},
    hg_proto_utils:deserialize(Type, EncodedParams).

-spec unmarshal_history([hg_machine:event()]) -> [hg_machine:event([invoice_template_change()])].
unmarshal_history(Events) ->
    [unmarshal_event(Event) || Event <- Events].

-spec unmarshal_event(hg_machine:event()) -> hg_machine:event([invoice_template_change()]).
unmarshal_event({ID, Dt, Payload}) ->
    {ID, Dt, unmarshal_event_payload(Payload)}.

-spec unmarshal_event_payload(hg_machine:event_payload()) -> [invoice_template_change()].
unmarshal_event_payload(#{format_version := 1, data := {bin, Changes}}) ->
    Type = {struct, union, {dmsl_payproc_thrift, 'EventPayload'}},
    {invoice_template_changes, Buf} = hg_proto_utils:deserialize(Type, Changes),
    Buf.
