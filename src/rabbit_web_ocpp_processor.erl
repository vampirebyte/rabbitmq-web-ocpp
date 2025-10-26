%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2025 VAMPIRE BYTE SRL. All Rights Reserved.
%%
-module(rabbit_web_ocpp_processor).

%% Simplified exports for OCPP
-export([info/2,
         init/7,
         process_incoming/2,
         terminate/3,
         handle_info/2,
         handle_text_frame/2,
         format_status/1,
         remove_duplicate_client_id_connections/2,
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
-define(CONSUMER_TAG, <<"ocpp.consumer">>).
-define(QUEUE_KIND, ocpp). % Used for queue naming convention
-define(PREFETCH_COUNT, 1). % Default prefetch for the OCPP queue

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
        ssl_login_name :: none | binary(),
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
        connected_at :: pos_integer()
}).

-record(state, {
    cfg :: #cfg{},
    queue_states :: rabbit_queue_type:state(), % State for managing the queue consumer
    auth_state :: #auth_state{} % Re-use auth_state structure
}).

-opaque state() :: #state{}.

%% --- Public API ---
-spec init(Vhost :: rabbit_types:vhost(),
           ClientId :: binary(),
           ProtoVer :: ocpp_protocol_version_atom(),
           RawSocket :: rabbit_net:socket(),
           ConnectionName :: binary(),
           User :: #user{},
           SendFun :: send_fun()) ->
    {ok, state()} | {error, term()}.
init(Vhost, ClientId, ProtoVer, Socket, ConnName0, User, SendFun) ->
    %% Check whether peer closed the connection.
    %% For example, this can happen when connection was blocked because of resource
    %% alarm and client therefore disconnected.
    case rabbit_net:socket_ends(Socket, inbound) of
        {ok, SocketEnds} ->
            process_connect(Vhost, ClientId, ProtoVer, Socket, ConnName0, User, SendFun, SocketEnds);
        {error, Reason} ->
            {error, {socket_ends, Reason}}
    end.

process_connect(Vhost, ClientId, ProtoVer, Socket, ConnName0, User, SendFun, {PeerIp, PeerPort, Ip, Port}) ->
    ?LOG_DEBUG("OCPP init request. ClientId: ~ts, ConnName: ~ts", [ClientId, ConnName0]),

    case rabbit_net:socket_ends(Socket, inbound) of
        {ok, SocketEnds} ->
            {PeerIp, PeerPort, Ip, Port} = SocketEnds;
        {error, SocketEndsReason} ->
            {error, {socket_ends, SocketEndsReason}}
    end,

    %% 2. Authentication & Authorization
    Result =
        maybe
            % Authz context might include ClientId specific info if needed by backends
            AuthzCtx = #{<<"client_id">> => ClientId, <<"protocol">> => <<"ocpp">>},
            ok = register_client_id(Vhost, ClientId),
            % Register potentially (optional, depends if needed for mgmt/tracking)
            ok = rabbit_networking:register_non_amqp_connection(self()),
            self() ! connection_created,
            rabbit_core_metrics:auth_attempt_succeeded(PeerIp, ClientId, ocpp),
            rabbit_global_counters:consumer_created(ProtoVer),

            %% 3. Setup Resources
            ExchangeNameBin = application:get_env(rabbit_web_ocpp, exchange, ?DEFAULT_EXCHANGE_NAME),
            ExchangeName = rabbit_misc:r(Vhost, exchange, ExchangeNameBin),
            QueueName = queue_name(Vhost, ClientId),
            Prefetch = application:get_env(rabbit_web_ocpp, prefetch_count, ?PREFETCH_COUNT),
            {TraceState, ConnName} = init_trace(Vhost, ConnName0),

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
                       connected_at = os:system_time(millisecond)},
            InitialState = #state{cfg = Cfg,
                                  queue_states = rabbit_queue_type:init(),
                                  auth_state = AuthState},

            {ok, StateAfterQueue} ?= ensure_queue_and_binding(InitialState),
            {ok, FinalState} ?= consume_from_queue(StateAfterQueue),

            ?LOG_INFO("OCPP connection ~ts established for ClientId ~ts on vhost ~ts",
                      [ConnName, ClientId, Vhost]),
            {ok, FinalState}
        else
            {error, Reason} ->
                ?LOG_ERROR("OCPP connection failed for ClientId ~ts: ~p", [ClientId, Reason]),
                %% Cleanup if partially successful before error
                rabbit_networking:unregister_non_amqp_connection(self()),
                {error, Reason} % Return the error reason
        end,
    Result.

