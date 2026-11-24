%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2025 VAMPIRE BYTE SRL. All Rights Reserved.
%%
-module(rabbit_web_ocpp_processor).

-feature(maybe_expr, enable).

-export([info/2,
         init/8,
         process_incoming/2,
         terminate/3,
         handle_info/2,
         handle_text_frame/2,
         format_status/1,
         proto_version_tuple/1
        ]).

-export_type([state/0,
              send_fun/0]).

-import(rabbit_misc, [maps_put_truthy/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit/include/amqqueue.hrl").
-include_lib("rabbit/include/mc.hrl").
-include("rabbit_web_ocpp.hrl").

%% --- Constants ---
-define(MAX_PERMISSION_CACHE_SIZE, 12).
-define(DEFAULT_EXCHANGE_NAME, <<"amq.topic">>). % Example exchange name
-define(CONSUMER_TAG_PREFIX, <<"ocpp.ctag-">>).
-define(QUEUE_KIND, ocpp). % Used for queue naming convention
-define(PREFETCH_COUNT, 1). % Default prefetch for the OCPP queue
-define(DUPLICATE_ID_KICK_TIMEOUT_MS, 3000). %% Wait for a kicked duplicate client ID to terminate.
-define(MAX_ACTION_BYTES, 239). %% Room left for the Action string segment of the routing key

%% --- Types ---

%% Function provided by the WebSocket handler to send data (Erlang term) to the client.
%% The function itself should handle JSON encoding.
-type send_fun() :: fun((Data :: term()) -> ok | {error, any()}).

-record(auth_state,
        {user :: #user{},
         authz_ctx :: #{binary() := binary()}
        }).

%% Simplified config compared to MQTT
-record(cfg, {
        socket :: rabbit_net:socket(),
        send_fun :: send_fun(),
        vhost :: rabbit_types:vhost(),
        client_id :: binary(), % Charge Point ID
        proto_ver :: ocpp_protocol_version_atom(),
        user :: #user{}, % Authenticated user details
        exchange :: rabbit_exchange:name(), % Exchange to publish *to* and bind *from*
        queue_name :: rabbit_amqqueue:name(), % The single queue for this client_id
        prefetch :: non_neg_integer(),
        conn_name :: option(binary()), % For logging/tracing
        user_prop :: user_property(),
        ip_addr :: inet:ip_address(),
        port :: inet:port_number(),
        peer_ip_addr :: inet:ip_address(),
        peer_port :: inet:port_number(),
        trace_state :: rabbit_trace:state(),
        consumer_tag :: binary(),
        connected_at :: pos_integer()
}).

-record(state, {
    cfg :: #cfg{},
    queue_states :: rabbit_queue_type:state(), % State for managing the queue consumer
    auth_state :: #auth_state{}, % Re-use auth_state structure
    %% Outbound WebSocket frames accumulated during a single handle_info/2 call,
    %% drained and returned to cowboy in one go. Stored in reverse order.
    pending_frames = [] :: [cowboy_websocket:frame()]
}).

-opaque state() :: #state{}.

%% --- Public API ---
-spec init(Vhost :: rabbit_types:vhost(),
           ClientId :: binary(),
           ProtoVer :: ocpp_protocol_version_atom(),
           RawSocket :: rabbit_net:socket(),
           ConnectionName :: binary(),
           User :: #user{},
           AuthzCtx :: #{binary() := binary()},
           SendFun :: send_fun()) ->
    {ok, state()} | {error, term()}.
init(Vhost, ClientId, ProtoVer, Socket, ConnName0, User, AuthzCtx, SendFun) ->
    %% Check whether peer closed the connection.
    %% For example, this can happen when connection was blocked because of resource
    %% alarm and client therefore disconnected.
    case rabbit_net:socket_ends(Socket, inbound) of
        {ok, SocketEnds} ->
            process_connect(Vhost, ClientId, ProtoVer, Socket, ConnName0, User, AuthzCtx, SendFun, SocketEnds);
        {error, Reason} ->
            {error, {socket_ends, Reason}}
    end.

process_connect(Vhost, ClientId, ProtoVer, Socket, ConnName0, User, AuthzCtx, SendFun, {PeerIp, PeerPort, Ip, Port}) ->
    case rabbit_net:socket_ends(Socket, inbound) of
        {ok, SocketEnds} ->
            {PeerIp, PeerPort, Ip, Port} = SocketEnds;
        {error, SocketEndsReason} ->
            {error, {socket_ends, SocketEndsReason}}
    end,

    %% 2. Authentication & Authorization
    Result =
        maybe
            ok = register_client_id(Vhost, ClientId),
            rabbit_core_metrics:auth_attempt_succeeded(PeerIp, ClientId, ocpp),

            %% 3. Setup Resources
            ExchangeNameBin = rabbit_data_coercion:to_binary(
                                application:get_env(?APP_NAME, exchange, ?DEFAULT_EXCHANGE_NAME)),
            ExchangeName = rabbit_misc:r(Vhost, exchange, ExchangeNameBin),
            QueueName = queue_name(Vhost, ClientId),
            Prefetch = application:get_env(?APP_NAME, prefetch_count, ?PREFETCH_COUNT),
            {TraceState, ConnName} = init_trace(Vhost, ConnName0),
            ConnectedAt = os:system_time(millisecond),

            AuthState = #auth_state{user = User, authz_ctx = AuthzCtx},
            Cfg = #cfg{socket = Socket,
                       ip_addr = Ip,
                       port = Port,
                       peer_ip_addr = PeerIp,
                       peer_port = PeerPort,
                       send_fun = SendFun,
                       vhost = Vhost,
                       client_id = ClientId,
                       proto_ver = ProtoVer,
                       user = User,
                       user_prop = [],
                       exchange = ExchangeName,
                       queue_name = QueueName,
                       prefetch = Prefetch,
                       conn_name = ConnName,
                       trace_state = TraceState,
                       consumer_tag = consumer_tag(ConnectedAt),
                       connected_at = ConnectedAt},
            InitialState = #state{cfg = Cfg,
                                  queue_states = rabbit_queue_type:init(),
                                  auth_state = AuthState},

            {ok, StateAfterQueue} ?= ensure_queue_and_binding(InitialState),
            {ok, FinalState} ?= consume_from_queue(StateAfterQueue),

            %% Register the connection and let the handler emit connection_created
            %% only now that the connection is fully established (consume_from_queue succeeded).
            ok = rabbit_networking:register_non_amqp_connection(self()),
            rabbit_global_counters:publisher_created(ProtoVer),
            rabbit_global_counters:consumer_created(ProtoVer),
            self() ! connection_created,

            ?LOG_INFO("OCPP connection ~ts established for ClientId ~ts on vhost ~ts",
                      [ConnName0, ClientId, Vhost]),
            {ok, FinalState}
        else
            {error, Reason} ->
                ?LOG_ERROR("OCPP connection failed for ClientId ~ts: ~p", [ClientId, Reason]),
                {error, Reason} % Return the error reason
        end,
    Result.

