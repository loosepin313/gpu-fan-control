#!/usr/bin/env bash
# loadgen.sh - generate real GPU load through an OpenAI-compatible endpoint
#
# Why not a synthetic burn? A compute-only burn (matrix multiply, hash loop)
# under-reports power badly on inference cards - it saturates the ALUs without
# touching HBM bandwidth, so it can sit 30-50% below the card's real workload
# power. On an MI50 a hand-written HIP burn topped out around 140-165 W while
# the actual inference workload ran 175-225 W. Calibrating a fan curve against
# the synthetic number gives you a curve that is too quiet for the real load.
#
# Driving the real inference endpoint is the only way to reproduce the actual
# power profile.
#
#   usage: ./loadgen.sh [duration_seconds] [concurrency]
#
#   env:
#     API_URL    chat-completions endpoint (default http://localhost:8080/v1/chat/completions)
#     MODEL      model name to request    (default: first model from /v1/models)
#     PROMPT     prompt text to send
#
# Concurrency matters: one stream will not load the card the way several do.
# Match the concurrency you actually run in production.

DUR=${1:-120}
N=${2:-3}
API_URL=${API_URL:-http://localhost:8080/v1/chat/completions}
MODEL=${MODEL:-}
PROMPT=${PROMPT:-Write a detailed, technical 900-word essay on thermal engineering and heat exchanger design.}

if [ -z "$MODEL" ]; then
    # try to discover the model name from the same server
    base="${API_URL%/chat/completions}/models"
    MODEL=$(curl -s -m 10 "$base" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$MODEL" ]; then
    echo "could not determine MODEL; set MODEL=... and retry" >&2
    exit 1
fi

echo "load: $N concurrent streams against $API_URL (model=$MODEL) for ${DUR}s"

end=$((SECONDS + DUR))
for ((i = 0; i < N; i++)); do
    (
        while [ $SECONDS -lt $end ]; do
            curl -s -m 180 "$API_URL" -H "Content-Type: application/json" \
                -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT section $i\"}],\"max_tokens\":1000}" \
                -o /dev/null
        done
    ) &
done
wait
