# RabbitMQ Web OCPP plugin

This plugin provides is a thin translator layer for OCPP-over-WebSockets to RabbitMQ AMQP protocol. Both version `1.6J` and `2.x` should be supported as the base JSON format array was kept backwards compatible, even tho many of the action names and payload are changed.

## Installation

This plugin works only with modern versions of RabbitMQ 4.x based on AMQP 1.0.
Like all plugins, it [must be enabled](https://www.rabbitmq.com/plugins.html) before it can be used:

``` bash
# this might require sudo
rabbitmq-plugins enable rabbitmq_web_ocpp
```

## Documentation

For all configuration options, please refer to the nearly identical plugin, [RabbitMQ Web MQTT guide](https://www.rabbitmq.com/web-mqtt.html).


## Building From Source

 * [Generic plugin build instructions](https://www.rabbitmq.com/plugin-development.html)
 * Instructions on [how to install a plugin into RabbitMQ broker](https://www.rabbitmq.com/plugins.html#installing-plugins)

Note that release branches (`stable` vs. `master`) and target RabbitMQ version need to be taken into account
when building plugins from source.


## Copyright and License

(c) 2007-2024 Broadcom. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.

Released under the same license as RabbitMQ. See LICENSE for details.
