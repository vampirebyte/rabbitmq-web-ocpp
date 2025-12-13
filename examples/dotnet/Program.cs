using System;
using System.Text;
using Newtonsoft.Json.Linq;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using OCPPCentralSystem.Controllers;
using OCPPCentralSystem.Models;

namespace AmqpOcppClient
{
    class Program
    {
        static void Main(string[] args)
        {
            Console.WriteLine("Demo OCPP Central System (AMQP-backed, Stateless Worker)");
            Console.WriteLine("Publishing responses to exchange: amq.topic with routing_key = <chargePointId>");
            Console.WriteLine();

            var factory = new ConnectionFactory() { HostName = "localhost", Port = 5672, UserName = "guest", Password = "guest" };
            using (var connection = factory.CreateConnection())
            using (var channel = connection.CreateModel())
            {
                string exchangeName = "amq.topic";
                string queueName = "ocpp.worker";

                channel.ExchangeDeclare(exchange: exchangeName, type: ExchangeType.Topic, durable: true);
                channel.QueueDeclare(queue: queueName, durable: true, exclusive: false, autoDelete: false, arguments: null);
                channel.QueueBind(queue: queueName, exchange: exchangeName, routingKey: "ocpp16.#");

                var controller = new CSMSMiddlewareOCPP16(channel, exchangeName);
                
                Console.WriteLine($"Listening on queue \"{queueName}\" and publishing to exchange \"{exchangeName}\"");
                
                var consumer = new EventingBasicConsumer(channel);
                consumer.Received += (model, ea) =>
                {
                    var body = ea.Body.ToArray();
                    var message = Encoding.UTF8.GetString(body);
                    var routingKey = ea.BasicProperties.ReplyTo;

                    if (string.IsNullOrEmpty(routingKey))
                    {
                        Console.WriteLine("Received message without reply_to set");
                        return;
                    }

                    Console.WriteLine($"${routingKey}: receive message ${message}");
                    var payload = new RequestPayload(JArray.Parse(message));
                    controller.ProcessRequest(payload, routingKey);
                };

                channel.BasicConsume(queue: queueName,
                                     autoAck: true,
                                     consumer: consumer);

                Console.WriteLine(" Press [enter] to exit.");
                Console.ReadLine();
            }
        }
    }
}
