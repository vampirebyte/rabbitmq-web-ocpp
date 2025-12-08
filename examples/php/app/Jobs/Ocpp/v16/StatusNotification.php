<?php

namespace App\Jobs\Ocpp\v16;

use Illuminate\Support\Facades\Log;
use SolutionForest\OcppPhp\Ocpp\v16\CallResults\StatusNotification as StatusNotificationResponse;

class StatusNotification
{
    /**
     * Handle StatusNotification request.
     *
     * @param string $messageId
     * @param array $data
     * @return array OCPP CALLRESULT: [3, messageId, payload]
     */
    public function handle(string $messageId, array $data): array
    {
        Log::info('StatusNotification received', [
            'messageId' => $messageId,
            'connectorId' => $data['connectorId'] ?? null,
            'status' => $data['status'] ?? 'unknown',
            'errorCode' => $data['errorCode'] ?? 'NoError',
            'timestamp' => $data['timestamp'] ?? null,
        ]);

        $response = new StatusNotificationResponse($messageId);
        // StatusNotification response has no additional fields

        return $response->toArray();
    }
}
