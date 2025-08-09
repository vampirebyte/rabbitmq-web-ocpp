%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2024 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(rabbit_web_ocpp_app).

-behaviour(application).

-include_lib("rabbit_common/include/rabbit.hrl").
-include("rabbit_web_ocpp.hrl").

-export([
    start/2,
    prep_stop/1,
    stop/1,
    list_connections/0,
    emit_connection_info_all/4,
    emit_connection_info_local/3
]).

%% Dummy supervisor - see Ulf Wiger's comment at
%% http://erlang.org/pipermail/erlang-questions/2010-April/050508.html
-behaviour(supervisor).
-export([init/1]).

-import(rabbit_misc, [pget/2]).

%%
%% API
%%

-spec start(_, _) -> {ok, pid()}.
start(_Type, _StartArgs) ->
    ocpp_init(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec prep_stop(term()) -> term().
prep_stop(State) ->
    State.

-spec stop(_) -> ok.
stop(_State) ->
    _ = rabbit_networking:stop_ranch_listener_of_protocol(?OCPP_TCP_PROTOCOL),
    _ = rabbit_networking:stop_ranch_listener_of_protocol(?OCPP_TLS_PROTOCOL),
    ok.

init([]) ->
    %% Use separate process group scope per RabbitMQ node. This achieves a local-only
    %% process group which requires less memory with millions of connections.
    PgScope = rabbit:pg_local_scope(?PG_SCOPE),
    persistent_term:put(?PG_SCOPE, PgScope),

    %% Define the children for the supervision tree
    Children = [
        #{id => PgScope,
          start => {pg, start_link, [PgScope]},
          restart => transient,
          shutdown => ?WORKER_WAIT,
          type => worker,
          modules => [pg]}
    ],

    %% Return the supervision strategy and children
    {ok, {{one_for_one, 1, 5}, Children}}.

-spec list_connections() -> [pid()].
list_connections() ->
    PlainPids = rabbit_networking:list_local_connections_of_protocol(?OCPP_TCP_PROTOCOL),
    TLSPids   = rabbit_networking:list_local_connections_of_protocol(?OCPP_TLS_PROTOCOL),
    PlainPids ++ TLSPids.

-spec emit_connection_info_all([node()], rabbit_types:info_keys(), reference(), pid()) -> term().
emit_connection_info_all(Nodes, Items, Ref, AggregatorPid) ->
    Pids = [spawn_link(Node, ?MODULE, emit_connection_info_local,
                       [Items, Ref, AggregatorPid])
            || Node <- Nodes],

    rabbit_control_misc:await_emitters_termination(Pids).

-spec emit_connection_info_local(rabbit_types:info_keys(), reference(), pid()) -> ok.
emit_connection_info_local(Items, Ref, AggregatorPid) ->
    LocalPids = list_connections(),
    emit_connection_info(Items, Ref, AggregatorPid, LocalPids).

emit_connection_info(Items, Ref, AggregatorPid, Pids) ->
    rabbit_control_misc:emitting_map_with_exit_handler(
      AggregatorPid, Ref,
      fun(Pid) ->
              rabbit_web_ocpp_handler:info(Pid, Items)
      end, Pids).
%%
%% Implementation
%%

ocpp_init() ->
    CowboyOpts0  = maps:from_list(get_env(cowboy_opts, [])),
    CowboyWsOpts = maps:from_list(get_env(cowboy_ws_opts, [])),
    rabbit_log:info("OCPP Cowboy options: ~p", [CowboyWsOpts]),
    TcpConfig = get_env(tcp_config, []),
    SslConfig = get_env(ssl_config, []),
    %% To derive its connection URL, the Charge Point modifies the OCPP-J endpoint URL by appending to the
    %% path first a '/' (U+002F SOLIDUS) and then a string uniquely identifying the Charge Point. 
    %% This uniquely identifying string has to be percent-encoded as necessary as described in [RFC3986].
    %% [OCPP 1.6 JSON spec §3.1.1].
    FullPath = get_env(ws_path, "/ocpp") ++ "/:vhost/:client_id",
    Routes = cowboy_router:compile([{'_', [
        {FullPath, rabbit_web_ocpp_handler, [{ws_opts, CowboyWsOpts}]}
    ]}]),
    CowboyOpts = CowboyOpts0#{
                 env => #{dispatch => Routes},
                 proxy_header => get_env(proxy_protocol, false),
                 stream_handlers => [rabbit_web_ocpp_stream_handler, cowboy_stream_h]
                },
    start_tcp_listener(TcpConfig, CowboyOpts),
    start_tls_listener(SslConfig, CowboyOpts).

