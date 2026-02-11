#!/usr/bin/env bash
set -euo pipefail

API_URL="${API_URL:-http://localhost:8080}"

run_burst() {
  local tier="$1"
  local total="$2"
  local concurrency="$3"

  seq 1 "$total" | xargs -n1 -P "$concurrency" -I{} curl -s -o /dev/null \
    -w "${tier} %{http_code} %{time_total}\n" \
    -H "X-Tenant-Tier: ${tier}" \
    "${API_URL}/api/data"
}

steady_stream() {
  local tier="$1"
  local count="$2"

  for _ in $(seq 1 "$count"); do
    curl -s -o /dev/null \
      -w "${tier} %{http_code} %{time_total}\n" \
      -H "X-Tenant-Tier: ${tier}" \
      "${API_URL}/api/data"
    sleep 0.5
  done
}

echo "Starting load test against ${API_URL}"

run_burst "free" 300 50 &
steady_stream "pro" 40 &
steady_stream "enterprise" 40 &

wait

echo "Load test complete. Check /metrics/bulkheads for pool saturation."
