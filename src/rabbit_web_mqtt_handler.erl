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

-record(state, {
          socket :: {rabbit_proxy_socket, any(), any()} | rabbit_net:socket(),
          stats_timer :: option(rabbit_event:state()),
          conn_name :: option(binary()),
          client_id :: option(binary()),
          protocol_ver :: ocpp_protocol_version_atom()
         }).

-type state() :: #state{}.

%% Close frame status codes as defined in https://www.rfc-editor.org/rfc/rfc6455#section-7.4.1
-define(CLOSE_NORMAL, 1000).
-define(CLOSE_SERVER_GOING_DOWN, 1001).
-define(CLOSE_PROTOCOL_ERROR, 1002).
-define(CLOSE_UNACCEPTABLE_DATA_TYPE, 1003).
-define(CLOSE_INVALID_PAYLOAD, 1007).
-define(CLOSE_POLICY_VIOLATION, 1008). % e.g., unsupported subprotocol

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
    %% Retrieve the client_id from URL first [OCPP 1.6 JSON spec §3.1.1].
    case cowboy_req:binding(client_id, Req) of
        ClientId when ClientId =:= undefined orelse ClientId =:= <<>> ->
            %% client_id path binding missing or empty, return 404
            {ok,
             cowboy_req:reply(404, #{}, <<"Not Found - Invalid Client ID">>, Req),
             #state{}};
        ClientId ->
            %% ClientId is valid, now check subprotocol
            case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
                undefined ->
                    no_supported_sub_protocol(undefined, ClientId, Req); % Pass ClientId for logging
                ProtocolList ->
                    Protocols = case ProtocolList of
                                    [Protocol] ->
                                        [Protocol];
                                    _ when is_list(ProtocolList) ->
                                        ProtocolList
                                end,
                    case lists:filter(fun(P) -> lists:member(P, ?OCPP_SUPPORTED_PROTOCOLS) end, Protocols) of
                        [] ->
                            no_supported_sub_protocol(ProtocolList, ClientId, Req); % Pass ClientId for logging
                        [MatchingProtocol|_] ->
                            %% Binding and subprotocol are valid, proceed
                            Req1 = cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, MatchingProtocol, Req),
                            State = #state{socket = maps:get(proxy_header, Req, undefined),
                                           client_id = ClientId}, % Store client_id
                            WsOpts0 = proplists:get_value(ws_opts, Opts, #{}),
                            WsOpts  = maps:merge(#{compress => true}, WsOpts0),
                            {?MODULE, Req1, State, WsOpts}
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
websocket_init(State0 = #state{socket = Sock, client_id = ClientId}) ->
    logger:set_process_metadata(#{domain => ?RMQLOG_DOMAIN_CONN ++ [web_ocpp]}),
    case rabbit_net:connection_string(Sock, inbound) of
        {ok, ConnStr} ->
            ConnName = rabbit_data_coercion:to_binary(ConnStr),
            ?LOG_INFO("Accepting Web OCPP connection ~s for client ID ~p", [ConnName, ClientId]),
            State1 = State0#state{conn_name = ConnName},
            State = rabbit_event:init_stats_timer(State1, #state.stats_timer),
            process_flag(trap_exit, true),
            {[], State, hibernate};
        {error, Reason} ->
            {[{shutdown_reason, Reason}], State0}
    end.

-spec websocket_handle(ping | pong | {text | binary | ping | pong, binary()}, State) ->
    {cowboy_websocket:commands(), State} |
    {cowboy_websocket:commands(), State, hibernate}.
%% Handle text (JSON) frames (pass to processor)
websocket_handle({text, Data}, State = #state{conn_name = ConnName, client_id = ClientId}) ->
    %% Call processor module to handle decoding and processing
    case rabbit_web_ocpp_processor:handle_text_frame(Data) of % Pass only Data
        {ok, DecodedMessage} ->
            % Log success with context from handler state
            ?LOG_INFO("Web OCPP JSON processed successfully for ~p (~p): ~tp",
                       [ClientId, ConnName, DecodedMessage]),
            % Processor is stateless, so we just return the original state
            {[], State, hibernate};
        {error, Reason} ->
            % Log failure with context from handler state
            ?LOG_ERROR("OCPP message handling failed for ~p (~p). Reason: ~tp",
                       [ClientId, ConnName, Reason]),
            %% Determine close code based on reason
            CloseCode = case Reason of
                            <<"Invalid JSON">> -> ?CLOSE_INVALID_PAYLOAD;
                            _ -> ?CLOSE_PROTOCOL_ERROR % Default to protocol error
                        end,
            % Pass the original state to stop/3
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
    {[{binary, Data}], State, hibernate};
websocket_info({stop, CloseCode, Error, SendWill}, State) ->
    stop({SendWill, State}, CloseCode, Error);
websocket_info({'EXIT', _, _}, State) ->
    stop(State);
websocket_info({'$gen_cast', _QueueEvent = {queue_event, _, _}},
               State = #state{}) ->
    {[], State};
websocket_info({'$gen_cast', {duplicate_id, SendWill}},
               State = #state{client_id = ClientId,
                              conn_name = ConnName}) ->
    ?LOG_WARNING("Web OCPP disconnecting a client with duplicate ID '~s' (~p)",
                 [ClientId, ConnName]),
    defer_close(?CLOSE_NORMAL, SendWill),
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

terminate(Reason, Request, #state{} = State) ->
    terminate(Reason, Request, {true, State});
terminate(_Reason, _Request,
          {_SendWill, #state{conn_name = ConnName, client_id = ClientId} = State}) ->
    ?LOG_INFO("Web OCPP closing connection ~ts for client ID ~p", [ConnName, ClientId]),
    maybe_emit_stats(State),
    ok.

%% Internal.

no_supported_sub_protocol(Protocol, ClientId, Req) ->
    %% The client MUST include a valid ocpp version in the list of
    %% WebSocket Sub Protocols it offers [OCPP 1.6 JSON spec §3.1.2].
    ?LOG_ERROR("Web OCPP: 'ocppX.X' version not included in client (~p) offered subprotocols: ~tp", [ClientId, Protocol]),
    {ok,
     cowboy_req:reply(400, #{<<"connection">> => <<"close">>}, Req),
     #state{}}.

%% Allow DISCONNECT packet to be sent to client before closing the connection.
defer_close(CloseStatusCode) ->
    defer_close(CloseStatusCode, true).

defer_close(CloseStatusCode, SendWill) ->
    self() ! {stop, CloseStatusCode, server_initiated_disconnect, SendWill},
    ok.

% stop_ocpp_protocol_error(State, Reason, ConnName) ->
%     ?LOG_WARNING("Web OCPP protocol error ~tp for connection ~tp", [Reason, ConnName]),
%     stop(State, ?CLOSE_PROTOCOL_ERROR, Reason).

stop(State) ->
    stop(State, ?CLOSE_NORMAL, "OCPP died").

stop(State, CloseCode, Error0) ->
    Error = rabbit_data_coercion:to_binary(Error0),
    {[{close, CloseCode, Error}], State}.

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
i(protocol, #state{}) ->
    {'Web OCPP', {1, 6}};
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
    rabbit_ssl:cert_info(Cert, rabbit_net:unwrap_socket(Sock)).
