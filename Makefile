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

PLT_APPS += rabbitmqctl elixir cowlib

# FIXME: Add Ranch as a BUILD_DEPS to be sure the correct version is picked.
# See rabbitmq-components.mk.
BUILD_DEPS += ranch

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

include ../../rabbitmq-components.mk
include ../../erlang.mk
