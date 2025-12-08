# OCPP AMQP Server (PHP/Laravel)

This directory contains a PHP/Laravel example for handling OCPP (Open Charge Point Protocol) messages using the RabbitMQ native OCPP to AMQP plugin. It leverages Laravel's queue system and the [solution-forest/ocpp-php](https://github.com/solution-forest/ocpp-php) library.

## Files

- `app/Jobs/OcppMessageProxy.php` - The main entry point (Job) that consumes raw OCPP messages from RabbitMQ and dispatches them to specific action handlers.
- `app/Jobs/Ocpp/v16/` - Directory containing individual Job classes for each OCPP 1.6 action (e.g., `BootNotification`, `Heartbeat`).
- `config/queue.php` - Configuration for the RabbitMQ connection and queue settings.
- `composer.json` - PHP dependencies.

## Dependencies

- [Laravel](https://laravel.com) - The web application framework.
- [laravel-queue-rabbitmq](https://github.com/vyuldashev/laravel-queue-rabbitmq) - RabbitMQ driver for Laravel queues.
- [ocpp-php](https://github.com/solution-forest/ocpp-php) - Library for parsing and validating OCPP messages.

## Key Features

- **Laravel Queue Integration**: Uses the standard `php artisan queue:work` or `rabbitmq:consume` commands to process OCPP messages.
- **Proxy Job Pattern**: `OcppMessageProxy` acts as a router, intercepting raw OCPP JSON arrays from the queue and dispatching them to dedicated classes.
- **Schema Validation**: Incoming messages are validated against OCPP 1.6 JSON schemas using the `ocpp-php` library.
- **Separation of Concerns**: Each OCPP action (like `BootNotification`, `Heartbeat`) is handled by its own Job class.

## Running the Worker

To start consuming messages from the queue:

```bash
# Standard Laravel worker (polling)
php artisan queue:work rabbitmq --queue=ocpp.worker --sleep=0.01

# Or using the RabbitMQ consumer (push-based, recommended for lower latency)
php artisan rabbitmq:consume rabbitmq --queue=ocpp.worker
```
