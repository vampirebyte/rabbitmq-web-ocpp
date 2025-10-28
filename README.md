# RabbitMQ Web OCPP plugin

A RabbitMQ plugin that turns the broker into a [highly-scalable](https://www.rabbitmq.com/blog/2023/03/21/native-mqtt#1-million-mqtt-connections), memory-efficient and low-latency gateway for EV charge stations. This plugin provides a native thin translator layer for OCPP-over-WebSockets to RabbitMQ AMQP protocol. Both version `1.6J` and `2.x` should be supported as the base JSON format array was kept backwards compatible, even tho many of the action names and payloads are changed.

## Motivation

Doing research for our CSMS platform, we found [IoT and WebSockets in K8s: Operating and Scaling an EV Charging Station Network - Saadi Myftija](https://www.youtube.com/watch?v=CuiY1Vj-A5E) and [Building an OCPP-compliant electric vehicle charge point operator solution using AWS IoT Core](https://aws.amazon.com/blogs/iot/building-an-ocpp-compliant-electric-vehicle-charge-point-operator-solution-using-aws-iot-core/), both ilustrating a rather complex and costly cloud architecture for this use-case. CPOs frequently need to fan-in **tens of thousands of charge points (CPs)** over the public (LTE) Internet while keeping stateful request/response semantics (RPC), durable command queues and enterprise-grade HA. 
RabbitMQ already excels at message durability and routing, but traditionally the OCPP world still relies on proprietary gateways or heavyweight HTTP stacks.

`rabbitmq_web_ocpp` closes that gap:

* **Zero external proxy** – The native Erlang HTTP server included in RabbitMQ, Cowboy, terminates `wss://` connections on the broker node, allowing even mTLS peer verification.
* **Native AMQP routing** – every OCPP frame is stored as a RabbitMQ *message container*; you fan-out, DLX, or mirror it; OCPP backend can be written in any programming language as queue workers.
* **One Erlang process per charger** – the same footprint as the native MQTT rewrite.
* **Reconnection storms resilience** - handled by RabbitMQ HA cluster, backend scalling is decopled.

## Why “one Erlang process per charger” actually scales

* **Low memory usage per process** – a BEAM process starts with a 256-word heap; even
  with the pending-map and a few binaries a live Web-OCPP handler + channel
  stays < few KiB.
* **No kernel threads** – the BEAM scheduler multiplexes hundreds of
  thousands of lightweight processes onto a fixed pool of OS threads.
  Context switches are micro-seconds and never hit the kernel.
* **Per-process garbage collection** – pauses are micro-scopic and local;
  one slow charger cannot block the others.
* **Built-in crash isolation & supervision** – the classic *let it crash*
  idiom restarts a misbehaving charger process without touching neighbours,
  something a monolithic Java or Go gateway must re-implement.
* **Direct in-VM routing** – by skipping TCP and AMQP frames the path from
  WebSocket frame → queue deliver → WebSocket send is one message copy
  inside the VM—not four kernel crossings like a side-car proxy.


## Installation

This plugin works only with modern versions of RabbitMQ 4.x based on AMQP 1.0.
You can [build from source](https://www.rabbitmq.com/plugin-development.html) or you can download the latest release build from GitHub. Then, unzip and place the `rabbitmq_web_ocpp-4.x.x.ez` file into your `/etc/rabbitmq/plugins/` folder.
Like all plugins, it [must be enabled](https://www.rabbitmq.com/plugins.html) before it can be used:

``` bash
# this might require sudo
rabbitmq-plugins enable rabbitmq_web_ocpp
```

Detailed instructions on how to install a plugin into RabbitMQ broker can be found [here](https://www.rabbitmq.com/plugins.html#installing-plugins).

Note that release branches (`v4.1.x` vs. `main`) and target RabbitMQ version need to be taken into account
when building plugins from source.

## Documentation

For all configuration options, please refer to the nearly identical plugin, [RabbitMQ Web MQTT guide](https://www.rabbitmq.com/web-mqtt.html).

## Enterprise-Grade Hosting & SLA Support

For CPOs or platform operators that need to onboard fleets of tens of thousands of chargers, our team offers cloud-native RabbitMQ HA deployments in AWS, Azure or GCP, complete with 24/7 monitoring, incident response, rolling upgrades, and expert assistance for PKI, Prometheus dashboards and OCPP-specific queue policies; we can also deliver custom feature work; we tailor service levels and cluster topologies so you can scale from pilot projects to nationwide networks without re-architecting.

## Copyright and License

(c) 2007-2024 Broadcom. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.  
(c) 2025 VAMPIRE BYTE SRL. All Rights Reserved.

Released under the same license as RabbitMQ. See [LICENSE](./LICENSE) for details.