%% Process incoming OCPP message (parsed list + raw binary)
-spec process_incoming(McOcpp :: #ocpp_msg{}, state()) ->
    {ok, state(), [cowboy_websocket:frame()]} | {error, term(), state()}.
process_incoming(McOcpp = #ocpp_msg{},
                State = #state{cfg = #cfg{exchange = ExchangeName = #resource{name = ExchangeNameBin},
                                                    client_id = ClientId,
                                                    proto_ver = ProtoVer,
                                                    trace_state = TraceState,
                                                    conn_name = ConnName},
                                         auth_state = #auth_state{user = #user{username = Username}}}) ->

    %% 1. Generate structured routing key (protocolver.actionname.req/conf)
    RoutingKey = generate_routing_key(McOcpp, State),

    %% 2. Check Publish Permissions (on Exchange and Topic/Routing Key)
    case check_publish_permitted(ExchangeName, RoutingKey, State) of
        ok ->
            %% 3. Validate Exchange
            case rabbit_exchange:lookup(ExchangeName) of
                {ok, Exchange} ->
                    
                    %% 4. Prepare annotations and initialize Message Container (mc) with mc_ocpp type
                    Anns = #{?ANN_EXCHANGE => ExchangeNameBin,
                             ?ANN_ROUTING_KEYS => [RoutingKey]},
                    McMsg = mc:init(mc_ocpp, McOcpp, Anns, #{}),
                    ?LOG_DEBUG("Created message container for ClientId ~ts with routing key ~ts: ~tp", 
                                [ClientId, RoutingKey, McMsg]),
                    
                    %% 5. Publish to the exchange with the structured routing key
                    case rabbit_exchange:route(Exchange, McMsg, #{}) of
                        [] ->
                            ?LOG_WARNING("OCPP message from ClientId ~ts routed to 0 queues. "
                                        "Exchange: ~ts, routing key: ~ts",
                                        [ClientId, rabbit_misc:rs(ExchangeName), RoutingKey]),
                            rabbit_global_counters:messages_unroutable_dropped(ProtoVer, 1),
                            drain_frames(reply_unroutable(McOcpp, State));
                        QNames when is_list(QNames) ->
                            %% 6. Trace (optional)
                            rabbit_trace:tap_in(McMsg, QNames, ConnName, Username, TraceState),
                            ?LOG_DEBUG("OCPP message routed to ~p queues for ClientId ~ts: ~p",
                                        [length(QNames), ClientId, QNames]),
                            drain_frames(deliver_to_queues(McMsg, #{}, QNames, State));
                        {error, Reason} ->
                            ?LOG_ERROR("OCPP failed to route message via exchange ~ts: ~p",
                                        [rabbit_misc:rs(ExchangeName), Reason]),
                            {error, publish_failed, State}
                    end;
                {error, not_found} ->
                    ?LOG_ERROR("Exchange ~ts does not exist for ClientId ~ts", [rabbit_misc:rs(ExchangeName), ClientId]),
                    {error, exchange_not_found, State}
            end;
        {error, access_refused} ->
            ?LOG_WARNING("OCPP publish refused for ClientId ~ts to exchange ~ts", [ClientId, rabbit_misc:rs(ExchangeName)]),
            {error, access_refused, State}
    end.

%% Answers a CALL that no queue is bound for, so that the charge point does
%% not wait for its timeout.
reply_unroutable(#ocpp_msg{msg_type = ?OCPP_MESSAGE_TYPE_CALL, msg_id = MsgId,
                           action = Action}, State)
  when is_binary(Action) ->
    buffer_frame(call_error(MsgId, <<"NotImplemented">>,
                            <<"No handler for action ", Action/binary>>), State);
reply_unroutable(_, State) ->
    State.

deliver_to_queues(Message,
                  Options,
                  RoutedToQNames,
                  State0 = #state{queue_states = QStates0,
                                  cfg = #cfg{proto_ver = ProtoVer}}) ->
    FilteredQNames = drop_local(RoutedToQNames, State0),
    Qs0 = lookup_queue_targets(FilteredQNames),
    Qs = rabbit_amqqueue:prepend_extra_bcc(Qs0),
    ?LOG_DEBUG("Delivering to queue ~p with state ~p", [Qs, QStates0]),
    case rabbit_queue_type:deliver(Qs, Message, Options, QStates0) of
        {ok, QStates, Actions} ->
            rabbit_global_counters:messages_routed(ProtoVer, length(Qs)),
            % State = process_routing_confirm(Options, Qs,
            %                                 State0#state{queue_states = QStates}),
            %% Actions must be processed after registering confirms as actions may
            %% contain rejections of publishes.
            handle_queue_actions(Actions, State0#state{queue_states = QStates});
        {error, Reason} ->
            Corr = maps:get(correlation, Options, undefined),
            ?LOG_ERROR("Failed to deliver message with packet_id=~p to queues: ~p",
                       [Corr, Reason]),
            State0
    end.

%% OCPP Messages MUST NOT be forwarded to a connection with a ClientID
%% equal to the ClientID of the publishing connection.
drop_local(QNames, #state{cfg = #cfg{queue_name = OwnQueueName}}) ->
    lists:filter(fun(QName) -> QName =/= OwnQueueName end, QNames);
drop_local(QNames, _) ->
    QNames.

lookup_queue_targets(QNames) ->
    case erlang:function_exported(rabbit_db_queue, get_targets, 1) of
        true ->
            %% RabbitMQ v4.2.x
            rabbit_db_queue:get_targets(QNames);
        false ->
            %% RabbitMQ <= v4.1.x
            rabbit_amqqueue:lookup_many(QNames)
    end.

-spec register_client_id(rabbit_types:vhost(), client_id()) -> ok.
register_client_id(Vhost, ClientId)
  when is_binary(Vhost), is_binary(ClientId) ->
    PgGroup = {Vhost, ClientId},
    %% "Last connection wins" without any per-connect cluster-wide calls,
    %% relying on the shared pg scope replicating memberships to all nodes:
    %%
    %% The monitor is installed *before* joining, so the event stream is
    %% complete: a member never sees joins that happened before its own
    %% monitor, therefore only an *older* connection can observe the join
    %% of a newer one, upon which it closes itself (see the corresponding
    %% websocket_info clauses in rabbit_web_ocpp_handler). This also
    %% converges after a network partition heals, when pg re-syncs
    %% memberships, something an erpc broadcast at connect time misses.
    {_Ref, Members} = pg:monitor(?PG_SCOPE, PgGroup),
    ok = pg:join(?PG_SCOPE, PgGroup, self()),
    %% Disconnect the already-known members and wait for them to die.
    %% A 'DOWN' fires only after the old connection fully terminated, i.e.
    %% after it published its final offline status and its exit released
    %% the exclusive consumer, so this connection is ready to bind, consume
    %% and announce itself the moment the monitor fires.
    lists:foreach(fun(Pid) ->
                          MRef = erlang:monitor(process, Pid),
                          gen_server:cast(Pid, {duplicate_id}),
                          receive
                              {'DOWN', MRef, process, Pid, _} -> ok
                          after ?DUPLICATE_ID_KICK_TIMEOUT_MS ->
                              erlang:demonitor(MRef, [flush]),
                              ?LOG_WARNING("Web OCPP connection ~p with duplicate "
                                           "client ID did not terminate in ~bms",
                                           [Pid, ?DUPLICATE_ID_KICK_TIMEOUT_MS])
                          end
                  end, Members -- [self()]).

-spec consumer_tag(pos_integer()) -> binary().
consumer_tag(ConnectedAt) ->
    %% The unique integer disambiguates same-millisecond reconnects.
    Unique = erlang:unique_integer([positive]),
    <<?CONSUMER_TAG_PREFIX/binary, (integer_to_binary(ConnectedAt))/binary,
      ".", (integer_to_binary(Unique))/binary>>.

%% Handle internal messages, queue events, etc.
-spec handle_info(term(), state()) -> {ok, state(), cowboy_websocket:commands()} | {stop, term(), state()}.
handle_info({queue_event, QName, Evt}, State = #state{queue_states = QStates0}) ->
    case rabbit_queue_type:handle_event(QName, Evt, QStates0) of
        {ok, QStates, Actions} ->
            State1 = State#state{queue_states = QStates},
            drain_frames(handle_queue_actions(Actions, State1));
        {protocol_error, _, _, _} = Error ->
            {stop, {shutdown, Error}, State};
        {eol, Actions} -> % Queue deleted or gone
             State1 = handle_queue_actions(Actions, State),
             QStates = rabbit_queue_type:remove(QName, QStates0),
             drain_frames(State1#state{queue_states = QStates});
        Other ->
             ?LOG_WARNING("Unhandled queue event for ~ts: ~p", [rabbit_misc:rs(QName), Other]),
             drain_frames(State)
    end;

%% The consumer cannot be re-established on a queue that is down, so close
%% the connection and let the charge point reconnect and consume again.
handle_info({{'DOWN', QName}, _, process, Pid, Reason},
            State = #state{cfg = #cfg{queue_name = QName, client_id = ClientId}}) ->
    ?LOG_WARNING("OCPP queue ~ts consumed by ClientId ~ts went down (~p): ~p",
                 [rabbit_misc:rs(QName), ClientId, Pid, Reason]),
    {stop, {shutdown, consumed_queue_down}, State};
handle_info({{'DOWN', QName}, _, process, Pid, Reason}, State = #state{queue_states = QStates0}) ->
    case rabbit_queue_type:handle_down(Pid, QName, Reason, QStates0) of
        {ok, QStates1, Actions} ->
            State1 = State#state{queue_states = QStates1},
            drain_frames(handle_queue_actions(Actions, State1));
        {eol, QStates1, QRef} ->
            QStates = rabbit_queue_type:remove(QRef, QStates1),
            drain_frames(State#state{queue_states = QStates});
        _ ->
            drain_frames(State)
    end;

handle_info(connection_closed, State) -> % Message from RabbitMQ core if underlying socket closes
    ?LOG_INFO("OCPP underlying connection closed notification received."),
    {stop, normal, State};

handle_info(Msg, State = #state{cfg = #cfg{client_id = ClientId}}) ->
    ?LOG_WARNING("OCPP processor for ~ts received unknown message: ~p", [ClientId, Msg]),
    drain_frames(State).

%% Drain accumulated outbound frames and return them to the caller along with
%% a state that no longer holds them.
drain_frames(State = #state{pending_frames = Frames}) ->
    {ok, State#state{pending_frames = []}, lists:reverse(Frames)}.

%% Terminate the processor
-spec terminate(any(), rabbit_event:event_props(), state()) -> ok.
terminate(Reason, Infos, State = #state{queue_states = QStates,
                                        cfg = #cfg{client_id = ClientId,
                                                   proto_ver = ProtoVer}}) ->
    ?LOG_INFO("OCPP processor terminating. ClientId: ~ts, Reason: ~p", [ClientId, Reason]),
    %% Whatever the reason for the disconnect, tell the backends the charge
    %% point went offline with one final synthetic StatusNotification. On a
    %% duplicate client ID kick this runs before the new connection
    %% proceeds (see register_client_id/2), so the subsequent online status
    %% is never overtaken by this one.
    publish_offline_status(State),
    ok = rabbit_queue_type:close(QStates), % Stop consuming
    rabbit_global_counters:publisher_deleted(ProtoVer),
    rabbit_global_counters:consumer_deleted(ProtoVer),
    rabbit_core_metrics:connection_closed(self()),
    rabbit_event:notify(connection_closed, Infos),
    ok = rabbit_networking:unregister_non_amqp_connection(self()),
    %% Note: We typically DO NOT delete the durable queue on disconnect for OCPP.
    %% It should persist messages while the CP is offline.
    ok.

%% Publishes a synthetic StatusNotification CALL marking the whole
%% charge point (connectorId 0) Unavailable/Offline, using the
%% OCPP version schema the CP was originally connected with.
-spec publish_offline_status(state()) -> ok.
publish_offline_status(State = #state{cfg = #cfg{client_id = ClientId,
                                                 proto_ver = ProtoVer}}) ->
    MsgId = list_to_binary(rabbit_guid:to_string(rabbit_guid:gen())),
    Timestamp = list_to_binary(
                  calendar:system_time_to_rfc3339(os:system_time(second),
                                                  [{offset, "Z"}])),
    Payload = case proto_version_tuple(ProtoVer) of
                  {1, _} -> % OCPP 1.x StatusNotification.req
                      #{<<"connectorId">> => 0,
                        <<"status">> => <<"Unavailable">>,
                        <<"errorCode">> => <<"NoError">>,
                        <<"timestamp">> => Timestamp,
                        <<"vendorId">> => <<"rabbitmq">>,
                        <<"vendorErrorCode">> => <<"Offline">>};
                  _ -> % OCPP 2.x StatusNotificationRequest
                      #{<<"timestamp">> => Timestamp,
                        <<"connectorStatus">> => <<"Unavailable">>,
                        <<"evseId">> => 0,
                        <<"connectorId">> => 0,
                        <<"customData">> => #{<<"vendorId">> => <<"rabbitmq">>,
                                              <<"vendorErrorCode">> => <<"Offline">>}}
              end,
    Frame = iolist_to_binary(json:encode([?OCPP_MESSAGE_TYPE_CALL, MsgId,
                                          <<"StatusNotification">>, Payload])),
    McOcpp = #ocpp_msg{msg_type = ?OCPP_MESSAGE_TYPE_CALL,
                       msg_id = MsgId,
                       action = <<"StatusNotification">>,
                       payload = Frame,
                       client_id = ClientId},
    try process_incoming(McOcpp, State) of
        {ok, _, _} ->
            ok;
        {error, Err, _} ->
            ?LOG_WARNING("OCPP offline StatusNotification for ClientId ~ts failed: ~p",
                         [ClientId, Err])
    catch Class:Err ->
        ?LOG_WARNING("OCPP offline StatusNotification for ClientId ~ts failed: ~p:~p",
                     [ClientId, Class, Err])
    end.

%% --- Internal Functions ---

%% @doc Generates a structured routing key in the format: protocolver.actionname.req/conf/error
%% Examples: "ocpp16.BootNotification.req", "ocpp16.Heartbeat.conf", "ocpp201.StatusNotification.req"
-spec generate_routing_key(#ocpp_msg{}, state()) -> binary().
generate_routing_key(#ocpp_msg{msg_type = MsgType, action = Action}, 
                     #state{cfg = #cfg{proto_ver = ProtoVer}}) ->
    %% Convert protocol version atom to binary string
    ProtoVerBin = atom_to_binary(ProtoVer, utf8),

    %% Handle action name (may be undefined for responses). The Action is client input
    %% with no restrictions in OCPP so we need to clean it up for routing key usage.
    ActionBin = case Action of
        undefined -> <<"response">>;  % For CALLRESULT/CALLERROR without action
        ActionName when is_binary(ActionName) ->
            case re:replace(ActionName, "[^A-Za-z0-9]", "", [global, {return, binary}]) of
                <<>> -> <<"unknown">>;
                <<Trimmed:?MAX_ACTION_BYTES/binary, _/binary>> -> Trimmed;
                Clean -> Clean
            end;
        _ -> <<"unknown">>
    end,

    %% Determine message direction (req/conf/error)
    MsgTypeBin = case MsgType of
        ?OCPP_MESSAGE_TYPE_CALL -> <<"req">>;      % Request from charge point
        ?OCPP_MESSAGE_TYPE_SEND -> <<"req">>;      % Request in OCPP 2.1
        ?OCPP_MESSAGE_TYPE_CALLRESULT -> <<"conf">>; % Response/confirmation
        ?OCPP_MESSAGE_TYPE_CALLERROR -> <<"error">>; % Error response
        ?OCPP_MESSAGE_TYPE_CALLRESULTERROR -> <<"error">>; % Error in OCPP 2.1
        _ -> <<"unknown">>
    end,

    %% Construct routing key: ocpp<protocolver>.<actionname>.req|conf|error
    <<ProtoVerBin/binary, ".", ActionBin/binary, ".", MsgTypeBin/binary>>.

%% Handle actions resulting from queue events (deliveries, etc.)
handle_queue_actions([], State) -> State;
handle_queue_actions([{deliver, _ConsumerTag, AckRequired, Msgs} | Rest], State) ->
    ?LOG_DEBUG("OCPP handling 'deliver' action. AckRequired: ~p, Msgs: ~tp", [AckRequired, Msgs]),
    State1 = deliver_to_client(Msgs, AckRequired, State),
    handle_queue_actions(Rest, State1);
handle_queue_actions([{settled, _QName, _MsgIds} | Rest], State) ->
    ?LOG_DEBUG("OCPP handling 'settled' action for MsgIds: ~tp", [_MsgIds]),
    handle_queue_actions(Rest, State);
handle_queue_actions([{block, QName} | Rest], State = #state{cfg = #cfg{client_id=ClientId}}) ->
    ?LOG_WARNING("OCPP queue ~ts blocked for ClientId ~ts", [QName, ClientId]),
    handle_queue_actions(Rest, State);
handle_queue_actions([{unblock, QName} | Rest], State = #state{cfg = #cfg{client_id=ClientId}}) ->
     ?LOG_INFO("OCPP queue ~ts unblocked for ClientId ~ts", [QName, ClientId]),
    handle_queue_actions(Rest, State);
handle_queue_actions([Action | Rest], State) ->
    ?LOG_DEBUG("OCPP unhandled queue action: ~p", [Action]),
    handle_queue_actions(Rest, State).

%% Deliver messages from the queue to the OCPP client via WebSocket.
%% Outbound frames are buffered into State#state.pending_frames and drained
%% by handle_info/2, which returns them directly to cowboy. This avoids the
%% prior `self() ! {reply, Data}` indirection.
deliver_to_client([], _AckRequired, State) -> State;
deliver_to_client([{QName, QPid, QMsgId, Redelivered, Mc} | Rest], AckRequired,
                  State = #state{cfg = #cfg{client_id = ClientId,
                                            trace_state = TraceState, conn_name = ConnName,
                                            consumer_tag = ConsumerTag},
                                 queue_states = QStates0,
                                 auth_state = #auth_state{user = User}}) ->
    try
        McOcpp = mc:convert(mc_ocpp, Mc, mc_env()),
        case mc:protocol_state(McOcpp) of
             #ocpp_msg{payload = BinaryPayload} when is_binary(BinaryPayload) ->
                ?LOG_DEBUG("OCPP delivering message to ~ts for QMsgId ~p", [ClientId, QMsgId]),
                rabbit_trace:tap_out({QName, QPid, QMsgId, Redelivered, Mc}, ConnName, User#user.username, TraceState),
                {ok, QStates1, Actions1} = rabbit_queue_type:settle(
                    QName, complete, ConsumerTag, [QMsgId], QStates0),
                message_delivered(QName, Redelivered, State),
                State1 = buffer_frame({text, BinaryPayload}, State#state{queue_states = QStates1}),
                State2 = handle_queue_actions(Actions1, State1),
                ok = maybe_notify_sent(QName, QPid, State2),
                deliver_to_client(Rest, AckRequired, State2);
            Other ->
                ?LOG_ERROR("OCPP delivery error: Expected #ocpp_msg{} record but got ~tp", [Other]),
                {ok, QStates3, Actions3} = rabbit_queue_type:settle(
                    QName, discard, ConsumerTag, [QMsgId], QStates0),
                State4 = handle_queue_actions(Actions3, State#state{queue_states = QStates3}),
                deliver_to_client(Rest, AckRequired, State4)
        end
    catch Class:Reason:Stacktrace ->
        ?LOG_ERROR("OCPP error delivering message to ~ts: ~p:~p~n~p",
                   [ClientId, Class, Reason, Stacktrace]),
        State5 = case rabbit_queue_type:settle(
                        QName, discard, ConsumerTag, [QMsgId], QStates0) of
                     {ok, QStates4, Actions4} ->
                         handle_queue_actions(Actions4, State#state{queue_states = QStates4});
                     SettleErr ->
                         ?LOG_ERROR("OCPP failed to discard message for ~ts: ~p",
                                    [ClientId, SettleErr]),
                         State
                 end,
        deliver_to_client(Rest, AckRequired, State5)
    end.

buffer_frame(Frame, State = #state{pending_frames = Frames}) ->
    State#state{pending_frames = [Frame | Frames]}.

%% The message is settled as soon as it is sent, so it counts as both
%% delivered with a manual ack and acknowledged.
message_delivered(QName, Redelivered, #state{queue_states = QStates,
                                             cfg = #cfg{proto_ver = ProtoVer}}) ->
    case rabbit_queue_type:module(QName, QStates) of
        {ok, QType} ->
            rabbit_global_counters:messages_delivered(ProtoVer, QType, 1),
            rabbit_global_counters:messages_delivered_consume_manual_ack(ProtoVer, QType, 1),
            rabbit_global_counters:messages_acknowledged(ProtoVer, QType, 1),
            case Redelivered of
                true -> rabbit_global_counters:messages_redelivered(ProtoVer, QType, 1);
                false -> ok
            end;
        _ ->
            ok
    end.

maybe_notify_sent(QName, QPid, #state{queue_states = QStates}) ->
    case rabbit_queue_type:module(QName, QStates) of
        {ok, rabbit_classic_queue} ->
            rabbit_amqqueue:notify_sent(QPid, self());
        _ ->
            ok
    end.

%% Ensure the queue exists and is bound
-spec ensure_queue_and_binding(state()) -> {ok, state()} | {error, term()}.
ensure_queue_and_binding(State = #state{cfg = #cfg{queue_name = QName,
                                                         exchange = _ExchangeName,
                                                         client_id = _ClientId,
                                                         vhost = Vhost}, % Need Vhost
                                        auth_state = #auth_state{user = User = #user{username = Username}, % Need Username
                                                                 authz_ctx = AuthzCtx}}) -> % Need AuthzCtx
    %% 1. Check configure permission first
    case check_resource_access(User, QName, configure, AuthzCtx) of
        ok ->
            QArgs = [], % Define QArgs
            %% Check DLX permissions if DLX args are present (simplified check)
            case case rabbit_misc:table_lookup(QArgs, <<"x-dead-letter-exchange">>) of
                     undefined -> ok; % No DLX, proceed
                     {longstr, XNameBin} ->
                         XName = #resource{virtual_host = Vhost, kind = exchange, name = XNameBin},
                         check_resource_access(User, XName, write, AuthzCtx)
                 end of
                ok -> % DLX check passed or not needed
                    %% 2. Declare the queue, unless it is already there
                    case ensure_queue(QName, QArgs, Vhost, Username) of
                        ok ->
                            bind_queue(State); % Proceed to binding
                        {error, _} = Error ->
                            Error
                    end;
                {error, access_refused} -> % DLX permission failed
                    ?LOG_WARNING("OCPP DLX permission refused for queue ~ts", [rabbit_misc:rs(QName)]),
                    {error, {queue_declare_failed, access_refused}}
            end; % End of DLX check case
        {error, access_refused} ->
            ?LOG_WARNING("OCPP configure permission refused for queue ~ts", [rabbit_misc:rs(QName)]),
            {error, {queue_declare_failed, access_refused}}
    end.

%% Declaring a classic queue always starts a queue process, which then writes
%% to the metadata store even when the queue turns out to already exist. Under
%% a connection storm that write is what times out, so look the queue up first
%% and only declare when it is missing, the way rabbit_mqtt_processor does.
-spec ensure_queue(rabbit_amqqueue:name(), rabbit_framing:amqp_table(),
                   rabbit_types:vhost(), rabbit_types:username()) ->
    ok | {error, term()}.
ensure_queue(QName, QArgs, Vhost, Username) ->
    case rabbit_amqqueue:lookup(QName) of
        {ok, _Q} ->
            ?LOG_DEBUG("OCPP queue ~ts already exists, proceeding to bind.",
                       [rabbit_misc:rs(QName)]),
            ok;
        {error, not_found} ->
            declare_queue(QName, QArgs, Vhost, Username)
    end.

-spec declare_queue(rabbit_amqqueue:name(), rabbit_framing:amqp_table(),
                    rabbit_types:vhost(), rabbit_types:username()) ->
    ok | {error, term()}.
declare_queue(QName, QArgs, Vhost, Username) ->
    QType = rabbit_amqqueue:get_queue_type(QArgs),
    Owner = none,
    Durable = true,
    AutoDelete = false,
    Q0 = amqqueue:new(QName, none, Durable, AutoDelete, Owner, QArgs, Vhost,
                      #{user => Username}, QType),
    case rabbit_queue_type:declare(Q0, node()) of
        {new, _Queue} ->
            rabbit_core_metrics:queue_created(QName),
            ok;
        {existing, _ExistingQ} ->
            %% Another connection won the race between the lookup and here.
            ?LOG_DEBUG("OCPP queue ~ts already exists, proceeding to bind.",
                       [rabbit_misc:rs(QName)]),
            ok;
        {error, queue_limit_exceeded, Reason, ReasonArgs} ->
            ?LOG_ERROR(Reason, ReasonArgs),
            {error, {queue_declare_failed, queue_limit_exceeded}};
        Other ->
            ?LOG_ERROR("Failed to declare OCPP queue ~s: ~p",
                       [rabbit_misc:rs(QName), Other]),
            {error, {queue_declare_failed, queue_declare_error}}
    end.

%% Helper function for binding logic
-spec bind_queue(state()) -> {ok, state()} | {error, term()}.
bind_queue(State = #state{cfg = #cfg{queue_name = QName,
                                      exchange = ExchangeName,
                                      client_id = ClientId},
                          auth_state = #auth_state{user = User}}) ->
    BindingArgs = [],
    RoutingKey = ClientId,
    Binding = #binding{source = ExchangeName, destination = QName,
                       key = RoutingKey, args = BindingArgs},
    case check_binding_permitted(QName, ExchangeName, RoutingKey, State) of
        ok ->
            %% Adding an existing binding would still write to the metadata store.
            Result = case rabbit_binding:exists(Binding) of
                         true -> ok;
                         _ -> rabbit_binding:add(Binding, User#user.username)
                     end,
            case Result of
                ok ->
                    ?LOG_DEBUG("OCPP queue ~ts bound to ~ts with key ~ts",
                              [rabbit_misc:rs(QName), rabbit_misc:rs(ExchangeName), RoutingKey]),
                    {ok, State};
                {error, Reason} ->
                    ?LOG_ERROR("OCPP failed to bind queue ~ts to ~ts: ~p",
                              [rabbit_misc:rs(QName), rabbit_misc:rs(ExchangeName), Reason]),
                    {error, {binding_failed, Reason}}
            end;
        {error, access_refused} ->
            ?LOG_WARNING("OCPP binding permission refused for queue ~ts / exchange ~ts",
                         [rabbit_misc:rs(QName), rabbit_misc:rs(ExchangeName)]),
            {error, {binding_failed, access_refused}}
    end.

%% Start consuming from the queue
-spec consume_from_queue(state()) -> {ok, state()} | {error, term()}.
consume_from_queue(State = #state{cfg = #cfg{queue_name = QName, client_id = ClientId,
                                             prefetch = Prefetch, consumer_tag = ConsumerTag},
                                  queue_states = QStates0,
                                  auth_state = #auth_state{user = User, authz_ctx = AuthzCtx}}) ->
    %% Check read permission on the queue
    case check_resource_access(User, QName, read, AuthzCtx) of
        ok ->
            ?LOG_DEBUG("OCPP about to consume from queue ~ts with prefetch ~p for ClientId ~ts",
                      [rabbit_misc:rs(QName), Prefetch, ClientId]),
            Spec = #{no_ack => false, % We need manual acks
                     channel_pid => self(),
                     limiter_pid => none, % Use basic prefetch
                     limiter_active => false,
                     mode => {simple_prefetch, Prefetch},
                     consumer_tag => ConsumerTag,
                     exclusive_consume => true, % Allow other consumers? (false for OCPP)
                     args => [],
                     ok_msg => undefined,
                     acting_user => User#user.username},

            %% Use rabbit_amqqueue:with to handle potential queue lookup races/errors
            rabbit_amqqueue:with(
                QName,
                fun(Q) ->
                    % First check if we're already consuming from this queue
                    case self_consumes(Q) of
                        true ->
                            ?LOG_INFO("OCPP already consuming from ~ts for ClientId ~ts",
                                     [rabbit_misc:rs(QName), ClientId]),
                            {ok, State}; % Already consuming, just return current state
                        false ->
                            case rabbit_queue_type:consume(Q, Spec, QStates0) of
                                {ok, QStates} ->
                                    ?LOG_INFO("OCPP successfully started consuming from ~ts with prefetch ~p for ClientId ~ts",
                                             [rabbit_misc:rs(QName), Prefetch, ClientId]),
                                    {ok, State#state{queue_states = QStates}};
                                {error, Type, Fmt, FmtArgs} ->
                                    ?LOG_ERROR("OCPP failed to consume from ~ts for ClientId ~ts: ~ts",
                                             [rabbit_misc:rs(QName), ClientId,
                                              rabbit_misc:format(Fmt, FmtArgs)]),
                                    {error, {consume_failed, Type}}
                            end
                    end
                end,
                fun(ErrorType) -> % Handle case where queue doesn't exist during consume
                    ?LOG_ERROR("OCPP cannot consume, queue ~ts lookup failed for ClientId ~ts: ~p",
                             [rabbit_misc:rs(QName), ClientId, ErrorType]),
                    {error, {consume_failed, ErrorType}}
                end);
        {error, access_refused} ->
            ?LOG_WARNING("OCPP consume permission refused for queue ~ts for ClientId ~ts",
                       [rabbit_misc:rs(QName), ClientId]),
            {error, {consume_failed, access_refused}}
    end.

%% Check if this process is already consuming from the queue
-spec self_consumes(amqqueue:amqqueue()) -> boolean().
self_consumes(Queue) ->
    lists:any(fun(Consumer) ->
                  element(1, Consumer) =:= self()
              end, rabbit_amqqueue:consumers(Queue)).

%% Generate queue name (e.g., ocpp.chargepoint_id)
-spec queue_name(Vhost :: rabbit_types:vhost(), ClientId :: binary()) -> rabbit_amqqueue:name().
queue_name(Vhost, ClientId) ->
    QNameBin = << "ocpp.", ClientId/binary >>,
    rabbit_misc:r(Vhost, queue, QNameBin).
%% --- Permission Checks (Simplified wrappers around MQTT versions) ---

%% Check permissions for publishing to the OCPP exchange
check_publish_permitted(Exchange, RoutingKey, State = #state{auth_state = AuthState}) ->
    case check_resource_access(AuthState#auth_state.user, Exchange, write, AuthState#auth_state.authz_ctx) of
        ok -> check_topic_access(RoutingKey, write, State);
        Err -> Err
    end.

%% Check permissions for binding queue to exchange. Requires 'write' on the
%% queue, 'read' on the exchange, and topic 'read' on the binding key
check_binding_permitted(QName, ExchangeName, RoutingKey,
                        State = #state{auth_state = AuthState}) ->
    User = AuthState#auth_state.user,
    Ctx = AuthState#auth_state.authz_ctx,
    case check_resource_access(User, QName, write, Ctx) of
        ok ->
            case check_resource_access(User, ExchangeName, read, Ctx) of
                ok -> check_topic_access(RoutingKey, read, State);
                Err -> Err
            end;
        Err -> Err
    end.

%% Generic resource permission check (borrowed from MQTT, no caching here)
check_resource_access(User, Resource, Perm, Context) ->
    V = {Resource, Context, Perm},
    Cache = case get(permission_cache) of
                undefined -> [];
                Other     -> Other
            end,
    case lists:member(V, Cache) of
        true ->
            ok;
        false ->
            try rabbit_access_control:check_resource_access(User, Resource, Perm, Context) of
                ok ->
                    CacheTail = lists:sublist(Cache, ?MAX_PERMISSION_CACHE_SIZE-1),
                    put(permission_cache, [V | CacheTail]),
                    ok
            catch
                exit:#amqp_error{name = access_refused,
                                 explanation = Msg} ->
                    ?LOG_ERROR("OCPP resource access refused: ~s", [Msg]),
                    {error, access_refused}
            end
    end.

check_topic_access(
  RoutingKey, Access,
  #state{auth_state = #auth_state{user = User = #user{username = Username}},
         cfg = #cfg{client_id = ClientId,
                    vhost = Vhost,
                    exchange = XName = #resource{name = XNameBin}}}) ->
    Cache = case get(topic_permission_cache) of
                undefined -> [];
                Other     -> Other
            end,
    Key = {RoutingKey, Username, ClientId, Vhost, XNameBin, Access},
    case lists:member(Key, Cache) of
        true ->
            ok;
        false ->
            Resource = XName#resource{kind = topic},
            Context = #{routing_key  => RoutingKey,
                        variable_map => #{<<"username">>  => Username,
                                          <<"vhost">>     => Vhost,
                                          <<"client_id">> => ClientId}},
            try rabbit_access_control:check_topic_access(User, Resource, Access, Context) of
                ok ->
                    CacheTail = lists:sublist(Cache, ?MAX_PERMISSION_CACHE_SIZE - 1),
                    put(topic_permission_cache, [Key | CacheTail]),
                    ok
            catch
                exit:#amqp_error{name = access_refused,
                                 explanation = Msg} ->
                    ?LOG_ERROR("OCPP topic access refused: ~s", [Msg]),
                    {error, access_refused}
            end
    end.

-spec init_trace(rabbit_types:vhost(), binary()) ->
    {rabbit_trace:state(), undefined | binary()}.
init_trace(Vhost, ConnName0) ->
    TraceState = rabbit_trace:init(Vhost),
    ConnName = case rabbit_trace:enabled(TraceState) of
                   true ->
                       ConnName0;
                   false ->
                       %% Tracing does not need connection name.
                       %% Use less memmory by setting to undefined.
                       undefined
               end,
    {TraceState, ConnName}.

%% Format status for management UI (very basic)
-spec format_status(state()) -> map().
format_status(#state{cfg = Cfg, queue_states = QStates, auth_state = AuthState}) ->
    #{cfg => Cfg, % Include relevant config
      queue_states => rabbit_queue_type:format_status(QStates), % Delegate queue status
      auth_state => AuthState}. % Include auth info

%% Decodes and checks a text frame from the charge point. Invalid messages are
%% dropped: a CALL gets a CALLERROR and the connection stays open
%% [OCPP 2.1 part 4 §4.2.3].
-spec handle_text_frame(binary(), state()) ->
    {ok, #ocpp_msg{}, state()} | {drop, [cowboy_websocket:frame()], state()}.
handle_text_frame(Data, State = #state{cfg = #cfg{client_id = ClientId,
                                                  proto_ver = ProtoVer}}) ->
    try json:decode(Data) of
        Decoded ->
            case process_decoded_message(Decoded) of
                {ok, MsgType, MsgId, Action} ->
                    rabbit_global_counters:messages_received(ProtoVer, 1),
                    UpdatedState = maybe_update_props_from_message(Decoded, State),
                    {ok, #ocpp_msg{client_id = ClientId,
                                   msg_type = MsgType,
                                   msg_id = MsgId,
                                   action = Action,
                                   payload = Data}, UpdatedState};
                unknown_type ->
                    ?LOG_DEBUG("Web OCPP ignored a message of unknown type from ClientId ~ts",
                               [ClientId]),
                    {drop, [], State};
                invalid ->
                    ?LOG_WARNING("Web OCPP dropped an invalid OCPP message from ClientId ~ts "
                                 "(~b bytes)", [ClientId, byte_size(Data)]),
                    {drop, reply_invalid(Decoded, State), State}
            end
    catch
        error:Reason ->
            ?LOG_WARNING("Web OCPP failed to decode JSON from ClientId ~ts (~b bytes): ~tp",
                         [ClientId, byte_size(Data), Reason]),
            {drop, [rpc_framework_error(undefined, State)], State}
    end.

%% Only a CALL, or a message whose type cannot be read, gets an answer. The
%% other message types are responses, or SEND messages, which must not be
%% answered [OCPP 2.1 part 4 §4.2.4].
reply_invalid([?OCPP_MESSAGE_TYPE_CALL, MsgId | _], State) ->
    [rpc_framework_error(MsgId, State)];
reply_invalid([Type | _], _State) when Type =/= ?OCPP_MESSAGE_TYPE_CALL ->
    [];
reply_invalid(_Decoded, State) ->
    [rpc_framework_error(undefined, State)].

%% A message ID that cannot be read is answered as "-1". OCPP 1.6 has no
%% RpcFrameworkError code.
rpc_framework_error(MsgId0, #state{cfg = #cfg{proto_ver = ProtoVer}}) ->
    MsgId = case mc_util:is_valid_shortstr(MsgId0) of
                true -> MsgId0;
                false -> <<"-1">>
            end,
    ErrorCode = case ProtoVer of
                    ?OCPP_PROTO_V16 -> <<"ProtocolError">>;
                    _ -> <<"RpcFrameworkError">>
                end,
    call_error(MsgId, ErrorCode, <<"Invalid OCPP message">>).

call_error(MsgId, ErrorCode, Description) ->
    CallError = [?OCPP_MESSAGE_TYPE_CALLERROR, MsgId, ErrorCode, Description, #{}],
    {text, iolist_to_binary(json:encode(CallError))}.

%% Updates the client properties in the connection_created core metrics
%% table, which the management agent copies to connection_created_stats once
%% per connection, and in connection_created_stats if that copy was already
%% made. connection_created_stats is owned by rabbit_mgmt_storage, which the
%% management agent does not start when
%% management_agent.disable_metrics_collector is set.
-spec force_stats_refresh(state()) -> ok.
force_stats_refresh(State = #state{cfg = #cfg{client_id = ClientId}}) ->
    Pid = self(),
    ClientProps = info(client_properties, State),
    try
        case ets:lookup(connection_created, Pid) of
            [{Pid, Infos}] ->
                ets:insert(connection_created,
                           {Pid, lists:keystore(client_properties, 1, Infos,
                                                {client_properties, ClientProps})});
            [] ->
                ok
        end,
        case ets:whereis(connection_created_stats) =/= undefined andalso
             ets:lookup(connection_created_stats, Pid) of
            [{Pid, ConnName, StatsInfos}] ->
                Formatted = {client_properties, rabbit_misc:amqp_table(ClientProps)},
                ets:insert(connection_created_stats,
                           {Pid, ConnName,
                            lists:keystore(client_properties, 1, StatsInfos, Formatted)});
            _ ->
                ok
        end
    catch
        Class:Reason ->
            ?LOG_WARNING("Failed to refresh connection stats for ~ts: ~p:~p",
                         [ClientId, Class, Reason])
    end,
    ok.

%% @doc Stores the vendor, model and firmware version from a BootNotification
%% as the platform, product and version client properties, which the
%% management UI displays in the client column of a connection.
%%
%% The status of each connector from a StatusNotification is stored as well.
%% Only connector and EVSE IDs up to 4 are stored, because the charge point
%% chooses the IDs and every update copies all properties to the stats tables.
-spec maybe_update_props_from_message(list(), state()) -> state().
maybe_update_props_from_message([?OCPP_MESSAGE_TYPE_CALL, _MsgId, <<"BootNotification">>, Payload],
                                State = #state{cfg = #cfg{proto_ver = ?OCPP_PROTO_V16}})
  when is_map(Payload) ->
    update_props(string_props([{<<"platform">>, maps:get(<<"chargePointVendor">>, Payload, undefined)},
                               {<<"product">>, maps:get(<<"chargePointModel">>, Payload, undefined)},
                               {<<"version">>, maps:get(<<"firmwareVersion">>, Payload, undefined)}]),
                 State);
maybe_update_props_from_message([?OCPP_MESSAGE_TYPE_CALL, _MsgId, <<"BootNotification">>,
                                 #{<<"chargingStation">> := Station}], State)
  when is_map(Station) ->
    update_props(string_props([{<<"platform">>, maps:get(<<"vendorName">>, Station, undefined)},
                               {<<"product">>, maps:get(<<"model">>, Station, undefined)},
                               {<<"version">>, maps:get(<<"firmwareVersion">>, Station, undefined)}]),
                 State);
maybe_update_props_from_message([?OCPP_MESSAGE_TYPE_CALL, _MsgId, <<"StatusNotification">>,
                                 #{<<"connectorId">> := ConnectorId,
                                   <<"status">> := Status,
                                   <<"errorCode">> := ErrorCode}],
                                State = #state{cfg = #cfg{proto_ver = ?OCPP_PROTO_V16}})
  when is_integer(ConnectorId), ConnectorId >= 0, ConnectorId =< 4,
       is_binary(Status), is_binary(ErrorCode) ->
    Key = <<"statusConnectorId", (integer_to_binary(ConnectorId))/binary>>,
    update_props([{Key, table, [{<<"status">>, longstr, Status},
                                {<<"errorCode">>, longstr, ErrorCode}]}], State);
maybe_update_props_from_message([?OCPP_MESSAGE_TYPE_CALL, _MsgId, <<"StatusNotification">>,
                                 #{<<"evseId">> := EvseId,
                                   <<"connectorId">> := ConnectorId,
                                   <<"connectorStatus">> := Status}], State)
  when is_integer(EvseId), EvseId >= 1, EvseId =< 4,
       is_integer(ConnectorId), ConnectorId >= 1, ConnectorId =< 4,
       is_binary(Status) ->
    Key = <<"statusEvseId", (integer_to_binary(EvseId))/binary,
            "ConnectorId", (integer_to_binary(ConnectorId))/binary>>,
    update_props([{Key, table, [{<<"status">>, longstr, Status}]}], State);
maybe_update_props_from_message(_DecodedList, State) ->
    State.

%% Values that are missing or not strings are skipped.
string_props(Props) ->
    [{Key, longstr, Value} || {Key, Value} <- Props, is_binary(Value)].

update_props(Props, State = #state{cfg = Cfg = #cfg{user_prop = OldProps}}) ->
    NewProps = lists:foldl(fun({Key, _, _} = Prop, Acc) ->
                                   lists:keystore(Key, 1, Acc, Prop)
                           end, OldProps, Props),
    UpdatedState = State#state{cfg = Cfg#cfg{user_prop = NewProps}},
    force_stats_refresh(UpdatedState),
    UpdatedState.

-spec info(rabbit_types:info_key(), state()) -> any().
info(host, #state{cfg = #cfg{ip_addr = Val}}) -> Val;
info(port, #state{cfg = #cfg{port = Val}}) -> Val;
info(peer_host, #state{cfg = #cfg{peer_ip_addr = Val}}) -> Val;
info(peer_port, #state{cfg = #cfg{peer_port = Val}}) -> Val;
info(connected_at, #state{cfg = #cfg{connected_at = Val}}) -> Val;
info(user_who_performed_action, S) ->
    info(user, S);
info(prefetch_count, #state{cfg = #cfg{prefetch = Val}}) -> Val;
info(exchange, #state{cfg = #cfg{exchange = #resource{name = Val}}}) -> Val;
info(user, #state{auth_state = #auth_state{user = #user{username = Val}}}) -> Val;
info(user_property, #state{cfg = #cfg{user_prop = Val}}) -> Val;
info(vhost, #state{cfg = #cfg{vhost = Val}}) -> Val;
%% for rabbitmq_management/priv/www/js/tmpl/connection.ejs
info(client_properties, #state{cfg = #cfg{client_id = ClientId,
                                          user_prop = Prop}}) ->
    ?LOG_DEBUG("OCPP client_properties for ~ts: ~p", [ClientId, Prop]),
    Result = [{<<"chargePointId">>, longstr, ClientId},
              {<<"connection_name">>, longstr, <<"Charging Point">>} | Prop],
    ?LOG_DEBUG("OCPP client_properties AFTER for ~ts: ~p", [ClientId, Result]),
    Result;
info(channel_max, _) -> 0;
info(node, _) -> node();
info(recv_oct, _) -> erlang:process_info(self(), message_queue_len); % Approx incoming? Needs better metric
info(send_oct, _) -> 0; % Hard to track accurately here
info(Other, #state{cfg=#cfg{client_id=ClientId}}) ->
    ?LOG_DEBUG("OCPP info request for ~ts: ~p", [ClientId, Other]),
    undefined.

%% The message ID becomes the correlation_id property, which AMQP 0-9-1
%% workers can only read if it is a valid short string. OCPP-J allows at most
%% 36 characters, so that a UUID fits [OCPP 2.1 part 4 §4.1.4]. The check here
%% is less strict, because longer IDs cause no harm.
%%
%% For CALLERROR and CALLRESULTERROR, the error code takes the place of the
%% action.
-spec process_decoded_message(term()) ->
    {ok, integer(), binary(), binary() | undefined} | unknown_type | invalid.
process_decoded_message([Type | _])
  when is_integer(Type),
       (Type < ?OCPP_MESSAGE_TYPE_CALL orelse Type > ?OCPP_MESSAGE_TYPE_SEND) ->
    unknown_type;
process_decoded_message([?OCPP_MESSAGE_TYPE_CALL, MessageId, Action, _Payload]) ->
    ocpp_message(?OCPP_MESSAGE_TYPE_CALL, MessageId, Action);
%% A signed message has an extension object before the action
%% [OCPP 2.1 part 4 §7.1].
process_decoded_message([?OCPP_MESSAGE_TYPE_CALL, MessageId, Extension, Action, _Payload])
  when is_map(Extension) ->
    ocpp_message(?OCPP_MESSAGE_TYPE_CALL, MessageId, Action);
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLRESULT, MessageId, _Payload]) ->
    ocpp_message(?OCPP_MESSAGE_TYPE_CALLRESULT, MessageId, undefined);
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLERROR, MessageId, ErrorCode, _ErrorDescription, _ErrorDetails]) ->
    ocpp_message(?OCPP_MESSAGE_TYPE_CALLERROR, MessageId, ErrorCode);
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLRESULTERROR, MessageId, ErrorCode, _ErrorDescription, _ErrorDetails]) ->
    ocpp_message(?OCPP_MESSAGE_TYPE_CALLRESULTERROR, MessageId, ErrorCode);
process_decoded_message([?OCPP_MESSAGE_TYPE_SEND, MessageId, Action, _Payload]) ->
    ocpp_message(?OCPP_MESSAGE_TYPE_SEND, MessageId, Action);
process_decoded_message([?OCPP_MESSAGE_TYPE_SEND, MessageId, Extension, Action, _Payload])
  when is_map(Extension) ->
    ocpp_message(?OCPP_MESSAGE_TYPE_SEND, MessageId, Action);
process_decoded_message(_Decoded) ->
    invalid.

%% JSON null decodes to the atom null, so an undefined action can only come
%% from a CALLRESULT.
ocpp_message(Type, MessageId, Action)
  when is_binary(Action) orelse Action =:= undefined ->
    case mc_util:is_valid_shortstr(MessageId) of
        true -> {ok, Type, MessageId, Action};
        false -> invalid
    end;
ocpp_message(_Type, _MessageId, _Action) ->
    invalid.

-spec proto_version_tuple(ocpp_protocol_version_atom() | undefined) -> tuple() | undefined.
proto_version_tuple(?OCPP_PROTO_V16) -> {1, 6};
proto_version_tuple(?OCPP_PROTO_V20) -> {2, 0};
proto_version_tuple(?OCPP_PROTO_V201) -> {2, 0, 1};
proto_version_tuple(?OCPP_PROTO_V21) -> {2, 1};
proto_version_tuple(_) -> undefined.

% %% Basic validation for decoded OCPP list structure
% -spec is_valid_ocpp_list(list()) -> boolean().
% is_valid_ocpp_list([Type, _MsgId, _Action, _Payload]) when Type =:= ?OCPP_MESSAGE_TYPE_CALL; Type =:= ?OCPP_MESSAGE_TYPE_SEND ->
%     true;
% is_valid_ocpp_list([Type, _MsgId, _Payload]) when Type =:= ?OCPP_MESSAGE_TYPE_CALLRESULT ->
%     true;
% is_valid_ocpp_list([Type, _MsgId, _ErrorCode, _ErrorDesc, _ErrorDetails]) when Type =:= ?OCPP_MESSAGE_TYPE_CALLERROR; Type =:= ?OCPP_MESSAGE_TYPE_CALLRESULTERROR ->
%     true;
% is_valid_ocpp_list(_) ->
%     false.

%% @doc Provides the environment for mc:convert/3. For OCPP->AMQP, no special env needed.
mc_env() ->
    #{}.