start_tcp_listener([], _) -> ok;
start_tcp_listener(TCPConf0, CowboyOpts) ->
    {TCPConf, IpStr, Port} = get_tcp_conf(TCPConf0),
    RanchRef = rabbit_networking:ranch_ref(TCPConf),
    RanchTransportOpts =
    #{
      socket_opts => TCPConf,
      max_connections => get_max_connections(),
      num_acceptors => get_env(num_tcp_acceptors, 10),
      num_conns_sups => get_env(num_conns_sup, 1)
     },
    case cowboy:start_clear(RanchRef, RanchTransportOpts, CowboyOpts) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, ErrTCP} ->
            rabbit_log:error(
              "Failed to start a WebSocket (HTTP) listener. Error: ~p, listener settings: ~p",
              [ErrTCP, TCPConf]),
            throw(ErrTCP)
    end,
    listener_started(?OCPP_TCP_PROTOCOL, TCPConf),
    rabbit_log:info("rabbit_web_ocpp: listening for HTTP connections on ~s:~w",
                    [IpStr, Port]).


start_tls_listener([], _) -> ok;
start_tls_listener(TLSConf0, CowboyOpts) ->
    _ = rabbit_networking:ensure_ssl(),
    {TLSConf, TLSIpStr, TLSPort} = get_tls_conf(TLSConf0),
    RanchRef = rabbit_networking:ranch_ref(TLSConf),
    RanchTransportOpts =
    #{
      socket_opts => TLSConf,
      max_connections => get_max_connections(),
      num_acceptors => get_env(num_ssl_acceptors, 10),
      num_conns_sups => get_env(num_conns_sup, 1)
     },
    case cowboy:start_tls(RanchRef, RanchTransportOpts, CowboyOpts) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, ErrTLS} ->
            rabbit_log:error(
              "Failed to start a TLS WebSocket (HTTPS) listener. Error: ~p, listener settings: ~p",
              [ErrTLS, TLSConf]),
            throw(ErrTLS)
    end,
    listener_started(?OCPP_TLS_PROTOCOL, TLSConf),
    rabbit_log:info("rabbit_web_ocpp: listening for HTTPS connections on ~s:~w",
                    [TLSIpStr, TLSPort]).

listener_started(Protocol, Listener) ->
    Port = rabbit_misc:pget(port, Listener),
    _ = case rabbit_misc:pget(ip, Listener) of
            undefined ->
                [rabbit_networking:tcp_listener_started(Protocol, Listener,
                                                        IPAddress, Port)
                 || {IPAddress, _Port, _Family}
                        <- rabbit_networking:tcp_listener_addresses(Port)];
            IP when is_tuple(IP) ->
                rabbit_networking:tcp_listener_started(Protocol, Listener,
                                                       IP, Port);
            IP when is_list(IP) ->
                {ok, ParsedIP} = inet_parse:address(IP),
                rabbit_networking:tcp_listener_started(Protocol, Listener,
                                                       ParsedIP, Port)
        end,
    ok.

get_tcp_conf(TCPConf0) ->
    TCPConf1 = case proplists:get_value(port, TCPConf0) of
                   undefined -> [{port, 19520}|TCPConf0];
                   _ -> TCPConf0
               end,
    get_ip_port(TCPConf1).

get_tls_conf(TLSConf0) ->
    TLSConf1 = case proplists:get_value(port, TLSConf0) of
                   undefined -> [{port, 19521}|proplists:delete(port, TLSConf0)];
                   _ -> TLSConf0
               end,
    get_ip_port(TLSConf1).

get_ip_port(Conf0) ->
    IpStr = proplists:get_value(ip, Conf0),
    Ip = normalize_ip(IpStr),
    Conf1 = lists:keyreplace(ip, 1, Conf0, {ip, Ip}),
    Port = proplists:get_value(port, Conf1),
    {Conf1, IpStr, Port}.

normalize_ip(IpStr) when is_list(IpStr) ->
    {ok, Ip} = inet:parse_address(IpStr),
    Ip;
normalize_ip(Ip) ->
    Ip.

get_max_connections() ->
  get_env(max_connections, infinity).

get_env(Key, Default) ->
    rabbit_misc:get_env(?APP_NAME, Key, Default).
