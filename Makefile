PROJECT = rabbitmq_web_ocpp
PROJECT_DESCRIPTION = RabbitMQ OCPP-J-to-AMQP adapter
PROJECT_MOD = rabbit_web_ocpp_app

define PROJECT_ENV
[
	    {tcp_config, [{port, 19520}]},
	    {ssl_config, []},
	    {num_tcp_acceptors, 10},
	    {num_ssl_acceptors, 10},
	    {cowboy_opts, []},
	    {proxy_protocol, false}
	  ]
endef

LOCAL_DEPS = ssl
DEPS = rabbit cowboy
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers rabbitmq_management rabbitmq_stomp rabbitmq_consistent_hash_exchange

PLT_APPS += rabbitmq_cli elixir cowlib

# FIXME: Add Ranch as a BUILD_DEPS to be sure the correct version is picked.
# See rabbitmq-components.mk.
BUILD_DEPS += ranch

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

# The monorepo structure of RabbitMQ does not work for OOT plugins.
DEPS_DIR ?= $(abspath ../rabbitmq-server/deps)
ERLANG_MK_TMP ?= $(abspath ./.erlang.mk)

include ../rabbitmq-server/rabbitmq-components.mk
include ../rabbitmq-server/erlang.mk
