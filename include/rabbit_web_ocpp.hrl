%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2025 VAMPIRE BYTE SRL. All Rights Reserved.
%%

-define(APP_NAME, rabbitmq_web_ocpp).
-define(PG_SCOPE, pg_scope_rabbitmq_web_ocpp_clientid).
-define(DEFAULT_IDLE_TIMEOUT_MS, 600_000). %% 10 minutes

-type option(T) :: undefined | T.
-type client_id() :: binary().
-type user_property() :: [{binary(), binary()}].

%% Close frame status codes as defined in
%% https://www.rfc-editor.org/rfc/rfc6455#section-7.4.1
-define(CLOSE_NORMAL, 1000).
-define(CLOSE_SERVER_GOING_DOWN, 1001).
-define(CLOSE_PROTOCOL_ERROR, 1002).
-define(CLOSE_UNACCEPTABLE_DATA_TYPE, 1003).
-define(CLOSE_INVALID_PAYLOAD, 1007).
-define(CLOSE_POLICY_VIOLATION, 1008). % e.g., unsupported subprotocol

%% WebSocket Subprotocol Name Registry
%% https://www.iana.org/assignments/websocket/websocket.xml
-define(OCPP_PROTO_V12, ocpp12).
-define(OCPP_PROTO_V15, ocpp15).
-define(OCPP_PROTO_V16, ocpp16).
-define(OCPP_PROTO_V20, ocpp20).
-define(OCPP_PROTO_V201, ocpp201).
-define(OCPP_PROTO_V21, ocpp21).

-type ocpp_protocol_version_atom() ::
        ?OCPP_PROTO_V12
        | ?OCPP_PROTO_V15
        | ?OCPP_PROTO_V16
        | ?OCPP_PROTO_V20
        | ?OCPP_PROTO_V201
        | ?OCPP_PROTO_V21.

-define(OCPP_PROTO_TO_ATOM(Proto), case Proto of
    <<"ocpp1.2">> -> ?OCPP_PROTO_V12;
    <<"ocpp1.5">> -> ?OCPP_PROTO_V15;
    <<"ocpp1.6">> -> ?OCPP_PROTO_V16;
    <<"ocpp2.0">> -> ?OCPP_PROTO_V20;
    <<"ocpp2.0.1">> -> ?OCPP_PROTO_V201;
    <<"ocpp2.1">> -> ?OCPP_PROTO_V21;
    _ -> undefined
end).

-define(OCPP_TCP_PROTOCOL, 'ws/ocpp').
-define(OCPP_TLS_PROTOCOL, 'wss/ocpp').

-define(OCPP_MESSAGE_TYPE_CALL, 2). % Request
-define(OCPP_MESSAGE_TYPE_CALLRESULT, 3). % Response success
-define(OCPP_MESSAGE_TYPE_CALLERROR, 4). % Response error
-define(OCPP_MESSAGE_TYPE_CALLRESULTERROR, 5). % OCPP 2.1 only
-define(OCPP_MESSAGE_TYPE_SEND, 6). % OCPP 2.1 only

%% Internal representation of an OCPP message
-record(ocpp_msg, {
    msg_type :: integer(), % Extracted MessageTypeID
    msg_id :: binary(), % Extracted MessageID (as binary string)
    action :: binary() | undefined, % Extracted Action for CALL/SEND types
    payload :: iolist(), % Original JSON payload
    client_id :: binary() % Originating CP identifier (e.g., from reply_to)
}).

-type ocpp_msg() :: #ocpp_msg{}.

-define(ITEMS,
        [pid,
         protocol,
         host,
         port,
         peer_host,
         peer_port,
         ssl,
         ssl_protocol,
         ssl_key_exchange,
         ssl_cipher,
         ssl_hash,
         vhost,
         user
        ]).

-define(INFO_ITEMS,
        ?ITEMS ++
        [
         client_id,
         conn_name,
         user_property,
         connection_state,
         ssl_login_name,
         recv_cnt,
         recv_oct,
         send_cnt,
         send_oct,
         send_pend,
         clean_sess,
         will_msg,
         retainer_pid,
         exchange,
         prefetch,
         messages_unconfirmed,
         messages_unacknowledged
        ]).

%% Connection opened or closed.
-define(EVENT_KEYS,
        ?ITEMS ++
        [name,
         client_properties,
         peer_cert_issuer,
         peer_cert_subject,
         peer_cert_validity,
         auth_mechanism,
         timeout,
         frame_max,
         channel_max,
         connected_at,
         node,
         user_who_performed_action
        ]).

-define(SIMPLE_METRICS,
        [pid,
         recv_oct,
         send_oct,
         reductions]).
-define(OTHER_METRICS,
        [recv_cnt,
         send_cnt,
         send_pend,
         garbage_collection,
         state]).