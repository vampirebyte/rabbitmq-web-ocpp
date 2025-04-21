%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2025 VAMPIRE BYTE SRL. All Rights Reserved.
%%

-type option(T) :: undefined | T.

%% WebSocket Subprotocol Name Registry
%% https://www.iana.org/assignments/websocket/websocket.xml
-define(OCPP_SUPPORTED_PROTOCOLS, [<<"ocpp1.2">>, <<"ocpp1.5">>, <<"ocpp1.6">>, <<"ocpp2.0">>, <<"ocpp2.0.1">>, <<"ocpp2.1">>]).

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

-define(OCPP_MESSAGE_TYPE_CALL, 2). % Request
-define(OCPP_MESSAGE_TYPE_CALLRESULT, 3). % Response success
-define(OCPP_MESSAGE_TYPE_CALLERROR, 4). % Response error
-define(OCPP_MESSAGE_TYPE_CALLRESULTERROR, 5). % OCPP 2.1 only
-define(OCPP_MESSAGE_TYPE_SEND, 6). % OCPP 2.1 only

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