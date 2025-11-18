-module(ff_validator).

-include_lib("validator_personal_data_proto/include/validator_personal_data_validator_personal_data_thrift.hrl").
-include_lib("damsel/include/dmsl_base_thrift.hrl").

-define(SERVICE, {validator_personal_data_validator_personal_data_thrift, 'ValidatorPersonalDataService'}).

%% API
-export([validate_personal_data/1]).

-type personal_data_validation_response() :: #{
    validation_id := binary(),
    token := binary(),
    validation_status := valid | invalid
}.
-type personal_data_token() :: binary().

-spec validate_personal_data(personal_data_token()) -> {ok, personal_data_validation_response()} | {error, _Reason}.
validate_personal_data(PersonalToken) ->
    Args = {PersonalToken},
    Request = {?SERVICE, 'ValidatePersonalData', Args},
    case ff_woody_client:call(validator, Request) of
        {ok, Result} ->
            {ok, unmarshal(personal_data_validation, Result)};
        {exception, #validator_personal_data_PersonalDataTokenNotFound{}} ->
            {error, not_found};
        {exception, #base_InvalidRequest{}} ->
            {error, invalid_request}
    end.

%% Internal functions

unmarshal(personal_data_validation, #validator_personal_data_ValidationResponse{
    validation_id = ID,
    token = Token,
    validation_status = Status
}) ->
    #{
        validation_id => ID,
        token => Token,
        validation_status => Status
    }.
