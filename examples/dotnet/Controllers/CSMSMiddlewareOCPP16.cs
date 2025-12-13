/*
Copyright 2021 Microsoft Corporation
*/

using System.Text;
using System.Reflection;
using Newtonsoft.Json;
using Newtonsoft.Json.Converters;
using Newtonsoft.Json.Linq;
using RabbitMQ.Client;
using OCPPCentralSystem.Models;
using OCPPCentralSystem.Schemas.OCPP16;
using System;

namespace OCPPCentralSystem.Controllers
{
    public class CSMSMiddlewareOCPP16 : I_OCPP_CentralSystemService_16
    {
        private int _transactionNumber = 0;
        private readonly IModel _channel;
        private readonly string _exchangeName;
        private readonly JsonSerializer _serializer;

        public CSMSMiddlewareOCPP16(IModel channel, string exchangeName)
        {
            _channel = channel;
            _exchangeName = exchangeName;

            var settings = new JsonSerializerSettings();
            settings.Converters.Add(new StringEnumConverter());
            settings.DateFormatHandling = DateFormatHandling.IsoDateFormat;
            _serializer = JsonSerializer.Create(settings);
        }

        public void ProcessRequest(RequestPayload request, string routingKey)
        {
            try 
            {
                object responsePayload = null;

                // Use reflection to find the method on the service interface
                var method = typeof(I_OCPP_CentralSystemService_16).GetMethod(request.Action);

                if (method != null)
                {
                    var parameters = method.GetParameters();
                    if (parameters.Length == 1)
                    {
                        var paramType = parameters[0].ParameterType;
                        var requestObj = request.Payload.ToObject(paramType, _serializer);

                        // Inject chargeBoxIdentity if the property exists
                        var chargeBoxIdentityField = paramType.GetField("chargeBoxIdentity");
                        if (chargeBoxIdentityField != null)
                        {
                            chargeBoxIdentityField.SetValue(requestObj, routingKey);
                        }

                        responsePayload = method.Invoke(this, new object[] { requestObj });
                    }
                    else
                    {
                        Console.WriteLine($"Method ${request.Action} has unexpected number of parameters.");
                    }
                }
                else
                {
                    Console.WriteLine($"Unknown action: ${request.Action}");
                }

                if (responsePayload != null)
                {
                    var response = new ResponsePayload(request.UniqueId, responsePayload);
                    response.Payload = JObject.FromObject(responsePayload, _serializer);
                    response.WrappedPayload = new JArray { response.MessageTypeId, response.UniqueId, response.Payload };

                    SendResponse(response, routingKey);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Error processing message: ${ex}");
            }
        }

        private void SendResponse(ResponsePayload response, string id)
        {
            var message = response.WrappedPayload.ToString(Formatting.None);
            Console.WriteLine($"${id}: send ${message}");
            var body = Encoding.UTF8.GetBytes(message);
            
            var properties = _channel.CreateBasicProperties();
            properties.ContentType = "application/json";
            properties.Timestamp = new AmqpTimestamp(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            properties.CorrelationId = response.UniqueId;

            _channel.BasicPublish(exchange: _exchangeName,
                                 routingKey: id,
                                 basicProperties: properties,
                                 body: body);
        }

        public AuthorizeResponse Authorize(AuthorizeRequest request)
        {
            Console.WriteLine("Authorization requested on chargepoint " + request.chargeBoxIdentity + "  and badge ID " + request.idTag);

            IdTagInfo info = new IdTagInfo
            {
                expiryDateSpecified = false,
                status = AuthorizationStatus.Accepted
            };

            return new AuthorizeResponse(info);
        }

        public BootNotificationResponse BootNotification(BootNotificationRequest request)
        {
            Console.WriteLine("Chargepoint with identity: " + request.chargeBoxIdentity + " booted!");
            return new BootNotificationResponse(RegistrationStatus.Accepted, DateTime.UtcNow, 60);
        }

        public HeartbeatResponse Heartbeat(HeartbeatRequest request)
        {
            Console.WriteLine("Heartbeat received from: " + request.chargeBoxIdentity);
            return new HeartbeatResponse(DateTime.UtcNow);
        }

        public MeterValuesResponse MeterValues(MeterValuesRequest request)
        {
            Console.WriteLine("Meter values for connector ID " + request.connectorId + " on chargepoint " + request.chargeBoxIdentity + ":");
            foreach (MeterValue meterValue in request.meterValue)
            {
                foreach (SampledValue sampledValue in meterValue.sampledValue)
                {
                    Console.WriteLine("Value: " + sampledValue.value + " " + sampledValue.unit.ToString());
                }
            }
            return new MeterValuesResponse();
        }

        public StartTransactionResponse StartTransaction(StartTransactionRequest request)
        {
            Console.WriteLine("Start transaction " + _transactionNumber.ToString() + " from " + request.timestamp + " on chargepoint " + request.chargeBoxIdentity + " on connector " + request.connectorId + " with badge ID " + request.idTag + " and meter reading at start " + request.meterStart);
            _transactionNumber++;
            
            IdTagInfo info = new IdTagInfo
            {
                expiryDateSpecified = false,
                status = AuthorizationStatus.Accepted
            };

            return new StartTransactionResponse(_transactionNumber, info);
        }

        public StopTransactionResponse StopTransaction(StopTransactionRequest request)
        {
            Console.WriteLine("Stop transaction " + request.transactionId.ToString() + " from " + request.timestamp + " on chargepoint " + request.chargeBoxIdentity + " with badge ID " + request.idTag + " and meter reading at stop " + request.meterStop);

            IdTagInfo info = new IdTagInfo
            {
                expiryDateSpecified = false,
                status = AuthorizationStatus.Accepted
            };

            return new StopTransactionResponse(info);
        }

        public StatusNotificationResponse StatusNotification(StatusNotificationRequest request)
        {
            Console.WriteLine("Chargepoint " + request.chargeBoxIdentity + " and connector " + request.connectorId + " status#: " + request.status.ToString());
            return new StatusNotificationResponse();
        }

        public DataTransferResponse DataTransfer(DataTransferRequest request)
        {
            return new DataTransferResponse(DataTransferStatus.Rejected, string.Empty);
        }

        public DiagnosticsStatusNotificationResponse DiagnosticsStatusNotification(DiagnosticsStatusNotificationRequest request)
        {
            return new DiagnosticsStatusNotificationResponse();
        }

        public FirmwareStatusNotificationResponse FirmwareStatusNotification(FirmwareStatusNotificationRequest request)
        {
            return new FirmwareStatusNotificationResponse();
        }
    }
}
