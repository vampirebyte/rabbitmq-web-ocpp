%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2024 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(rabbit_web_ocpp_handler).
-behaviour(cowboy_websocket).
-behaviour(cowboy_sub_protocol).

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/logging.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include("rabbit_web_ocpp.hrl").

-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).

-export([info/2]).

%% cowboy_sub_protocol
-export([upgrade/4,
         upgrade/5,
         takeover/7]).

-define(APP, rabbitmq_web_ocpp).

-ifdef(TEST).
-define(SILENT_CLOSE_DELAY, 10).
-else.
-define(SILENT_CLOSE_DELAY, 3_000).
-endif.

-record(state, {
          socket :: {rabbit_proxy_socket, any(), any()} | rabbit_net:socket(),
          proc_state :: rabbit_web_ocpp_processor:state(),
          connection_state = running :: running | blocked,
          stats_timer :: option(rabbit_event:state()),
          vhost :: rabbit_types:vhost(),
          client_id :: client_id(),
          user :: #user{},
          conn_name :: option(binary()),
          idle_timeout :: timeout(), %% from cowboy, in seconds
          proto_ver :: ocpp_protocol_version_atom()
         }).

-type state() :: #state{}.

%% cowboy_sub_protcol
upgrade(Req, Env, Handler, HandlerState) ->
    upgrade(Req, Env, Handler, HandlerState, #{}).

upgrade(Req, Env, Handler, HandlerState, Opts) ->
    cowboy_websocket:upgrade(Req, Env, Handler, HandlerState, Opts).

takeover(Parent, Ref, Socket, Transport, Opts, Buffer, {Handler, HandlerState}) ->
    Sock = case HandlerState#state.socket of
               undefined ->
                   Socket;
               ProxyInfo ->
                   {rabbit_proxy_socket, Socket, ProxyInfo}
           end,
    cowboy_websocket:takeover(Parent, Ref, Socket, Transport, Opts, Buffer,
                              {Handler, HandlerState#state{socket = Sock}}).

%% cowboy_websocket
init(Req, Opts) ->
    %% Retrieve the vhost and client_id from URL path first
    Vhost = cowboy_req:binding(vhost, Req),
    ClientId = cowboy_req:binding(client_id, Req),

    case {Vhost, ClientId} of
        {<<>>, _} ->
            {ok, cowboy_req:reply(404, #{}, <<"Vhost not specified">>, Req), #state{}};
        {_, <<>>} ->
            {ok, cowboy_req:reply(404, #{}, <<"Client ID not specified">>, Req), #state{}};
        {V1, CId} when V1 =:= <<>> orelse CId =:= <<>> ->
            {ok, cowboy_req:reply(404, #{}, <<"Invalid Vhost or Client ID">>, Req), #state{}};
        {V2, CId} ->
            %% ClientId is valid, now check subprotocol
            case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
                undefined ->
                    no_supported_sub_protocol(undefined, ClientId, Req);
                ProtocolList ->
                    %% Map protocols to their atom representations, filtering out unsupported ones
                    SupportedProtos = [{Proto, ?OCPP_PROTO_TO_ATOM(Proto)} || 
                                       Proto <- ProtocolList, 
                                       ?OCPP_PROTO_TO_ATOM(Proto) =/= undefined],

                    case SupportedProtos of
                        [] ->
                            no_supported_sub_protocol(ProtocolList, ClientId, Req);
                        [{MatchingProtocol, ProtocolVer}|_] ->
                            %% First supported protocol is selected (preserving client preference order)
                            Req1 = cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, 
                                                             MatchingProtocol, Req),
                            AuthHd = cowboy_req:header(<<"authorization">>, Req, <<>>),
                            case AuthHd of
                                <<>> ->
                                    %% No Authorization header, request credentials
                                    Headers = #{<<"www-authenticate">> => <<"Basic realm=\"RabbitMQ\"">>},
                                    {ok, cowboy_req:reply(401, Headers, <<"Unauthorized">>, Req), #state{}};
                                _ ->
                                    case cow_http_hd:parse_authorization(AuthHd) of
                                        {basic, Username, Password} ->
                                            %% Perform authentication check here
                                            case rabbit_access_control:check_user_login(
                                                    Username, [{password, Password}]) of
                                                {ok, User} ->
                                                    State0 = #state{socket = maps:get(proxy_header, Req, undefined),
                                                                proto_ver = ProtocolVer,
                                                                vhost = V2,
                                                                user = User,
                                                                client_id = CId},
                                                    WsOpts0 = proplists:get_value(ws_opts, Opts, #{}),
                                                    IdleTimeoutMs = maps:get(idle_timeout, WsOpts0, ?DEFAULT_IDLE_TIMEOUT_MS),
                                                    WsOpts = maps:merge(#{compress => true, idle_timeout => IdleTimeoutMs}, WsOpts0),
                                                    IdleTimeoutS = case IdleTimeoutMs of
                                                                    infinity -> 0;
                                                                    Ms -> Ms div 1000
                                                                   end,
                                                    State = State0#state{idle_timeout = IdleTimeoutS},
                                                    {?MODULE, Req1, State, WsOpts};
                                                {error, _Reason} ->
                                                    Headers = #{<<"www-authenticate">> => <<"Basic realm=\"RabbitMQ\"">>},
                                                    {ok, cowboy_req:reply(401, Headers, <<"Unauthorized">>, Req), #state{}}
                                            end;
                                        _ ->
                                            %% Invalid Authorization header format
                                            Headers = #{<<"www-authenticate">> => <<"Basic realm=\"RabbitMQ\"">>},
                                            {ok, cowboy_req:reply(401, Headers, <<"Unauthorized">>, Req), #state{}}
                                    end
                            end
                    end
            end
    end.

%% We cannot use a gen_server call, because the handler process is a
%% special cowboy_websocket process (not a gen_server) which assumes
%% all gen_server calls are supervisor calls, and does not pass on the
%% request to this callback module. (see cowboy_websocket:loop/3 and
%% cowboy_children:handle_supervisor_call/4) However using a generic
%% gen:call with a special label ?MODULE works fine.
-spec info(pid(), rabbit_types:info_keys()) ->
    rabbit_types:infos().
info(Pid, all) ->
    info(Pid, ?INFO_ITEMS);
info(Pid, Items) ->
    {ok, Res} = gen:call(Pid, ?MODULE, {info, Items}),
    Res.
-spec websocket_init(state()) ->
    {cowboy_websocket:commands(), state()} |
    {cowboy_websocket:commands(), state(), hibernate}.
websocket_init(State0 = #state{socket = Socket, vhost = Vhost, client_id = ClientId, proto_ver = ProtoVer}) ->
    logger:set_process_metadata(#{domain => ?RMQLOG_DOMAIN_CONN ++ [web_ocpp]}),
    case rabbit_net:connection_string(Socket, inbound) of
        {ok, ConnStr} ->
            ConnName = rabbit_data_coercion:to_binary(ConnStr),
            ?LOG_INFO("Accepting Web OCPP connection ~s for client ID ~p", [ConnName, ClientId]),
            State1 = State0#state{conn_name = ConnName},
            State2 = rabbit_event:init_stats_timer(State1, #state.stats_timer),
            % Inside `init` of the processor "connection_created" is called for management UI to show the connection
            case rabbit_web_ocpp_processor:init(Vhost, ClientId, ProtoVer, rabbit_net:unwrap_socket(Socket),
                                                    ConnName, fun send_reply/1) of
                {ok, ProcState} ->
                    ?LOG_INFO("Accepted Web OCPP connection ~ts for client ID ~ts",
                                [ConnName, ClientId]),
                    FinalState = State2#state{proc_state = ProcState},
                    process_flag(trap_exit, true),
                    % `ensure_stats_timer` is needed to trigger the initial stats collection
                    % and update the connection state to "running" in the management UI
                    {[], ensure_stats_timer(FinalState), hibernate};
                {error, Reason} ->
                    ?LOG_ERROR("Rejected Web OCPP connection ~ts: ~p", [ConnName, Reason]),
                    self() ! {stop, ?CLOSE_PROTOCOL_ERROR, connect_packet_rejected},
                    {[], State2}
            end;
        {error, Reason} ->
            {[{shutdown_reason, Reason}], State0}
    end.

-spec websocket_handle(ping | pong | {text | binary | ping | pong, binary()}, State) ->
    {cowboy_websocket:commands(), State} |
    {cowboy_websocket:commands(), State, hibernate}.
%% Handle text (JSON) frames (pass to processor)
websocket_handle({text, Data}, State = #state{conn_name = ConnName, client_id = ClientId, proc_state = ProcState0}) ->
    %% Call processor module to handle decoding and validation first
    case rabbit_web_ocpp_processor:handle_text_frame(Data, ProcState0) of
        {ok, McOcpp, ProcState1} ->
            % Decoding and validation successful, now process the incoming message
            % Pass both the decoded list and the original raw binary
            case rabbit_web_ocpp_processor:process_incoming(McOcpp, ProcState1) of
                {ok, NewProcState} ->
                    % Message successfully published to the exchange
                    ?LOG_DEBUG("Web OCPP message processed and published for ~p (~p)",
                               [ClientId, ConnName]),
                    NewState = State#state{proc_state = NewProcState},
                    {[], ensure_stats_timer(NewState), hibernate};
                {error, Reason, _ProcState} ->
                    % Publish permission denied or other processing error
                    ?LOG_ERROR("OCPP message processing failed for ~p (~p). Reason: ~tp",
                               [ClientId, ConnName, Reason]),
                    % Use access_refused specific code if possible, otherwise protocol error
                    CloseCode = case Reason of
                                    {error, access_refused} -> ?CLOSE_POLICY_VIOLATION;
                                    _ -> ?CLOSE_PROTOCOL_ERROR
                                end,
                    stop(State, CloseCode, Reason)
            end;
        {error, Reason} ->
            % Decoding or validation failed
            ?LOG_ERROR("OCPP message handling failed (decode/validate) for ~p (~p). Reason: ~tp",
                       [ClientId, ConnName, Reason]),
            %% Determine close code based on reason
            CloseCode = case Reason of
                            <<"Invalid JSON">> -> ?CLOSE_INVALID_PAYLOAD;
                            <<"Invalid OCPP message structure">> -> ?CLOSE_PROTOCOL_ERROR; % Or maybe 1007?
                            _ -> ?CLOSE_PROTOCOL_ERROR % Default to protocol error
                        end,
            stop(State, CloseCode, Reason)
    end;
%% Silently ignore ping and pong frames as Cowboy will automatically reply to ping frames.
websocket_handle({Ping, _}, State)
  when Ping =:= ping orelse Ping =:= pong ->
    {[], State, hibernate};
websocket_handle(Ping, State)
  when Ping =:= ping orelse Ping =:= pong ->
    {[], State, hibernate};
%% Log and close connection when receiving any other unexpected frames.
%% This includes binary (compressed) frames, which are not implemented yet.
websocket_handle(Frame, State = #state{conn_name = ConnName, client_id = ClientId}) ->
    ?LOG_INFO("Web OCPP: unexpected WebSocket frame from client ID ~p (~p): ~tp", [ClientId, ConnName, Frame]),
    stop(State, ?CLOSE_UNACCEPTABLE_DATA_TYPE, <<"unexpected WebSocket frame type">>).

-spec websocket_info(any(), State) ->
    {cowboy_websocket:commands(), State} |
    {cowboy_websocket:commands(), State, hibernate}.
websocket_info({reply, Data}, State) ->
    % Send the data as text frame (JSON)
    {[{text, Data}], State, hibernate};
websocket_info({stop, CloseCode, Error}, State) ->
    stop(State, CloseCode, Error);
websocket_info({'EXIT', _, _}, State) ->
    stop(State);
websocket_info({'$gen_cast', QueueEvent = {queue_event, _, _}},
               State = #state{proc_state = PState0}) ->
    case rabbit_web_ocpp_processor:handle_info(QueueEvent, PState0) of
        {ok, PState} ->
            % Update the processor state and return to the WebSocket handler
            NewState = State#state{proc_state = PState},
            {[], NewState, hibernate};
        {error, Reason, PState} ->
            ?LOG_ERROR("Web OCPP connection ~p failed to handle queue event: ~p",
                       [State#state.conn_name, Reason]),
            stop(State#state{proc_state = PState})
    end;
websocket_info({'$gen_cast', {duplicate_id}},
               State = #state{client_id = ClientId,
                              conn_name = ConnName}) ->
    ?LOG_WARNING("Web OCPP disconnecting a client with duplicate ID '~s' (~p)",
                 [ClientId, ConnName]),
    defer_close(?CLOSE_NORMAL),
    {[], State};
websocket_info({'$gen_cast', {close_connection, Reason}},
               State = #state{client_id = ClientId,
                              conn_name = ConnName}) ->
    ?LOG_WARNING("Web OCPP disconnecting client with ID '~s' (~p), reason: ~s",
                 [ClientId, ConnName, Reason]),
    case Reason of
        maintenance ->
            defer_close(?CLOSE_SERVER_GOING_DOWN),
            {[], State};
        _ ->
            stop(State)
    end;
websocket_info({'$gen_cast', {force_event_refresh, Ref}}, State0) ->
    Infos = infos(?EVENT_KEYS, State0),
    rabbit_event:notify(connection_created, Infos, Ref),
    State = rabbit_event:init_stats_timer(State0, #state.stats_timer),
    {[], State, hibernate};
websocket_info({'$gen_cast', refresh_config},
               State0 = #state{conn_name = _ConnName}) ->
    State = State0,
    {[], State, hibernate};
websocket_info(credential_expired,
               State = #state{client_id = ClientId,
                              conn_name = ConnName}) ->
    ?LOG_WARNING("Web OCPP disconnecting client with ID '~s' (~p) because credential expired",
                 [ClientId, ConnName]),
    defer_close(?CLOSE_NORMAL),
    {[], State};
websocket_info(emit_stats, State) ->
    {[], emit_stats(State), hibernate};
websocket_info({{'DOWN', _QName}, _MRef, process, _Pid, _Reason} = _Evt,
               State = #state{}) ->
    {[], State};
websocket_info({'DOWN', _MRef, process, QPid, _Reason}, State) ->
    rabbit_amqqueue_common:notify_sent_queue_down(QPid),
    {[], State, hibernate};
websocket_info({shutdown, Reason}, #state{conn_name = ConnName} = State) ->
    %% rabbitmq_management plugin requests to close connection.
    ?LOG_INFO("Web OCPP closing connection ~tp: ~tp", [ConnName, Reason]),
    stop(State, ?CLOSE_NORMAL, Reason);
websocket_info(connection_created, State) ->
    Infos = infos(?EVENT_KEYS, State),
    rabbit_core_metrics:connection_created(self(), Infos),
    rabbit_event:notify(connection_created, Infos),
    {[], State, hibernate};
websocket_info({?MODULE, From, {info, Items}}, State) ->
    Infos = infos(Items, State),
    gen:reply(From, Infos),
    {[], State, hibernate};
websocket_info(Msg, State) ->
    ?LOG_WARNING("Web OCPP: unexpected message ~tp", [Msg]),
    {[], State, hibernate}.

terminate(Reason, _Request, #state{conn_name = ConnName,
                            proc_state = PState, % Can be undefined if init failed
                            client_id = ClientId} = State) ->
    ?LOG_INFO("Web OCPP closing connection ~ts for client ID ~p", [ConnName, ClientId]),
    maybe_emit_stats(State),
    case PState of
        undefined ->
            ok;
        _ ->
            Infos = infos(?EVENT_KEYS, State),
            rabbit_web_ocpp_processor:terminate(Reason, Infos, PState)
    end.

%% Internal.

-spec ssl_login_name(rabbit_net:socket()) ->
    none | binary().
ssl_login_name(Sock) ->
    case rabbit_net:peercert(Sock) of
        {ok, C}              -> case rabbit_ssl:peer_cert_auth_name(C) of
                                    unsafe    -> none;
                                    not_found -> none;
                                    Name      -> Name
                                end;
        {error, no_peercert} -> none;
        nossl                -> none
    end.

check_credentials(Username, Password, SslLoginName, PeerIp) ->
    case creds(Username, Password, SslLoginName) of
        {ok, _, _} = Ok ->
            Ok;
        nocreds ->
            ?LOG_ERROR("MQTT login failed: no credentials provided"),
            auth_attempt_failed(PeerIp, <<>>),
            {error, ?CLOSE_POLICY_VIOLATION};
        {invalid_creds, {undefined, Pass}} when is_binary(Pass) ->
            ?LOG_ERROR("MQTT login failed: no username is provided"),
            auth_attempt_failed(PeerIp, <<>>),
            {error, ?CLOSE_POLICY_VIOLATION};
        {invalid_creds, {User, _Pass}} when is_binary(User) ->
            ?LOG_ERROR("MQTT login failed for user '~s': no password provided", [User]),
            auth_attempt_failed(PeerIp, User),
            {error, ?CLOSE_POLICY_VIOLATION}
    end.

creds(User, Pass, SSLLoginName) ->
    CredentialsProvided = User =/= undefined orelse Pass =/= undefined,
    ValidCredentials = is_binary(User) andalso is_binary(Pass) andalso Pass =/= <<>>,
    {ok, TLSAuth} = application:get_env(?APP_NAME, ssl_cert_login),
    SSLLoginProvided = TLSAuth =:= true andalso SSLLoginName =/= none,

    case {CredentialsProvided, ValidCredentials, SSLLoginProvided} of
        {true, true, _} ->
            %% Username and password take priority
            {ok, User, Pass};
        {true, false, _} ->
            %% Either username or password is provided
            {invalid_creds, {User, Pass}};
        {false, false, true} ->
            %% rabbitmq_mqtt.ssl_cert_login is true. SSL user name provided.
            %% Authenticating using username only.
            {ok, SSLLoginName, none};
        {false, false, false} ->
            {ok, AllowAnon} = application:get_env(?APP_NAME, allow_anonymous),
            case AllowAnon of
                true ->
                    case rabbit_auth_mechanism_anonymous:credentials() of
                        {ok, _, _} = Ok ->
                            Ok;
                        error ->
                            nocreds
                    end;
                false ->
                    nocreds
            end;
        _ ->
            nocreds
    end.

-spec auth_attempt_failed(inet:ip_address(), binary()) -> ok.
auth_attempt_failed(PeerIp, Username) ->
    rabbit_core_metrics:auth_attempt_failed(PeerIp, Username, ocpp),
    timer:sleep(?SILENT_CLOSE_DELAY).

no_supported_sub_protocol(Protocol, ClientId, Req) ->
    %% The client MUST include a valid ocpp version in the list of
    %% WebSocket Sub Protocols it offers [OCPP 1.6 JSON spec §3.1.2].
    ?LOG_ERROR("Web OCPP: Invalid 'ocppX.X' version included in client (~p) offered subprotocols: ~tp", [ClientId, Protocol]),
    {ok,
     cowboy_req:reply(400, #{<<"connection">> => <<"close">>}, Req),
     #state{}}.

%% Allow DISCONNECT packet to be sent to client before closing the connection.
defer_close(CloseStatusCode) ->
    self() ! {stop, CloseStatusCode, server_initiated_disconnect},
    ok.

% stop_ocpp_protocol_error(State, Reason, ConnName) ->
%     ?LOG_WARNING("Web OCPP protocol error ~tp for connection ~tp", [Reason, ConnName]),
%     stop(State, ?CLOSE_PROTOCOL_ERROR, Reason).

stop(State) ->
    stop(State, ?CLOSE_NORMAL, "OCPP died").

stop(State, CloseCode, Error0) ->
    Error = rabbit_data_coercion:to_binary(Error0),
    {[{close, CloseCode, Error}], State}.

-spec send_reply(binary()) -> ok. % Data is now JSON binary
send_reply(Data) ->
    self() ! {reply, Data},
    ok.

ensure_stats_timer(State) ->
    rabbit_event:ensure_stats_timer(State, #state.stats_timer, emit_stats).

maybe_emit_stats(#state{stats_timer = undefined}) ->
    ok;
maybe_emit_stats(State) ->
    rabbit_event:if_enabled(State, #state.stats_timer,
                                fun() -> emit_stats(State) end).

emit_stats(State) ->
    [{_, Pid},
     {_, RecvOct},
     {_, SendOct},
     {_, Reductions}] = infos(?SIMPLE_METRICS, State),
    Infos = infos(?OTHER_METRICS, State),
    rabbit_core_metrics:connection_stats(Pid, Infos),
    rabbit_core_metrics:connection_stats(Pid, RecvOct, SendOct, Reductions),
    State1 = rabbit_event:reset_stats_timer(State, #state.stats_timer),
    ensure_stats_timer(State1).

infos(Items, State) ->
    [{Item, i(Item, State)} || Item <- Items].

i(pid, _) ->
    self();
i(SockStat, #state{socket = Sock})
  when SockStat =:= recv_oct;
       SockStat =:= recv_cnt;
       SockStat =:= send_oct;
       SockStat =:= send_cnt;
       SockStat =:= send_pend ->
    case rabbit_net:getstat(Sock, [SockStat]) of
        {ok, [{_, N}]} when is_number(N) ->
            N;
        _ ->
            0
    end;
i(reductions, _) ->
    {reductions, Reductions} = erlang:process_info(self(), reductions),
    Reductions;
i(garbage_collection, _) ->
    rabbit_misc:get_gc_info(self());
i(protocol, #state{proto_ver = ProtocolVer, socket = Sock}) ->
    ProtocolName = case rabbit_net:is_ssl(Sock) of
        true -> "WSS OCPP";
        false -> "WS OCPP"
    end,
    {ProtocolName, rabbit_web_ocpp_processor:proto_version_tuple(ProtocolVer)};
i(SSL, #state{socket = Sock})
  when SSL =:= ssl;
       SSL =:= ssl_protocol;
       SSL =:= ssl_key_exchange;
       SSL =:= ssl_cipher;
       SSL =:= ssl_hash ->
    rabbit_ssl:info(SSL, {rabbit_net:unwrap_socket(Sock),
                          rabbit_net:maybe_get_proxy_socket(Sock)});
i(name, S) ->
    i(conn_name, S);
i(conn_name, #state{conn_name = Val}) ->
    Val;
i(client_id, #state{client_id = Val}) ->
    Val;
i(Cert, #state{socket = Sock})
  when Cert =:= peer_cert_issuer;
       Cert =:= peer_cert_subject;
       Cert =:= peer_cert_validity ->
    rabbit_ssl:cert_info(Cert, rabbit_net:unwrap_socket(Sock));
i(state, S) ->
    i(connection_state, S);
i(connection_state, #state{connection_state = Val}) ->
    Val;
i(timeout, #state{idle_timeout = Val}) ->
    Val;
i(Key, #state{proc_state = PState}) ->
    % Handle the rest of the keys from processor state
    case PState of
        undefined -> undefined;
        _ -> rabbit_web_ocpp_processor:info(Key, PState)
    end.
