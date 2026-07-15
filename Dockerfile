# syntax=docker/dockerfile:1.7

ARG RABBITMQ_VERSION=4.3.1
ARG ERLANG_VERSION=27
ARG ELIXIR_VERSION=1.19

#
# Build environment
#
FROM --platform=$BUILDPLATFORM \
    elixir:${ELIXIR_VERSION}-otp-${ERLANG_VERSION} \
    AS builder

ARG RABBITMQ_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        make \
        build-essential \
        p7zip-full \
        zip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone \
      --branch "v${RABBITMQ_VERSION}" \
      --depth 1 \
      https://github.com/rabbitmq/rabbitmq-server.git

WORKDIR /build/rabbitmq-server/deps/rabbitmq_web_ocpp

# "plugin" is a named BuildKit build context.
# Locally it can be ".", while CI can point it to a Git commit.
COPY --from=plugin . .

#
# Run tests and create the .ez.
#
# RUN make tests RABBITMQ_VERSION="${RABBITMQ_VERSION}"

RUN make dist \
      RABBITMQ_VERSION="${RABBITMQ_VERSION}" \
      MIX_ENV=prod \
      DIST_AS_EZS=yes \
    && mkdir -p /out \
    && cp plugins/rabbitmq_web_ocpp-*.ez /out/

#
# Production RabbitMQ image.
#
FROM rabbitmq:${RABBITMQ_VERSION}-management AS runtime

LABEL org.opencontainers.image.source="https://github.com/vampirebyte/rabbitmq-web-ocpp"
LABEL org.opencontainers.image.description="RabbitMQ with rabbitmq_web_ocpp"

COPY --from=builder \
    --chown=rabbitmq:rabbitmq \
    --chmod=0644 \
    /out/rabbitmq_web_ocpp-*.ez \
    /opt/rabbitmq/plugins/

# dry-run to test the plugin can be enabled without errors
RUN rabbitmq-plugins enable --offline rabbitmq_web_ocpp
