# OCPP AMQP Server

This directory contains Python examples for handling OCPP (Open Charge Point Protocol) messages using RabbitMQ native OCPP to AMQP plugin. It uses the popular python OCPP lib, [mobilityhouse/ocpp](https://github.com/mobilityhouse/ocpp).

## Files

- `server.py` - CSMS / OCPP server
- `amqp_charge_point.py` - Overrides the original ChargePoint class
- `requirements.txt` - Python dependencies

## Key Differences from traditional WebSocket Approach

- Uses RabbitMQ message broker for communication
- Messages are persistent and can survive connection drops
- Better scalability and load distribution
- Supports complex routing patterns
- Can handle multiple charge points efficiently
