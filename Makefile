PROJECT = rabbitmq_web_mqtt
PROJECT_DESCRIPTION = RabbitMQ MQTT-over-WebSockets adapter
PROJECT_MOD = rabbit_web_mqtt_app

define PROJECT_ENV
[
	    {tcp_config, []},
	    {num_tcp_acceptors, 10},
	    {ssl_config, []},
	    {num_ssl_acceptors, 1},
	    {cowboy_opts, []}
	  ]
endef

DEPS = rabbit_common rabbit cowboy rabbitmq_mqtt
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers
dep_cowboy_commit = 1.0.3

# FIXME: Add Ranch as a BUILD_DEPS to be sure the correct version is picked.
# See rabbitmq-components.mk.
BUILD_DEPS += ranch

DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk
