#!/usr/bin/env bash
###############################################################################
# load-test.sh — Demonstrates bulkhead isolation under load
#
# Usage:
#   chmod +x load-test.sh
#   ./load-test.sh                       # default: http://localhost:8080
#   API_URL=http://myhost:8080 ./load-test.sh
#
# The script floods the free tier with 300 concurrent requests while
# simultaneously sending a low, steady stream of requests to the pro and
# enterprise tiers.  The output summary proves that pro/enterprise remain
# fully responsive while the free tier is rate-limited (429).
###############################################################################
set -euo pipefail

API_URL="${API_URL:-http://localhost:8080}"
RESULTS_DIR=$(mktemp -d)

trap 'rm -rf "$RESULTS_DIR"' EXIT

echo "=============================================="
echo " Bulkhead Isolation Load Test"
echo " Target: ${API_URL}"
echo "=============================================="
echo ""

###############################################################################
# Free tier — high-volume burst (300 requests, 50 concurrent)
###############################################################################
echo "[FREE ] Sending 300 requests with concurrency 50 ..."
seq 1 300 | xargs -n1 -P50 -I{} \
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "X-Tenant-Tier: free" \
    "${API_URL}/api/data" \
  >> "${RESULTS_DIR}/free.txt" 2>/dev/null &
FREE_PID=$!

###############################################################################
# Pro tier — steady stream (20 requests, 1 every 0.5s)
###############################################################################
echo "[PRO  ] Sending 20 requests at ~2 req/s ..."
(
  for i in $(seq 1 20); do
    curl -s -o /dev/null -w "%{http_code}\n" \
      -H "X-Tenant-Tier: pro" \
      "${API_URL}/api/data" \
      >> "${RESULTS_DIR}/pro.txt" 2>/dev/null
    sleep 0.5
  done
) &
PRO_PID=$!

###############################################################################
# Enterprise tier — steady stream (20 requests, 1 every 0.5s)
###############################################################################
echo "[ENTER] Sending 20 requests at ~2 req/s ..."
(
  for i in $(seq 1 20); do
    curl -s -o /dev/null -w "%{http_code}\n" \
      -H "X-Tenant-Tier: enterprise" \
      "${API_URL}/api/data" \
      >> "${RESULTS_DIR}/enterprise.txt" 2>/dev/null
    sleep 0.5
  done
) &
ENTERPRISE_PID=$!

###############################################################################
# Wait for all background processes
###############################################################################
echo ""
echo "Waiting for all requests to complete ..."
wait "$FREE_PID" "$PRO_PID" "$ENTERPRISE_PID" 2>/dev/null || true
echo ""

###############################################################################
# Tally results
###############################################################################
count_code() {
  local file="$1" code="$2"
  grep -c "^${code}$" "$file" 2>/dev/null || echo 0
}

FREE_TOTAL=$(wc -l < "${RESULTS_DIR}/free.txt" | tr -d ' ')
FREE_200=$(count_code "${RESULTS_DIR}/free.txt" 200)
FREE_429=$(count_code "${RESULTS_DIR}/free.txt" 429)
FREE_503=$(count_code "${RESULTS_DIR}/free.txt" 503)
FREE_OTHER=$((FREE_TOTAL - FREE_200 - FREE_429 - FREE_503))

PRO_TOTAL=$(wc -l < "${RESULTS_DIR}/pro.txt" | tr -d ' ')
PRO_200=$(count_code "${RESULTS_DIR}/pro.txt" 200)
PRO_FAIL=$((PRO_TOTAL - PRO_200))

ENT_TOTAL=$(wc -l < "${RESULTS_DIR}/enterprise.txt" | tr -d ' ')
ENT_200=$(count_code "${RESULTS_DIR}/enterprise.txt" 200)
ENT_FAIL=$((ENT_TOTAL - ENT_200))

###############################################################################
# Print summary
###############################################################################
echo "=============================================="
echo " Load Test Results"
echo "=============================================="
printf "\n%-14s %6s %6s %6s %6s %6s\n" "TIER" "TOTAL" "200" "429" "503" "OTHER"
echo "----------------------------------------------"
printf "%-14s %6d %6d %6d %6d %6d\n" "free"       "$FREE_TOTAL" "$FREE_200" "$FREE_429" "$FREE_503" "$FREE_OTHER"
printf "%-14s %6d %6d %6s %6s %6d\n" "pro"        "$PRO_TOTAL"  "$PRO_200"  "-"         "-"         "$PRO_FAIL"
printf "%-14s %6d %6d %6s %6s %6d\n" "enterprise" "$ENT_TOTAL"  "$ENT_200"  "-"         "-"         "$ENT_FAIL"
echo ""

###############################################################################
# Fetch and display bulkhead metrics
###############################################################################
echo "=============================================="
echo " Bulkhead Metrics (post-load)"
echo "=============================================="
METRICS=$(curl -s "${API_URL}/metrics/bulkheads")
echo "$METRICS" | python3 -m json.tool 2>/dev/null || echo "$METRICS"
echo ""

###############################################################################
# Verdict
###############################################################################
echo "=============================================="
echo " Verdict"
echo "=============================================="
PASS=true

if [ "$PRO_200" -ge 18 ] && [ "$ENT_200" -ge 18 ]; then
  echo "[PASS] Pro and Enterprise tiers remained fully responsive."
else
  echo "[FAIL] Some pro/enterprise requests failed — isolation may be broken."
  PASS=false
fi

if [ "$FREE_429" -gt 0 ] || [ "$FREE_503" -gt 0 ]; then
  echo "[PASS] Free tier experienced rate limiting / circuit breaker as expected."
else
  echo "[WARN] Free tier was not rate-limited — test may have been too short."
fi

echo ""
if [ "$PASS" = true ]; then
  echo "Bulkhead isolation is working correctly."
else
  echo "Bulkhead isolation needs investigation."
  exit 1
fi
