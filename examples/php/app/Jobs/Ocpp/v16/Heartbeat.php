<?php

namespace App\Jobs\Ocpp\v16;

use Illuminate\Support\Facades\Log;
use SolutionForest\OcppPhp\Ocpp\v16\CallResults\Heartbeat as HeartbeatResponse;

class Heartbeat
{
    /**
     * Handle Heartbeat request.
     *
     * @param string $messageId
     * @param array $data
     * @return array OCPP CALLRESULT: [3, messageId, payload]
     */
    public function handle(string $messageId, array $data): array
    {
        Log::debug('Heartbeat received', ['messageId' => $messageId]);

        $response = new HeartbeatResponse($messageId);
        $response->currentTime = now()->toIso8601String();

        return $response->toArray();
    }
}
