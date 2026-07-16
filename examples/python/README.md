# OCPP AMQP Server

This directory contains Python examples for handling OCPP (Open Charge Point Protocol) messages using RabbitMQ native OCPP to AMQP plugin. It uses the popular python OCPP lib, [mobilityhouse/ocpp](https://github.com/mobilityhouse/ocpp).

## Quick Start (Docker Compose)

Run the whole CSMS — RabbitMQ with the plugin baked in, plus the Python worker — with one command:

``` bash
docker compose up --build
```

Then connect your EVSE (or a simulator) to `ws://localhost:19520/ocpp/demo/` (the stack uses a `demo` vhost) and watch the worker log the OCPP traffic. The management UI is available at [http://localhost:15672](http://localhost:15672) (`guest`/`guest`).

Since workers are stateless queue consumers, you can scale them freely:

``` bash
docker compose up --build --scale csms=3
```

## Running the worker locally

Alternatively, start only the broker in Docker and run the worker on your machine:

``` bash
docker compose up rabbitmq -d
pip install -r requirements.txt
RABBITMQ_VHOST=demo python server.py
```

Connection settings can be overridden via the `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_VHOST`, `RABBITMQ_USER` and `RABBITMQ_PASS` environment variables.

## Files

- `server.py` - CSMS / OCPP server
- `amqp_charge_point.py` - Overrides the original ChargePoint class
- `requirements.txt` - Python dependencies
- `docker-compose.yml` - One-command stack: broker + worker
- `Dockerfile` - Container image for the worker

## Key Differences from traditional WebSocket Approach

- Uses RabbitMQ message broker for communication
- Messages are persistent and can survive connection drops
- Better scalability and load distribution
- Supports complex routing patterns
- Can handle multiple charge points efficiently
