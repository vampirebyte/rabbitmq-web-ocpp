%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2025 VAMPIRE BYTE SRL. All Rights Reserved.
%%
-module(rabbit_web_ocpp_processor).

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/logging.hrl").
-include("rabbit_web_ocpp.hrl"). % Keep for OCPP defines

-export([handle_text_frame/1]). % Takes only Data now

%% @doc Handles an incoming WebSocket text frame, decodes JSON, and validates the OCPP message structure.
%% Returns {ok, DecodedList} | {error, Reason :: binary()}.
-spec handle_text_frame(binary()) -> {ok, list()} | {error, binary()}.
handle_text_frame(Data) ->
    try json:decode(Data) of
        Decoded when is_list(Decoded) ->
            % Successfully decoded a JSON list, process it
            process_decoded_message(Decoded);
        _Other ->
            % Decoded JSON is not a list, which is invalid for OCPP
            ?LOG_ERROR("Web OCPP received unexpected JSON structure (not an array): ~ts", [Data]),
            {error, <<"Invalid JSON">>}
    catch
        % Handle JSON decoding errors
        error:Reason:Stacktrace ->
            ?LOG_ERROR("Web OCPP failed to decode JSON. Reason: ~tp, Data: ~ts, Stacktrace: ~tp",
                       [Reason, Data, Stacktrace]),
            {error, <<"Invalid JSON">>}
    end.

%% Internal function to process the already decoded list based on OCPP message type
%% Returns {ok, DecodedList} | {error, Reason :: binary()}.
-spec process_decoded_message(list()) -> {ok, list()} | {error, binary()}.
process_decoded_message([?OCPP_MESSAGE_TYPE_CALL, MessageId, Action, Payload] = Decoded) ->
    ?LOG_INFO("Processing CALL: Id=~tp, Action=~tp, Payload=~tp",
              [MessageId, Action, Payload]),
    %% TODO: Implement CALL message handling (e.g., routing to backend)
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLRESULT, MessageId, Payload] = Decoded) ->
    ?LOG_INFO("Processing CALLRESULT: Id=~tp, Payload=~tp",
              [MessageId, Payload]),
    %% TODO: Implement CALLRESULT message handling (e.g., routing response)
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLERROR, MessageId, ErrorCode, ErrorDescription, ErrorDetails] = Decoded) ->
    ?LOG_INFO("Processing CALLERROR: Id=~tp, Code=~tp, Desc=~tp, Details=~tp",
              [MessageId, ErrorCode, ErrorDescription, ErrorDetails]),
    %% TODO: Implement CALLERROR message handling (e.g., routing error)
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLRESULTERROR, MessageId, ErrorCode, ErrorDescription, ErrorDetails] = Decoded) -> % OCPP 2.1
    ?LOG_INFO("Processing CALLRESULTERROR: Id=~tp, Code=~tp, Desc=~tp, Details=~tp",
              [MessageId, ErrorCode, ErrorDescription, ErrorDetails]),
    %% TODO: Implement CALLRESULTERROR message handling
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_SEND, MessageId, Action, Payload] = Decoded) -> % OCPP 2.1
    ?LOG_INFO("Processing SEND: Id=~tp, Action=~tp, Payload=~tp",
              [MessageId, Action, Payload]),
    %% TODO: Implement SEND message handling
    {ok, Decoded};
process_decoded_message(Decoded) ->
    % The list structure doesn't match any known OCPP message type/format
    ?LOG_ERROR("Received invalid OCPP message structure: ~tp", [Decoded]),
    {error, <<"Invalid OCPP message structure">>}.

% %% Basic validation for decoded OCPP list structure
% -spec is_valid_ocpp_list(list()) -> boolean().
% is_valid_ocpp_list([Type, _MsgId, _Action, _Payload]) when Type =:= ?OCPP_MESSAGE_TYPE_CALL; Type =:= ?OCPP_MESSAGE_TYPE_SEND ->
%     true;
% is_valid_ocpp_list([Type, _MsgId, _Payload]) when Type =:= ?OCPP_MESSAGE_TYPE_CALLRESULT ->
%     true;
% is_valid_ocpp_list([Type, _MsgId, _ErrorCode, _ErrorDesc, _ErrorDetails]) when Type =:= ?OCPP_MESSAGE_TYPE_CALLERROR; Type =:= ?OCPP_MESSAGE_TYPE_CALLRESULTERROR ->
%     true;
% is_valid_ocpp_list(_) ->
%     false.b