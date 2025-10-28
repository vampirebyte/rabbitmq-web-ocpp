import asyncio
import logging
from datetime import datetime, timezone

import aio_pika
from aio_pika import Message, ExchangeType

from ocpp.routing import on
from ocpp.v16 import call_result
from ocpp.v16.enums import Action, RegistrationStatus

from amqp_charge_point import AmqpChargePoint

EXCHANGE_NAME = 'amq.topic'
QUEUE_NAME = 'ocpp.worker'

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class MyChargePoint(AmqpChargePoint):
    """
    Extends the AmqpChargePoint to add application-specific message handlers.
    """
    @on(Action.boot_notification)
    async def on_boot_notification(
        self, charge_point_vendor, charge_point_model, **kwargs
    ):
        logger.info(
            "#### Boot notification from vendor %s, model %s",
            charge_point_vendor,
            charge_point_model,
        )
        return call_result.BootNotification(
            current_time=datetime.now(tz=timezone.utc).isoformat(),
            interval=10,
            status=RegistrationStatus.accepted,
        )

    @on(Action.status_notification)
    async def on_status_notification(
        self,
        status,
        connector_id,
        error_code,
        **kwargs,
    ):
        logger.info(
            "#### Status notification from connector %s: status=%s, error=%s",
            connector_id,
            status,
            error_code,
        )
        return call_result.StatusNotification()

    @on(Action.heartbeat)
    async def on_heartbeat(self, **kwargs):
        return call_result.Heartbeat(
            current_time=datetime.now(tz=timezone.utc).isoformat()
        )

async def main():
    """Main async entry: connect to RabbitMQ and start the OCPP charge point."""
    connection = None

    try:
        connection = await aio_pika.connect_robust(
            host='localhost',
            port=5672,
            virtualhost='/',
            login='guest',
            password='guest',
        )

        channel = await connection.channel()
        exchange = await channel.declare_exchange(EXCHANGE_NAME, ExchangeType.TOPIC, durable=True)
        queue = await channel.declare_queue(QUEUE_NAME, durable=True)

        # Add bindings to route messages to our queue
        # Bind to receive messages for all message types (wildcard pattern)
        await queue.bind(exchange, routing_key='ocpp16.#')

        # Create and start the charge point
        charge_point = MyChargePoint(queue, exchange)

        logger.info('Listening on queue "%s" and publishing to exchange "%s"', QUEUE_NAME, EXCHANGE_NAME)
        
        # Start the charge point (this will run forever)
        await charge_point.start()

    except asyncio.CancelledError:
        logger.info('Shutting down...')
    except Exception:
        logger.exception('Fatal error in main')
    finally:
        if connection:
            await connection.close()


if __name__ == '__main__':
    print('Demo OCPP Central System (AMQP-backed, Stateless Worker)')
    print('Publishing responses to exchange: amq.topic with routing_key = <chargePointId>')
    print()

    asyncio.run(main())