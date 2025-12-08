<?php

namespace App\Jobs\Ocpp\v16;

use Illuminate\Support\Facades\Log;
use SolutionForest\OcppPhp\Ocpp\v16\CallResults\BootNotification as BootNotificationResponse;

class BootNotification
{
    /**
     * Handle BootNotification request.
     *
     * @param string $messageId
     * @param array $data
     * @return array OCPP CALLRESULT: [3, messageId, payload]
     */
    public function handle(string $messageId, array $data): array
    {
        Log::info('BootNotification received', [
            'messageId' => $messageId,
            'vendor' => $data['chargePointVendor'] ?? 'unknown',
            'model' => $data['chargePointModel'] ?? 'unknown',
            'serialNumber' => $data['chargePointSerialNumber'] ?? null,
        ]);

        $response = new BootNotificationResponse($messageId);
        $response->status = 'Accepted'; // Options: Accepted, Pending, Rejected
        $response->currentTime = now()->toIso8601String();
        $response->interval = 60; // Heartbeat interval in seconds

        return $response->toArray();
    }
}
