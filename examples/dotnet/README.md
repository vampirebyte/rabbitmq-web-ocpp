# OCPP AMQP Server (.NET)

This directory contains a .NET 6 example for handling OCPP (Open Charge Point Protocol) messages over RabbitMQ using the native OCPP-to-AMQP plugin. It leverages the OCPP models generated from the Digital Twin Consortium (barnstee) schemas: https://github.com/digitaltwinconsortium/iot-edge-ocpp-central-system.

## Files

- `Program.cs` — console entrypoint that connects to RabbitMQ, consumes `ocpp.worker` queue messages, and forwards them to the controller.
- `Controllers/CSMSMiddlewareOCPP16.cs` — controller that processes OCPP requests (via reflection) and publishes responses back to `amq.topic`, setting `routingKey` from `reply_to` header and `CorrelationId` to the OCPP `UniqueId`.
- `Models/` — helper payload wrappers (request/response) reused for AMQP framing.
- `schemas/` — generated OCPP 1.6 service contracts used by the controller.
- `AmqpOcppServer.csproj` — project file with required dependencies (RabbitMQ.Client, Newtonsoft.Json).

## Why AMQP instead of WebSockets?

- Uses RabbitMQ for resilient, persistent messaging.
- Survives connection drops and supports backpressure.
- Scales across workers; supports flexible routing (topic-based).
- Handles multiple charge points efficiently.

## Prerequisites

- .NET 6 SDK or later
- RabbitMQ running locally (defaults used): `localhost:5672`, vhost `/`, user `guest/guest`
- Queue bound: `ocpp.worker` bound to exchange `amq.topic` with routing key `ocpp16.#`

## Run

```bash
cd examples/dotnet
dotnet run
```

On start, the app listens on `ocpp.worker` and publishes responses to `amq.topic` with routing key `<chargePointId>` taken from the message `reply_to`. Each response carries `CorrelationId = UniqueId` of the OCPP message.
