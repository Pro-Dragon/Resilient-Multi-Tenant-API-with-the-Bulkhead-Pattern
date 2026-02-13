#!/usr/bin/env bash
###############################################################################
# integration.test.sh — Automated verification of all core requirements
#
# Usage:
#   docker-compose up --build -d
#   # wait for healthy
#   chmod +x tests/integration.test.sh
#   ./tests/integration.test.sh
###############################################################################
set -euo pipefail

API_URL="${API_URL:-http://localhost:8080}"
PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

http_code() {
  curl -s -o /dev/null -w "%{http_code}" "$@"
}

http_body() {
  curl -s "$@"
}

echo "=============================================="
echo " Integration Tests — ${API_URL}"
echo "=============================================="

###########################################################################
echo ""
echo "1. Health endpoint"
###########################################################################
CODE=$(http_code "${API_URL}/health")
BODY=$(http_body "${API_URL}/health")
if [ "$CODE" = "200" ]; then pass "GET /health returns 200"; else fail "GET /health returned $CODE"; fi
if echo "$BODY" | grep -q '"healthy"'; then pass "Body contains healthy"; else fail "Body: $BODY"; fi

###########################################################################
echo ""
echo "2. Data endpoint — valid tiers"
###########################################################################
for TIER in free pro enterprise; do
  CODE=$(http_code -H "X-Tenant-Tier: ${TIER}" "${API_URL}/api/data")
  BODY=$(http_body -H "X-Tenant-Tier: ${TIER}" "${API_URL}/api/data")
  if [ "$CODE" = "200" ]; then pass "GET /api/data tier=$TIER returns 200"; else fail "tier=$TIER returned $CODE"; fi
  if echo "$BODY" | grep -q "\"tier\":\"${TIER}\""; then pass "Body contains tier=$TIER"; else fail "Body missing tier=$TIER: $BODY"; fi
done

###########################################################################
echo ""
echo "3. Data endpoint — missing header"
###########################################################################
CODE=$(http_code "${API_URL}/api/data")
if [ "$CODE" = "400" ]; then pass "Missing header returns 400"; else fail "Missing header returned $CODE"; fi

###########################################################################
echo ""
echo "4. Data endpoint — invalid tier"
###########################################################################
CODE=$(http_code -H "X-Tenant-Tier: invalid" "${API_URL}/api/data")
if [ "$CODE" = "400" ]; then pass "Invalid tier returns 400"; else fail "Invalid tier returned $CODE"; fi

###########################################################################
echo ""
echo "5. Free tier rate limiting (100 RPM)"
###########################################################################
# Wait briefly to ensure a clean rate limit window
sleep 1
OK=0
LIMITED=0
for i in $(seq 1 110); do
  CODE=$(http_code -H "X-Tenant-Tier: free" "${API_URL}/api/data")
  if [ "$CODE" = "200" ]; then OK=$((OK + 1)); fi
  if [ "$CODE" = "429" ]; then LIMITED=$((LIMITED + 1)); fi
done
if [ "$OK" -le 101 ] && [ "$OK" -ge 95 ]; then pass "~100 requests succeeded ($OK)"; else fail "Expected ~100 successes, got $OK"; fi
if [ "$LIMITED" -ge 1 ]; then pass "Rate limiting triggered ($LIMITED x 429)"; else fail "No 429 responses received"; fi

###########################################################################
echo ""
echo "6. Enterprise tier — no rate limit"
###########################################################################
# Wait for rate limit window reset
sleep 61
ENT_OK=0
for i in $(seq 1 120); do
  CODE=$(http_code -H "X-Tenant-Tier: enterprise" "${API_URL}/api/data")
  if [ "$CODE" = "200" ]; then ENT_OK=$((ENT_OK + 1)); fi
done
if [ "$ENT_OK" -eq 120 ]; then pass "All 120 enterprise requests succeeded"; else fail "Enterprise: $ENT_OK/120 succeeded"; fi

###########################################################################
echo ""
echo "7. Metrics endpoint schema"
###########################################################################
METRICS=$(http_body "${API_URL}/metrics/bulkheads")
CODE=$(http_code "${API_URL}/metrics/bulkheads")
if [ "$CODE" = "200" ]; then pass "GET /metrics/bulkheads returns 200"; else fail "Metrics returned $CODE"; fi

for TIER in free pro enterprise; do
  if echo "$METRICS" | grep -q "\"${TIER}\""; then pass "Metrics contains $TIER"; else fail "Metrics missing $TIER"; fi
done

# Check specific pool sizes
if echo "$METRICS" | grep -q '"max":5';  then pass "free connPool.max=5";  else fail "free connPool.max not 5"; fi
if echo "$METRICS" | grep -q '"max":20'; then pass "pro connPool.max=20";  else fail "pro connPool.max not 20"; fi
if echo "$METRICS" | grep -q '"max":50'; then pass "ent connPool.max=50";  else fail "ent connPool.max not 50"; fi
if echo "$METRICS" | grep -q '"poolSize":10'; then pass "free poolSize=10"; else fail "free poolSize not 10"; fi
if echo "$METRICS" | grep -q '"poolSize":30'; then pass "pro poolSize=30";  else fail "pro poolSize not 30"; fi
if echo "$METRICS" | grep -q '"poolSize":60'; then pass "ent poolSize=60";  else fail "ent poolSize not 60"; fi

###########################################################################
echo ""
echo "8. Circuit breaker isolation"
###########################################################################
# Wait for rate limit window reset
sleep 61

# Verify all breakers start CLOSED
METRICS=$(http_body "${API_URL}/metrics/bulkheads")
# All states should be CLOSED at this point
CB_CLOSED=$(echo "$METRICS" | grep -o '"state":"CLOSED"' | wc -l | tr -d ' ')
if [ "$CB_CLOSED" -eq 3 ]; then pass "All 3 circuit breakers start CLOSED"; else fail "Expected 3 CLOSED breakers, got $CB_CLOSED"; fi

# Trip free tier breaker
for i in $(seq 1 6); do
  http_code -H "X-Tenant-Tier: free" "${API_URL}/api/data?force_error=true" > /dev/null
done

METRICS=$(http_body "${API_URL}/metrics/bulkheads")

# Check free is OPEN
if echo "$METRICS" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['free']['circuitBreaker']['state']=='OPEN' else 1)" 2>/dev/null; then
  pass "Free circuit breaker is OPEN after forced errors"
else
  fail "Free circuit breaker did not open"
fi

# Check pro is still CLOSED
if echo "$METRICS" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['pro']['circuitBreaker']['state']=='CLOSED' else 1)" 2>/dev/null; then
  pass "Pro circuit breaker remains CLOSED"
else
  fail "Pro circuit breaker unexpectedly changed state"
fi

# Check enterprise is still CLOSED
if echo "$METRICS" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['enterprise']['circuitBreaker']['state']=='CLOSED' else 1)" 2>/dev/null; then
  pass "Enterprise circuit breaker remains CLOSED"
else
  fail "Enterprise circuit breaker unexpectedly changed state"
fi

# Pro should still work
CODE=$(http_code -H "X-Tenant-Tier: pro" "${API_URL}/api/data")
if [ "$CODE" = "200" ]; then pass "Pro tier works while free breaker is open"; else fail "Pro failed with $CODE"; fi

###########################################################################
echo ""
echo "=============================================="
echo " Results: $PASS passed, $FAIL failed"
echo "=============================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  echo "All tests passed."
  exit 0
fi
