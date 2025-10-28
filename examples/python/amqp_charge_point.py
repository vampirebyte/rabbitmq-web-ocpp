import asyncio
from datetime import datetime

from aio_pika import Message, Queue, Exchange
from ocpp.v16 import ChargePoint as cp


class AmqpChargePoint(cp):
    """
    An OCPP ChargePoint implementation that is tightly integrated with AMQP.
    
    This class directly consumes from an AMQP queue and publishes responses
    to an exchange, making it completely self-contained.
    """

    def __init__(self, queue: Queue, exchange: Exchange, **kwargs):
        """
        Args:
            queue (aio_pika.Queue): The AMQP queue to consume messages from
            exchange (aio_pika.Exchange): The AMQP exchange to publish responses to
        """
        # Pass None as the id since we'll extract it dynamically from routing keys
        super().__init__(None, self, **kwargs)
        self.queue = queue
        self.exchange = exchange

    async def _send(self, message: str):
        """
        Overrides the base `_send` method to publish the message to the
        AMQP exchange using the current charge point ID from the routing key.
        """

        self.logger.info("%s: send %s", self.id, message)
        msg = Message(
            body=message.encode(),
            content_type='application/json',
            timestamp=int(datetime.now().timestamp()),
        )
        await self.exchange.publish(msg, routing_key=self.id)

    async def start(self):
        """
        Start consuming from the AMQP queue and process messages directly.
        Completely overrides the base class implementation.
        """
        async with self.queue.iterator() as queue_iter:
            async for message in queue_iter:
                # Acknowledge the message automatically after processing
                async with message.process(requeue=False):
                    try:
                        # Extract routing key and charge point ID
                        routing_key = getattr(message, 'reply_to', '') or ''
                        if not routing_key:
                            self.logger.warning("Received message without reply_to set")
                            continue
                        self.id = routing_key
                        
                        # Decode message body
                        body = message.body.decode()
                        
                        # Process the message directly
                        self.logger.info("%s: receive message %s", routing_key, body)
                        await self.route_message(body)
                        
                    except Exception as e:
                        self.logger.exception("Error processing message: %s", e)
