<?php

namespace App\Jobs;

use Illuminate\Support\Facades\Log;
use SolutionForest\OcppPhp\Ocpp\Exceptions\NotImplementedError;
use SolutionForest\OcppPhp\Ocpp\JsonSchemaValidator;
use SolutionForest\OcppPhp\Ocpp\Messages\CallError;
use VladimirYuldashev\LaravelQueueRabbitMQ\Queue\Jobs\RabbitMQJob;

class OcppMessageProxy extends RabbitMQJob
{
    protected $actionName = '';

    /**
     * Fire the job - dispatches to specific OCPP action jobs.
     *
     * @return void
     */
    public function fire()
    {
        $payload = $this->payload();

        dump('OcppMessageJob received:', $payload);

        // OCPP CALL format: [messageTypeId, messageId, action, payload]
        if (! is_array($payload) || count($payload) < 3) {
            Log::error('Invalid OCPP message format', ['payload' => $payload]);
            $this->delete();
            return false;
        }

        [$messageType, $messageId, $action] = $payload;
        $data = $payload[3] ?? [];

        // Only handle CALL messages (2); ignore CALLRESULT/CALLERROR
        if ($messageType !== 2) {
            Log::debug('Ignoring non-CALL message', ['messageType' => $messageType]);
            $this->delete();
            return false;
        }

        // Resolve Call Class from Library
        $callClass = "SolutionForest\\OcppPhp\\Ocpp\\v16\\Calls\\{$action}";

        if (!class_exists($callClass)) {
            Log::warning("Unknown OCPP Action (Library class not found): {$action}");
            $error = new NotImplementedError($messageId);
            $response = $error->toArray();
            dump('OcppMessageJob response (NotImplemented - Unknown Action):', $response);
            Log::info('OCPP Response ready to send', ['response' => $response]);
            $this->delete();
            return false;
        }

        // Instantiate and hydrate Call object for validation
        /** @var \SolutionForest\OcppPhp\Ocpp\Messages\Call $callObject */
        $callObject = new $callClass();
        $callObject->messageId = $messageId;
        foreach ($data as $key => $value) {
            $callObject->$key = $value;
        }

        // Validate incoming OCPP message using built-in JSON schema validator
        $validationResult = JsonSchemaValidator::validate($callObject, 'v1.6', false);

        // If validation fails, validator already built a proper CallError
        if ($validationResult instanceof CallError) {
            Log::warning("OCPP message validation failed for action: {$action}", [
                'messageId' => $messageId,
                'errorCode' => $validationResult->errorCode,
                'errorDescription' => $validationResult->errorDescription,
            ]);
            $response = $validationResult->toArray();
        }

        // Build job class name: App\Jobs\Ocpp\v16\{Action}
        $jobClass = "App\\Jobs\\Ocpp\\v16\\{$action}";

        if (!class_exists($jobClass)) {
            Log::warning("No job found for action: {$action}, sending NotImplemented");
            $error = new NotImplementedError($messageId);
            $response = $error->toArray();
        }

        // Instantiate and execute the specific OCPP job
        $job = app($jobClass);
        $response = $job->handle($messageId, $data);

        if ($response) {
            dump('OcppMessageJob response:', $response);
            Log::info('OCPP Response ready to send', ['response' => $response]);

            $this->respond($response);
        }

        $this->delete();
        return true;
    }

    public function getName()
    {
        return $this->actionName;
    }

    public function respond($response)
    {
        $broker = $this->getRabbitMQ();
        $message = $this->getRabbitMQMessage();

        if ($message->has('reply_to')) {
            $broker->getChannel()->basic_publish(
                new \PhpAmqpLib\Message\AMQPMessage(
                    json_encode($response),
                    ['correlation_id' => $message->get('correlation_id') ?? '']
                ),
                'amq.topic',
                $message->get('reply_to')
            );
        }
    }
}
