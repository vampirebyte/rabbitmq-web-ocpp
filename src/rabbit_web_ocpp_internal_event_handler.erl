%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2026 VAMPIRE BYTE SRL. All Rights Reserved.
%%

-module(rabbit_web_ocpp_internal_event_handler).

-include_lib("kernel/include/logger.hrl").
-include("rabbit_web_ocpp.hrl").

-behaviour(gen_event).

-export([init/1, handle_event/2, handle_call/2, handle_info/2]).
-export([close_local_connections_and_wait/0]).

-define(STATE, []).
%% Charge points are disconnected one at a time at this interval, 100 per second,
%% so that the remaining nodes are not overwhelmed by their reconnects.
-define(CLOSE_INTERVAL_MS, 10).

init([]) ->
    {ok, ?STATE}.

%% Schedules the connections to close at evenly spaced intervals and returns
%% their number. Only established connections are members of the client ID
%% process groups.
-spec close_local_connections() -> non_neg_integer().
close_local_connections() ->
    Pids = [Pid || Group <- pg:which_groups(?PG_SCOPE),
                   Pid <- pg:get_local_members(?PG_SCOPE, Group)],
    [erlang:send_after(I * ?CLOSE_INTERVAL_MS, Pid,
                       {'$gen_cast', {close_connection, maintenance}})
     || {I, Pid} <- lists:enumerate(0, Pids)],
    length(Pids).

%% Used when the plugin or the node stops, also right after a drain: the
%% connections left keep their order, so they are scheduled again at about
%% the same points in time.
-spec close_local_connections_and_wait() -> ok.
close_local_connections_and_wait() ->
    timer:sleep(close_local_connections() * ?CLOSE_INTERVAL_MS).

handle_event({event, maintenance_connections_closed, _Info, _, _}, ?STATE) ->
    ?LOG_WARNING("Delayed closing ~b local Web OCPP client connections",
                 [close_local_connections()]),
    {ok, ?STATE};
handle_event(_Event, ?STATE) ->
    {ok, ?STATE}.

handle_call(_Request, ?STATE) ->
    {ok, ok, ?STATE}.

handle_info(_Info, State) ->
    {ok, State}.