%% Process incoming OCPP message (parsed list + raw binary)
-spec process_incoming(McOcpp :: #ocpp_msg{}, state()) -> {ok, state()} | {error, term(), state()}.
process_incoming(McOcpp = #ocpp_msg{},
                State = #state{cfg = #cfg{exchange = ExchangeName,
                                                    client_id = ClientId,
                                                    trace_state = TraceState,
                                                    conn_name = ConnName},
                                         auth_state = #auth_state{user = User}}) ->
    %% 1. Check Publish Permissions (on Exchange and Topic/Routing Key)
    case check_publish_permitted(ExchangeName, ClientId, State) of
        ok ->
            %% 2. Validate Exchange
            case rabbit_exchange:lookup(ExchangeName) of
                {ok, Exchange} ->
                    %% 3. Prepare annotations and initialize Message Container (mc) with mc_ocpp type
                    Anns = #{?ANN_EXCHANGE => ?DEFAULT_EXCHANGE_NAME},
                    case mc:init(mc_ocpp, McOcpp, Anns, #{}) of
                        McMsg ->
                            ?LOG_DEBUG("Created message container for ClientId ~ts: ~tp", [ClientId, McMsg]),
                            %% 4. Trace (optional)
                            rabbit_trace:tap_in(McMsg, [ExchangeName], ConnName, User#user.username, TraceState),

                            %% 5. Publish to the exchange with the ClientId as routing key
                            case rabbit_exchange:route(Exchange, McMsg, #{}) of
                                ok ->
                                    ?LOG_INFO("Message routed successfully for ClientId ~ts", [ClientId]),
                                    {ok, State};
                                QNames when is_list(QNames) ->
                                    ?LOG_INFO("Message routed to ~p queues for ClientId ~ts: ~p",
                                              [length(QNames), ClientId, QNames]),
                                    deliver_to_queues(McMsg, #{}, QNames, State),
                                    {ok, State};
                                {error, Reason} ->
                                    ?LOG_ERROR("OCPP failed to route message via exchange ~ts: ~p",
                                               [rabbit_misc:rs(ExchangeName), Reason]),
                                    {error, {publish_failed, Reason}, State}
                            end;
                        _ ->
                            ?LOG_ERROR("Failed to initialize mc_ocpp message for ClientId ~ts", [ClientId]),
                            {error, {invalid_mc_msg, McOcpp}, State}
                    end;
                {error, not_found} ->
                    ?LOG_ERROR("Exchange ~ts does not exist for ClientId ~ts", [rabbit_misc:rs(ExchangeName), ClientId]),
                    {error, {exchange_not_found, ExchangeName}, State}
            end;
        {error, access_refused} = Error ->
            ?LOG_WARNING("OCPP publish refused for ClientId ~ts to exchange ~ts", [ClientId, rabbit_misc:rs(ExchangeName)]),
            {error, Error, State}
    end.

binding_action_with_checks(QName, TopicFilter, BindingArgs, Action,
                           State = #state{cfg = #cfg{exchange = ExchangeName},
                                          auth_state = AuthState}) ->
    %% Same permissions required for binding or unbinding queue to/from topic exchange.
    maybe
        ok ?= check_queue_write_access(QName, AuthState),
        ok ?= check_exchange_read_access(ExchangeName, AuthState),
        ok ?= check_topic_access(TopicFilter, read, State),
        ok ?= binding_action(ExchangeName, TopicFilter, QName, BindingArgs,
                             fun rabbit_binding:Action/2, AuthState)
    else
        {error, Reason} = Err ->
            ?LOG_ERROR("Failed to ~s binding between ~s and ~s for topic filter ~s: ~p",
                       [Action, rabbit_misc:rs(ExchangeName), rabbit_misc:rs(QName), TopicFilter, Reason]),
            Err
    end.

check_queue_write_access(QName, #auth_state{user = User,
                                            authz_ctx = AuthzCtx}) ->
    %% write access to queue required for queue.(un)bind
    check_resource_access(User, QName, write, AuthzCtx).

check_exchange_read_access(ExchangeName, #auth_state{user = User,
                                                     authz_ctx = AuthzCtx}) ->
    %% read access to exchange required for queue.(un)bind
    check_resource_access(User, ExchangeName, read, AuthzCtx).

binding_action(ExchangeName, TopicFilter, QName, BindingArgs,
               BindingFun, #auth_state{user = #user{username = Username}}) ->
    % RoutingKey = mqtt_to_amqp(TopicFilter),
    Binding = #binding{source = ExchangeName,
                       destination = QName,
                    %    key = RoutingKey,
                       args = BindingArgs},
    BindingFun(Binding, Username).

% publish_to_queues(
%   #mqtt_msg{topic = Topic,
%             packet_id = PacketId} = MqttMsg,
%   #state{cfg = #cfg{exchange = ExchangeName = #resource{name = ExchangeNameBin},
%                     conn_name = ConnName,
%                     trace_state = TraceState},
%          auth_state = #auth_state{user = #user{username = Username}}} = State) ->
%     Anns = #{?ANN_EXCHANGE => ExchangeNameBin,
%              ?ANN_ROUTING_KEYS => [mqtt_to_amqp(Topic)]},
%     Msg0 = mc:init(mc_mqtt, MqttMsg, Anns, mc_env()),
%     Msg = rabbit_message_interceptor:intercept(Msg0),
%     case rabbit_exchange:lookup(ExchangeName) of
%         {ok, Exchange} ->
%             QNames0 = rabbit_exchange:route(Exchange, Msg, #{return_binding_keys => true}),
%             QNames = drop_local(QNames0, State),
%             rabbit_trace:tap_in(Msg, QNames, ConnName, Username, TraceState),
%             Opts = maps_put_truthy(flow, Flow, maps_put_truthy(correlation, PacketId, #{})),
%             deliver_to_queues(Msg, Opts, QNames, State);
%         {error, not_found} ->
%             ?LOG_ERROR("~s not found", [rabbit_misc:rs(ExchangeName)]),
%             {error, exchange_not_found, State}
%     end.

deliver_to_queues(Message,
                  Options,
                  RoutedToQNames,
                  State0 = #state{queue_states = QStates0,
                                  cfg = #cfg{proto_ver = ProtoVer}}) ->
    FilteredQNames = drop_local(RoutedToQNames, State0),
    Qs0 = rabbit_amqqueue:lookup_many(FilteredQNames),
    Qs = rabbit_amqqueue:prepend_extra_bcc(Qs0),
    ?LOG_DEBUG("Delivering to queue ~p with state ~p", [Qs, QStates0]),
    case rabbit_queue_type:deliver(Qs, Message, Options, QStates0) of
        {ok, _QStates, Actions} ->
            rabbit_global_counters:messages_routed(ProtoVer, length(Qs)),
            % State = process_routing_confirm(Options, Qs,
            %                                 State0#state{queue_states = QStates}),
            %% Actions must be processed after registering confirms as actions may
            %% contain rejections of publishes.
            {ok, handle_queue_actions(Actions, State0)};
        {error, Reason} ->
            Corr = maps:get(correlation, Options, undefined),
            ?LOG_ERROR("Failed to deliver message with packet_id=~p to queues: ~p",
                       [Corr, Reason]),
            {error, Reason, State0}
    end.

%% OCPP Messages MUST NOT be forwarded to a connection with a ClientID
%% equal to the ClientID of the publishing connection.
drop_local(QNames, #state{cfg = #cfg{queue_name = OwnQueueName}}) ->
    lists:filter(fun(QName) -> QName =/= OwnQueueName end, QNames);
drop_local(QNames, _) ->
    QNames.

-spec register_client_id(rabbit_types:vhost(), client_id()) -> ok.
register_client_id(Vhost, ClientId)
  when is_binary(Vhost), is_binary(ClientId) ->
    PgGroup = {Vhost, ClientId},
    ok = pg:join(persistent_term:get(?PG_SCOPE), PgGroup, self()),
    ok = erpc:multicast([node() | nodes()],
                        ?MODULE,
                        remove_duplicate_client_id_connections,
                        [PgGroup, self()]).

-spec remove_duplicate_client_id_connections(
        {rabbit_types:vhost(), client_id()}, pid()) -> ok.
remove_duplicate_client_id_connections(PgGroup, PidToKeep) ->
    try persistent_term:get(?PG_SCOPE) of
        PgScope ->
            Pids = pg:get_local_members(PgScope, PgGroup),
            lists:foreach(fun(Pid) ->
                                  gen_server:cast(Pid, {duplicate_id})
                          end, Pids -- [PidToKeep])
    catch _:badarg ->
        %% OCPP supervision tree on this node not fully started
        ok
    end.

%% Handle internal messages, queue events, etc.
-spec handle_info(term(), state()) -> {ok, state()} | {stop, term(), state()}.
handle_info({queue_event, QName, Evt}, State = #state{queue_states = QStates0}) ->
    case rabbit_queue_type:handle_event(QName, Evt, QStates0) of
        {ok, QStates, Actions} ->
            State1 = State#state{queue_states = QStates},
            {ok, handle_queue_actions(Actions, State1)};
        {protocol_error, _, _, _} = Error ->
            {stop, {shutdown, Error}, State};
        {eol, Actions} -> % Queue deleted or gone
             State1 = handle_queue_actions(Actions, State),
             QStates = rabbit_queue_type:remove(QName, QStates0),
             {ok, State1#state{queue_states = QStates}};
        Other ->
             ?LOG_WARNING("Unhandled queue event for ~ts: ~p", [rabbit_misc:rs(QName), Other]),
             {ok, State}
    end;

handle_info({'DOWN', _, process, Pid, Reason}, State = #state{queue_states = QStates0}) ->
    %% Handle queue process down event
    case rabbit_queue_type:handle_down(Pid, undefined, Reason, QStates0) of
         {ok, QStates1, Actions} ->
            State1 = State#state{queue_states = QStates1},
            {ok, handle_queue_actions(Actions, State1)};
         {eol, QStates1, _QRef} -> % Queue is gone
             ?LOG_WARNING("OCPP queue process ~p down, queue is gone (EOL)", [Pid]),
             {ok, State#state{queue_states = QStates1}}; % Just update state
         _ ->
             ?LOG_WARNING("OCPP queue process ~p down, reason: ~p", [Pid, Reason]),
             {ok, State}
    end;

handle_info(connection_closed, State) -> % Message from RabbitMQ core if underlying socket closes
    ?LOG_INFO("OCPP underlying connection closed notification received."),
    {stop, normal, State};

handle_info(Msg, State = #state{cfg = #cfg{client_id = ClientId}}) ->
    ?LOG_WARNING("OCPP processor for ~ts received unknown message: ~p", [ClientId, Msg]),
    {ok, State}.

%% Terminate the processor
-spec terminate(any(), rabbit_event:event_props(), state()) -> ok.
terminate(Reason, Infos, _State = #state{queue_states = QStates,
                                        cfg = #cfg{client_id = ClientId}}) ->
    ?LOG_INFO("OCPP processor terminating. ClientId: ~ts, Reason: ~p", [ClientId, Reason]),
    ok = rabbit_queue_type:close(QStates), % Stop consuming
    rabbit_core_metrics:connection_closed(self()),
    rabbit_event:notify(connection_closed, Infos),
    ok = rabbit_networking:unregister_non_amqp_connection(self()),
    %% Note: We typically DO NOT delete the durable queue on disconnect for OCPP.
    %% It should persist messages while the CP is offline.
    ok.

%% --- Internal Functions ---

%% @doc Extracts relevant metadata from a parsed OCPP message list.
% -spec extract_ocpp_metadata(list()) -> {ok, MsgId :: binary(), Action :: binary() | undefined} | {error, term()}.
% extract_ocpp_metadata([?OCPP_MESSAGE_TYPE_CALL, MsgId, Action, _Payload]) when is_binary(MsgId), is_binary(Action) -> {ok, MsgId, Action};
% extract_ocpp_metadata([?OCPP_MESSAGE_TYPE_CALLRESULT, MsgId, _Payload]) when is_binary(MsgId) -> {ok, MsgId, undefined};
% extract_ocpp_metadata([?OCPP_MESSAGE_TYPE_CALLERROR, MsgId, _EC, _ED, _EDet]) when is_binary(MsgId) -> {ok, MsgId, undefined};
% extract_ocpp_metadata([?OCPP_MESSAGE_TYPE_SEND, MsgId, Action, _Payload]) when is_binary(MsgId), is_binary(Action) -> {ok, MsgId, Action}; % OCPP 2.1
% extract_ocpp_metadata([?OCPP_MESSAGE_TYPE_CALLRESULTERROR, MsgId, _EC, _ED, _EDet]) when is_binary(MsgId) -> {ok, MsgId, undefined}; % OCPP 2.1
% extract_ocpp_metadata(Other) -> {error, {invalid_ocpp_list_for_metadata, Other}}.

%% Handle actions resulting from queue events (deliveries, etc.)
handle_queue_actions([], State) -> State;
handle_queue_actions([{deliver, ?CONSUMER_TAG, AckRequired, Msgs} | Rest], State) ->
    ?LOG_DEBUG("OCPP handling 'deliver' action. AckRequired: ~p, Msgs: ~tp", [AckRequired, Msgs]), % Added logging
    State1 = deliver_to_client(Msgs, AckRequired, State),
    handle_queue_actions(Rest, State1);
handle_queue_actions([{settled, _QName, _MsgIds} | Rest], State) ->
    ?LOG_DEBUG("OCPP handling 'settled' action for MsgIds: ~tp", [_MsgIds]), % Added logging
    %% We auto-ack after sending, so settled from queue isn't primary mechanism here
    handle_queue_actions(Rest, State);
handle_queue_actions([{block, QName} | Rest], State = #state{cfg = #cfg{client_id=ClientId}}) ->
    ?LOG_WARNING("OCPP queue ~ts blocked for ClientId ~ts", [QName, ClientId]),
    % Could potentially signal backpressure to WebSocket handler if needed
    handle_queue_actions(Rest, State);
handle_queue_actions([{unblock, QName} | Rest], State = #state{cfg = #cfg{client_id=ClientId}}) ->
     ?LOG_INFO("OCPP queue ~ts unblocked for ClientId ~ts", [QName, ClientId]),
    handle_queue_actions(Rest, State);
handle_queue_actions([Action | Rest], State) ->
    ?LOG_DEBUG("OCPP unhandled queue action: ~p", [Action]),
    handle_queue_actions(Rest, State).

%% Deliver messages from the queue to the OCPP client via WebSocket
deliver_to_client([], _AckRequired, State) -> State;
deliver_to_client([{QName, QPid, QMsgId, _Redelivered, Mc} | Rest], AckRequired,
                  State = #state{cfg = #cfg{send_fun = SendFun, client_id = ClientId,
                                                  trace_state = TraceState, conn_name = ConnName},
                                 queue_states = QStates0,
                                 auth_state = #auth_state{user = User}}) ->
    try
        McOcpp = mc:convert(mc_ocpp, Mc, mc_env()),
        Payload = mc:protocol_state(McOcpp),
        case Payload of
             #ocpp_msg{payload = BinaryPayload} when is_binary(BinaryPayload) ->
                ?LOG_DEBUG("OCPP delivering raw message to ~ts", [ClientId]),
                rabbit_trace:tap_out({QName, QPid, QMsgId, _Redelivered, Mc}, ConnName, User#user.username, TraceState),
                case SendFun(BinaryPayload) of
                    ok ->
                        ?LOG_DEBUG("OCPP SendFun succeeded for QMsgId ~p", [QMsgId]), % Added logging
                        {ok, QStates1, Actions1} = rabbit_queue_type:settle(
                            QName, complete, ?CONSUMER_TAG, [QMsgId], QStates0),
                        State2 = handle_queue_actions(Actions1, State#state{queue_states = QStates1}),
                        deliver_to_client(Rest, AckRequired, State2);
                    {error, SendError} ->
                        ?LOG_ERROR("OCPP failed to send message to ~ts: ~p", [ClientId, SendError]),
                        {ok, QStates2, Actions2} = rabbit_queue_type:settle(
                            QName, discard, ?CONSUMER_TAG, [QMsgId], QStates0),
                        State3 = handle_queue_actions(Actions2, State#state{queue_states = QStates2}),
                        deliver_to_client(Rest, AckRequired, State3)
                end;
            _ ->
                ?LOG_ERROR("OCPP delivery error: Expected #ocpp_msg{} record but got ~tp", [Payload]),
                {ok, QStates3, Actions3} = rabbit_queue_type:settle(
                    QName, discard, ?CONSUMER_TAG, [QMsgId], QStates0),
                State4 = handle_queue_actions(Actions3, State#state{queue_states = QStates3}),
                deliver_to_client(Rest, AckRequired, State4)
        end
    catch Class:Reason:Stacktrace ->
        ?LOG_ERROR("OCPP error delivering message to ~ts: ~p:~p~n~p",
                   [ClientId, Class, Reason, Stacktrace]),
        {ok, QStates4, Actions4} = rabbit_queue_type:settle(
            QName, discard, ?CONSUMER_TAG, [QMsgId], QStates0),
        State5 = handle_queue_actions(Actions4, State#state{queue_states = QStates4}),
        deliver_to_client(Rest, AckRequired, State5)
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
                    %% 2. Declare the queue
                    QType = rabbit_amqqueue:get_queue_type(QArgs), % Define QType
                    Owner = none,
                    Durable = true,
                    AutoDelete = false,
                    Q0 = amqqueue:new(QName, none, Durable, AutoDelete, Owner, QArgs, Vhost, % Use QArgs
                                      #{user => Username}, QType), % Use QType

                    case rabbit_queue_type:declare(Q0, node()) of
                        {new, _Queue} -> % Successfully declared
                            rabbit_core_metrics:queue_created(QName),
                            bind_queue(State); % Proceed to binding
                        {existing, _ExistingQInfo} -> % Queue already exists (Corrected pattern)
                            ?LOG_DEBUG("OCPP queue ~ts already exists, proceeding to bind.", [rabbit_misc:rs(QName)]),
                            bind_queue(State); % Proceed to binding
                        {error, queue_limit_exceeded, Reason, ReasonArgs} ->
                            ?LOG_ERROR(Reason, ReasonArgs),
                            {error, {queue_declare_failed, queue_limit_exceeded}};
                        Other ->
                            ?LOG_ERROR("Failed to declare OCPP queue ~s: ~p", [rabbit_misc:rs(QName), Other]),
                            {error, {queue_declare_failed, queue_declare_error}}
                    end;
                {error, access_refused} = DlxErr -> % DLX permission failed
                    ?LOG_WARNING("OCPP DLX permission refused for queue ~ts", [rabbit_misc:rs(QName)]),
                    DlxErr
            end; % End of DLX check case
        {error, access_refused} = ConfigureErr ->
            ?LOG_WARNING("OCPP configure permission refused for queue ~ts", [rabbit_misc:rs(QName)]),
            ConfigureErr % Return configure permission error
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
    case check_binding_permitted(QName, ExchangeName, State) of
        ok ->
            case rabbit_binding:add(Binding, User#user.username) of
                ok ->
                    ?LOG_DEBUG("OCPP queue ~ts bound to ~ts with key ~ts",
                              [rabbit_misc:rs(QName), rabbit_misc:rs(ExchangeName), RoutingKey]),
                    {ok, State};
                {error, Reason} ->
                    ?LOG_ERROR("OCPP failed to bind queue ~ts to ~ts: ~p",
                              [rabbit_misc:rs(QName), rabbit_misc:rs(ExchangeName), Reason]),
                    {error, {binding_failed, Reason}}
            end;
        {error, access_refused} = Error ->
            ?LOG_WARNING("OCPP binding permission refused for queue ~ts / exchange ~ts",
                         [rabbit_misc:rs(QName), rabbit_misc:rs(ExchangeName)]),
            {error, Error}
    end.

%% Start consuming from the queue
-spec consume_from_queue(state()) -> {ok, state()} | {error, term()}.
consume_from_queue(State = #state{cfg = #cfg{queue_name = QName, client_id = ClientId, prefetch = Prefetch},
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
                     consumer_tag => ?CONSUMER_TAG,
                     exclusive_consume => false, % Allow other consumers? (Usually false for OCPP)
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
                                {error, Reason} = Err ->
                                    ?LOG_ERROR("OCPP failed to consume from ~ts for ClientId ~ts: ~p",
                                             [rabbit_misc:rs(QName), ClientId, Reason]),
                                    Err
                            end
                    end
                end,
                fun(ErrorType) -> % Handle case where queue doesn't exist during consume
                    ?LOG_ERROR("OCPP cannot consume, queue ~ts lookup failed for ClientId ~ts: ~p",
                             [rabbit_misc:rs(QName), ClientId, ErrorType]),
                    {error, {consume_failed, queue_lookup_failed, ErrorType}}
                end);
        {error, access_refused} = Error ->
            ?LOG_WARNING("OCPP consume permission refused for queue ~ts for ClientId ~ts",
                       [rabbit_misc:rs(QName), ClientId]),
            {error, Error}
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
check_publish_permitted(Exchange, CPID, State = #state{auth_state = AuthState}) ->
    case check_resource_access(AuthState#auth_state.user, Exchange, write, AuthState#auth_state.authz_ctx) of
        ok -> check_topic_access(CPID, write, State); % Also check routing key permission
        Err -> Err
    end.

%% Check permissions for binding queue to exchange
check_binding_permitted(QName, ExchangeName, #state{auth_state = AuthState}) ->
    User = AuthState#auth_state.user,
    Ctx = AuthState#auth_state.authz_ctx,
    %% Need 'write' on queue and 'read' on exchange for binding
    case check_resource_access(User, QName, write, Ctx) of
        ok -> check_resource_access(User, ExchangeName, read, Ctx);
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
    Key = {RoutingKey, Username, ClientId, Vhost, XNameBin, Access}, % TODO check if RoutingKey is OK
    case lists:member(Key, Cache) of
        true ->
            ok;
        false ->
            Resource = XName#resource{kind = topic},
            Context = #{routing_key  => RoutingKey,
                        variable_map => #{<<"username">> => Username,
                                          <<"vhost">> => Vhost,
                                          <<"client_id">> => ClientId}},
            try rabbit_access_control:check_topic_access(User, Resource, Access, Context) of
                ok ->
                    CacheTail = lists:sublist(Cache, ?MAX_PERMISSION_CACHE_SIZE - 1),
                    put(topic_permission_cache, [Key | CacheTail]),
                    ok
            catch
                exit:#amqp_error{name = access_refused,
                                 explanation = Msg} ->
                    ?LOG_ERROR("MQTT topic access refused: ~s", [Msg]),
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

%% @doc Handles an incoming WebSocket text frame, decodes JSON, and validates the OCPP message structure.
%% Returns {ok, #ocpp_msg{}} | {error, Reason :: binary()}.
-spec handle_text_frame(binary(), state()) -> {ok, #ocpp_msg{}, state()} | {error, binary()}.
handle_text_frame(Data, State = #state{cfg = #cfg{client_id = ClientId}}) ->
    try json:decode(Data) of
        Decoded when is_list(Decoded) ->
            % Successfully decoded a JSON list, validate its structure
            case process_decoded_message(Decoded) of
                {ok, ValidatedList} ->
                    UpdatedState = maybe_update_props_from_message(ValidatedList, State),
                    % Create mc_ocpp message
                    {ok, #ocpp_msg{
                        client_id = ClientId,
                        msg_type = lists:nth(1, ValidatedList),
                        msg_id = rabbit_data_coercion:to_binary(lists:nth(2, ValidatedList)),
                        action = case ValidatedList of
                                    [_Type, _MsgId, Action | _] when is_binary(Action) -> Action;
                                    _ -> undefined
                                 end,
                        payload = Data
                    }, UpdatedState};
                {error, Reason} ->
                    {error, Reason}
            end;
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

%% Seamlessly update both ETS tables without causing 404 errors
-spec force_stats_refresh(state()) -> ok.
force_stats_refresh(State = #state{cfg = #cfg{client_id = ClientId}}) ->
    try
        Pid = self(),
        %% Get fresh client properties from our state
        FreshClientProps = info(client_properties, State),

        % rabbit_core_metrics:connection_created(Pid, FreshClientProps),

        % %% 1. Update connection_created table (source of truth)
        % case ets:lookup(connection_created, Pid) of
        %     [{Pid, OldInfos}] ->
        %         UpdatedInfos = lists:keystore(client_properties, 1, OldInfos, 
        %                                     {client_properties, FreshClientProps}),
        %         ets:insert(connection_created, {Pid, UpdatedInfos}),
        %         ?LOG_DEBUG("OCPP updated connection_created table for ~ts", [ClientId]);
        %     [] ->
        %         ?LOG_WARNING("OCPP connection ~ts not found in connection_created ETS", [ClientId])
        % end,
        
        %% 2. Update connection_created_stats table (formatted version) in-place
        case ets:lookup(connection_created_stats, Pid) of
            [{Pid, ConnName, OldStatsInfos}] ->
                %% Convert proplist to map format using the same function as management plugin
                FormattedClientProps = rabbit_misc:amqp_table(FreshClientProps),
                UpdatedStatsInfos = lists:keystore(client_properties, 1, OldStatsInfos,
                                                 {client_properties, FormattedClientProps}),
                ets:insert(connection_created_stats, {Pid, ConnName, UpdatedStatsInfos}),
                ?LOG_DEBUG("OCPP updated connection_created_stats table for ~ts", [ClientId]);
            [] ->
                %% Stats entry doesn't exist yet - that's fine, it will be created on next collection
                ?LOG_DEBUG("OCPP connection_created_stats entry not found for ~ts (will be created on next collection)", [ClientId])
        end,
        
        % %% 3. Clear management cache to ensure API returns fresh data
        % try
        %     ProcName = rabbit_mgmt_db_cache:process_name(connections),
        %     case whereis(ProcName) of
        %         undefined -> ok;
        %         CachePid -> gen_server:call(CachePid, purge_cache, 5000)
        %     end
        % catch _:_ -> ok end,
        
        ?LOG_DEBUG("OCPP seamlessly updated connection stats for ~ts", [ClientId])
        
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING("Failed to refresh connection stats for ~ts: ~p:~p~n~p",
                         [ClientId, Class, Reason, Stacktrace])
    end,
    ok.

%% @doc Updates state properties based on specific OCPP message actions.
%% Currently handles BootNotification to update user_prop with device info.
-spec maybe_update_props_from_message(list(), state()) -> state().
maybe_update_props_from_message([?OCPP_MESSAGE_TYPE_CALL, _MsgId, <<"BootNotification">>, Payload],
                                State = #state{cfg = Cfg = #cfg{user_prop = OldProps, proto_ver = ?OCPP_PROTO_V16}}) 
  when is_map(Payload) ->
    try
        NewPropsList = maps:to_list(Payload),
        MergedProps = lists:foldl(
          fun({K, V}, Acc) ->
                  BinKey = rabbit_data_coercion:to_binary(K),
                  BinVal = rabbit_data_coercion:to_binary(V),
                  lists:keystore(BinKey, 1, Acc, {BinKey, longstr, BinVal})
          end, OldProps, NewPropsList),
        ?LOG_DEBUG("Updated user_prop from BootNotification: ~p", [MergedProps]),
        %% IMPORTANT: Update state FIRST, then refresh stats with updated state
        UpdatedState = State#state{cfg = Cfg#cfg{user_prop = MergedProps}},
        force_stats_refresh(UpdatedState),
        UpdatedState
    catch
        error:Reason ->
            ?LOG_WARNING("Could not process BootNotification payload for user_prop update. Reason: ~p", [Reason]),
            State
    end;

maybe_update_props_from_message([?OCPP_MESSAGE_TYPE_CALL, _MsgId, <<"Heartbeat">>, _Payload], State) ->
    %% Could update last_heartbeat timestamp in user_prop
    State;

maybe_update_props_from_message([?OCPP_MESSAGE_TYPE_CALL, _MsgId, <<"StatusNotification">>, Payload], 
                                State = #state{cfg = Cfg = #cfg{user_prop = OldProps, proto_ver = ?OCPP_PROTO_V16}})
  when is_map(Payload) ->
    %% Extract required fields from the Payload
    case {maps:get(<<"connectorId">>, Payload, undefined),
          maps:get(<<"status">>, Payload, undefined),
          maps:get(<<"errorCode">>, Payload, undefined)} of
        {ConnectorId, Status, ErrorCode} when is_integer(ConnectorId), is_binary(Status), is_binary(ErrorCode) ->
            %% Construct the key and value for user_prop
            ConnectorIdBin = erlang:integer_to_binary(ConnectorId),
            Key = <<"statusConnectorId", ConnectorIdBin/binary>>,
            %% Store a nested object with status and errorCode
            Value = [{<<"status">>, Status}, {<<"errorCode">>, ErrorCode}],
            UpdatedProps = lists:keystore(Key, 1, OldProps, {Key, longstr, Value}),
            %% Update state and refresh stats
            UpdatedState = State#state{cfg = Cfg#cfg{user_prop = UpdatedProps}},
            force_stats_refresh(UpdatedState),
            UpdatedState;
        _ ->
            %% If any field is missing or invalid, return the original state
            State
    end;

%% Default case - no state update needed
maybe_update_props_from_message(_DecodedList, State) ->
    State.

-spec info(rabbit_types:info_key(), state()) -> any().
info(host, #state{cfg = #cfg{ip_addr = Val}}) -> Val;
info(port, #state{cfg = #cfg{port = Val}}) -> Val;
info(peer_host, #state{cfg = #cfg{peer_ip_addr = Val}}) -> Val;
info(peer_port, #state{cfg = #cfg{peer_port = Val}}) -> Val;
info(connected_at, #state{cfg = #cfg{connected_at = Val}}) -> Val;
info(ssl_login_name, #state{cfg = #cfg{ssl_login_name = Val}}) -> Val;
info(user_who_performed_action, S) ->
    info(user, S);
info(prefetch_count, #state{cfg = #cfg{prefetch = Val}}) -> Val;
info(user, #state{auth_state = #auth_state{user = #user{username = Val}}}) -> Val;
info(user_property, #state{cfg = #cfg{user_prop = Val}}) -> Val;
info(vhost, #state{cfg = #cfg{vhost = Val}}) -> Val;
%% for rabbitmq_management/priv/www/js/tmpl/connection.ejs
info(client_properties, #state{cfg = #cfg{client_id = ClientId,
                                          user_prop = Prop}}) ->
    ?LOG_DEBUG("OCPP client_properties for ~ts: ~p", [ClientId, Prop]),
    L = [{chargePointId, longstr, ClientId},
         {connection_name, longstr, <<"Charging Point">>}],
    PropWithAtomKeys = [{binary_to_atom(K, utf8), T, V} || {K, T, V} <- Prop],
    Result = L ++ PropWithAtomKeys,
    ?LOG_DEBUG("OCPP client_properties AFTER for ~ts: ~p", [ClientId, Result]),
    Result;
info(channel_max, _) -> 0;
info(node, _) -> node();
info(frame_max, _) -> 0; % Not applicable like MQTT
%% SASL not supported?
info(auth_mechanism, _) -> <<"BASIC">>;
info(recv_oct, _) -> erlang:process_info(self(), message_queue_len); % Approx incoming? Needs better metric
info(send_oct, _) -> 0; % Hard to track accurately here
info(Other, #state{cfg=#cfg{client_id=ClientId}}) ->
    ?LOG_DEBUG("OCPP info request for ~ts: ~p", [ClientId, Other]),
    undefined.

%% Internal function to validate the structure of the already decoded list based on OCPP message type.
%% Returns {ok, DecodedList :: list()} | {error, Reason :: binary()}.
-spec process_decoded_message(list()) -> {ok, list()} | {error, binary()}.
process_decoded_message([?OCPP_MESSAGE_TYPE_CALL, MessageId, Action, _Payload] = Decoded) ->
    ?LOG_DEBUG("Validated CALL: Id=~tp, Action=~tp", [MessageId, Action]), % Log less verbosely here
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLRESULT, MessageId, _Payload] = Decoded) ->
     ?LOG_DEBUG("Validated CALLRESULT: Id=~tp", [MessageId]),
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLERROR, MessageId, ErrorCode, _ErrorDescription, _ErrorDetails] = Decoded) ->
     ?LOG_DEBUG("Validated CALLERROR: Id=~tp, Code=~tp", [MessageId, ErrorCode]),
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_CALLRESULTERROR, MessageId, ErrorCode, _ErrorDescription, _ErrorDetails] = Decoded) -> % OCPP 2.1
     ?LOG_DEBUG("Validated CALLRESULTERROR: Id=~tp, Code=~tp", [MessageId, ErrorCode]),
    {ok, Decoded};
process_decoded_message([?OCPP_MESSAGE_TYPE_SEND, MessageId, Action, _Payload] = Decoded) -> % OCPP 2.1
     ?LOG_DEBUG("Validated SEND: Id=~tp, Action=~tp", [MessageId, Action]),
    {ok, Decoded};
process_decoded_message(Decoded) ->
    % The list structure doesn't match any known OCPP message type/format
    ?LOG_ERROR("Received invalid OCPP message structure: ~tp", [Decoded]),
    {error, <<"Invalid OCPP message structure">>}.

-spec proto_version_tuple(ocpp_protocol_version_atom() | undefined) -> tuple() | undefined.
proto_version_tuple(?OCPP_PROTO_V12) -> {1, 2};
proto_version_tuple(?OCPP_PROTO_V15) -> {1, 5};
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