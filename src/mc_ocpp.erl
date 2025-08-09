%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2025 VAMPIRE BYTE SRL. All Rights Reserved.
%%
-module(mc_ocpp).
-behaviour(mc).

-export([
    init/1,
    size/1,
    x_header/2,
    property/2,
    routing_headers/2,
    convert_from/3,
    convert_to/3,
    protocol_state/2,
    prepare/2
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").  % #content{}
-include_lib("amqp10_common/include/amqp10_framing.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").          % #'P_basic'{}
-include_lib("rabbit/include/mc.hrl").
-include("rabbit_web_ocpp.hrl").

-define(CONTENT_TYPE_JSON, <<"application/json">>).

%%--------------------------------------------------------------------
-spec init(#ocpp_msg{}) -> {#ocpp_msg{}, map()} | error.
init(Msg = #ocpp_msg{}) ->
    Anns = #{
        ?ANN_ROUTING_KEYS => [Msg#ocpp_msg.client_id],
        ?ANN_DURABLE   => false,
        correlation_id => Msg#ocpp_msg.msg_id,
        reply_to       => Msg#ocpp_msg.client_id,
        content_type   => ?CONTENT_TYPE_JSON
    },
    {Msg, Anns};
init(Other) ->
    ?LOG_ERROR("mc_ocpp:init badarg: ~p", [Other]),
    error(badarg).

%%--------------------------------------------------------------------
-spec size(#ocpp_msg{}) -> {non_neg_integer(), non_neg_integer()}.
size(#ocpp_msg{payload = P}) when is_binary(P) ->
    {0, byte_size(P)};
size(#ocpp_msg{payload = Iol}) ->
    {0, iolist_size(Iol)}.

%%--------------------------------------------------------------------
x_header(_Key, #ocpp_msg{}) ->
    undefined.

%%--------------------------------------------------------------------
property(correlation_id, #ocpp_msg{msg_id = ID}) when is_binary(ID) ->
    {binary, ID};
property(reply_to,       #ocpp_msg{client_id = C})  when is_binary(C) ->
    {binary, C};
property(_, _) ->
    undefined.

%%--------------------------------------------------------------------
routing_headers(#ocpp_msg{action = A}, _) when is_binary(A) ->
    #{<<"ocpp_action">> => A};
routing_headers(_, _) ->
    #{}.

%%--------------------------------------------------------------------
-spec convert_from(atom(), term(), map()) -> #ocpp_msg{} | not_implemented.

%% AMQP 1.0
convert_from(mc_amqp, Sections, _Env) ->
    {Payload, Corr, Act, Rto} = extract_amqp1(Sections),
    build_ocpp(Payload, Corr, Act, Rto);

%% AMQP 0-9-1
convert_from(mc_amqpl, #content{payload_fragments_rev = Rev, properties = BP}, _Env) ->
    Payload = iolist_to_binary(lists:reverse(Rev)),
    Corr    = case BP#'P_basic'.correlation_id of undefined -> undefined; CorrVal -> CorrVal end,
    Act     = case BP#'P_basic'.type of
                 undefined -> undefined;
                 ActVal -> ActVal
              end,
    Rto     = case BP#'P_basic'.reply_to         of undefined -> undefined; RtoVal -> RtoVal end,
    build_ocpp(Payload, Corr, Act, Rto);

%% Identity / No conversion
convert_from(?MODULE, Msg, _) ->
    Msg;
convert_from(_, _, _) ->
    not_implemented.

%%--------------------------------------------------------------------
-spec convert_to(atom(), #ocpp_msg{}, map()) -> term() | not_implemented.

%% AMQP 1.0
convert_to(mc_amqp, #ocpp_msg{payload=P, msg_id=ID, action=A, client_id=CID} = _Msg, Env) ->
    Header   = #'v1_0.header'{durable = false},
    Props    = #'v1_0.properties'{
                  correlation_id = ID,
                  subject        = A,
                  content_type   = {symbol, ?CONTENT_TYPE_JSON},
                  reply_to       = CID
               },
    Data     = #'v1_0.data'{content = P},
    Sections = [Header, Props, Data],
    %% Use convert_from/3 here to turn a section list into
    %% a canonical AMQP message that the server knows how to frame.
    mc_amqp:convert_from(mc_amqp, Sections, Env);

%% AMQP 0-9-1
convert_to(mc_amqpl,
           #ocpp_msg{payload = Payload,
                     msg_id   = MsgId,
                     action   = Action,
                     client_id= ClientId},
           _Env) ->
    %% 1) Build the basic properties record
    BP = #'P_basic'{
      delivery_mode   = 1,                % non-persistent
      correlation_id  = MsgId,            % your OCPP msg_id
      type            = Action,           % maps to 'type' header
      content_type    = ?CONTENT_TYPE_JSON,
      reply_to        = ClientId,         % OCPP client_id
      headers         = undefined         % no extra field-table entries
    },

    %% 2) Wrap the JSON payload as a single binary
    PFR = [ iolist_to_binary(Payload) ],

    %% 3) Use the Basic class ID (60) for content frames
    #content{
      class_id              = 60,
      properties            = BP,
      properties_bin        = none,
      payload_fragments_rev = PFR
    };

%% Identity / No conversion
convert_to(?MODULE, Msg, _) ->
    Msg;
convert_to(_, _, _) ->
    not_implemented.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% @doc No‐op before sending—ensure payload is a binary
-spec prepare(Atom :: atom(), Msg :: #ocpp_msg{}) -> #ocpp_msg{}.
prepare(_For, Msg = #ocpp_msg{payload = P}) when is_binary(P) ->
    Msg;
prepare(_For, Msg = #ocpp_msg{payload = Iolist}) ->
    %% convert any stray iolists to a flat binary
    Msg#ocpp_msg{payload = iolist_to_binary(Iolist)}.

%% @doc No protocol‐specific state changes needed
-spec protocol_state(Msg :: #ocpp_msg{}, Anns :: map()) -> #ocpp_msg{}.
protocol_state(Msg, _Anns) ->
    Msg.

-spec extract_amqp1([term()]) -> {binary(), binary()|undefined, binary()|undefined, binary()|undefined}.
extract_amqp1(Sections) ->
    {Rev, Corr, Act, Rto} =
      lists:foldl(fun
        (#'v1_0.data'{content=C},    {R,C0,A0,R0}) -> {[C|R], C0, A0, R0};
        (#'v1_0.properties'{correlation_id={binary,ID}}, {R,_,A0,R0}) -> {R, ID, A0, R0};
        (#'v1_0.properties'{subject={utf8,S}},         {R,C0,_,R0})  -> {R, C0, S, R0};
        (#'v1_0.properties'{reply_to={binary,RT}},     {R,C0,A0,_})  -> {R, C0, A0, RT};
        (_, Acc) -> Acc
      end, {[], undefined, undefined, undefined}, Sections),
    { iolist_to_binary(lists:reverse(Rev))
    , Corr, Act, Rto
    }.

-spec build_ocpp(binary(), binary()|undefined, binary()|undefined, binary()|undefined) -> #ocpp_msg{}.
build_ocpp(Payload, Corr, Act, Rto) ->
    #ocpp_msg{
      payload     = Payload,
      msg_type    = undefined,
      msg_id      = Corr,
      action      = Act,
      client_id   = Rto
    }.
