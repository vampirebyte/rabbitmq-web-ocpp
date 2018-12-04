%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_web_mqtt_app).

-behaviour(application).
-export([start/2, prep_stop/1, stop/1]).

%% Dummy supervisor - see Ulf Wiger's comment at
%% http://erlang.2086793.n4.nabble.com/initializing-library-applications-without-processes-td2094473.html
-behaviour(supervisor).
-export([init/1]).

%%----------------------------------------------------------------------------

-spec start(_, _) -> {ok, pid()}.
start(_Type, _StartArgs) ->
    mqtt_init(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec prep_stop(term()) -> term().
prep_stop(State) ->
    ranch:stop_listener(web_mqtt),
    State.

-spec stop(_) -> ok.
stop(_State) ->
    ok.

init([]) -> {ok, {{one_for_one, 1, 5}, []}}.

%%----------------------------------------------------------------------------

mqtt_init() ->
    CowboyOpts0  = maps:from_list(get_env(cowboy_opts, [])),
    CowboyWsOpts = maps:from_list(get_env(cowboy_ws_opts, [])),

    Routes = cowboy_router:compile([{'_', [
        {get_env(ws_path, "/ws"), rabbit_web_mqtt_handler, [{ws_opts, CowboyWsOpts}]}
    ]}]),
    CowboyOpts = CowboyOpts0#{env          => #{dispatch => Routes},
                              middlewares  => [cowboy_router, rabbit_web_mqtt_middleware, cowboy_handler],
                              proxy_header => get_env(proxy_protocol, false)},
    {TCPConf, IpStr, Port} = get_tcp_conf(),

    case ranch:start_listener(web_mqtt, get_env(num_tcp_acceptors, 10),
        ranch_tcp, TCPConf,
        rabbit_web_mqtt_connection_sup, CowboyOpts) of
        {ok, _}                       -> ok;
        {error, {already_started, _}} -> ok;
        {error, Err}                  ->
            rabbit_log_connection:error(
                "Failed to start a WebSocket (HTTP) listener. Error: ~p,"
                " listener settings: ~p~n",
                [Err, TCPConf]),
            throw(Err)
    end,
    listener_started('http/web-mqtt', TCPConf),
    rabbit_log:info("rabbit_web_mqtt: listening for HTTP connections on ~s:~w~n",
                    [IpStr, Port]),

    case get_env(ssl_config, []) of
        [] ->
            ok;
        TLSConf0 ->
            rabbit_networking:ensure_ssl(),
            {TLSConf, TLSIpStr, TLSPort} = get_tls_conf(TLSConf0),
            {ok, _} = ranch:start_listener(web_mqtt_secure, get_env(num_ssl_acceptors, 10),
                ranch_ssl, TLSConf,
                rabbit_web_mqtt_connection_sup, CowboyOpts),
            listener_started('https/web-mqtt', TLSConf),
            rabbit_log:info("rabbit_web_mqtt: listening for HTTPS connections on ~s:~w~n",
                            [TLSIpStr, TLSPort])
    end,
    ok.

listener_started(Protocol, Listener) ->
    Port = rabbit_misc:pget(port, Listener),
    [rabbit_networking:tcp_listener_started(Protocol, Listener,
                                            IPAddress, Port)
     || {IPAddress, _Port, _Family}
        <- rabbit_networking:tcp_listener_addresses(Port)],
    ok.

get_tcp_conf() ->
    TCPConf0 = [{connection_type, supervisor}|get_env(tcp_config, [])],
    TCPConf1 = case proplists:get_value(port, TCPConf0) of
                   undefined -> [{port, 15675}|TCPConf0];
                   _ -> TCPConf0
               end,
    get_ip_port(TCPConf1).

get_tls_conf(TLSConf0) ->
    TLSConf1 = [{connection_type, supervisor}|TLSConf0],
    TLSConf2 = case proplists:get_value(port, TLSConf1) of
                   undefined -> [{port, 15674}|proplists:delete(port, TLSConf1)];
                   _ -> TLSConf1
               end,
    get_ip_port(TLSConf2).

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

get_env(Key, Default) ->
    rabbit_misc:get_env(rabbitmq_web_mqtt, Key, Default).
