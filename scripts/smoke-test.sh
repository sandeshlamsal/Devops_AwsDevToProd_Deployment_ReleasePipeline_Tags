#!/bin/bash
# smoke-test.sh <base_url>
# Runs a set of smoke tests against a deployed nginx-release instance.
# Exits 0 on pass, 1 on any failure.

set -euo pipefail

BASE_URL="${1:-}"
if [ -z "$BASE_URL" ]; then
  echo "Usage: $0 <base_url>   (e.g. http://abc.us-east-1.elb.amazonaws.com)"
  exit 1
fi

# Strip trailing slash
BASE_URL="${BASE_URL%/}"

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"   # "ok" or error message
  if [ "$result" = "ok" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc — $result"
    FAIL=$((FAIL + 1))
  fi
}

wait_for_ready() {
  echo "Waiting for $BASE_URL to be reachable..."
  for i in $(seq 1 20); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${BASE_URL}/health" 2>/dev/null || echo "000")
    [ "$HTTP" = "200" ] && echo "Ready." && return 0
    echo "  ($i) HTTP $HTTP — retrying in 10s..."
    sleep 10
  done
  echo "ERROR: Service did not become ready after 200s"
  exit 1
}

# ─── Tests ────────────────────────────────────────────────────────────────────

wait_for_ready

echo ""
echo "Running smoke tests against $BASE_URL"
echo "──────────────────────────────────────"

# 1. Health endpoint returns 200
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${BASE_URL}/health")
[ "$HTTP" = "200" ] && check "/health → 200" "ok" || check "/health → 200" "got $HTTP"

# 2. Index page returns 200
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${BASE_URL}/")
[ "$HTTP" = "200" ] && check "/ → 200" "ok" || check "/ → 200" "got $HTTP"

# 3. /version returns valid JSON with required fields
VERSION_BODY=$(curl -sf --max-time 10 "${BASE_URL}/version" 2>/dev/null || echo "")
if echo "$VERSION_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'version'   in d, 'missing version'
assert 'sha'       in d, 'missing sha'
assert 'env'       in d, 'missing env'
assert 'buildDate' in d, 'missing buildDate'
assert d['version'] != 'unknown', 'version is unknown'
" 2>/dev/null; then
  check "/version JSON valid" "ok"
else
  check "/version JSON valid" "invalid or missing fields: $VERSION_BODY"
fi

# 4. Index page HTML contains version string
PAGE=$(curl -sf --max-time 10 "${BASE_URL}/" 2>/dev/null || echo "")
echo "$PAGE" | grep -q "Release Dashboard" && \
  check "index.html contains 'Release Dashboard'" "ok" || \
  check "index.html contains 'Release Dashboard'" "string not found"

# 5. Security headers present
HEADERS=$(curl -sI --max-time 10 "${BASE_URL}/" 2>/dev/null || echo "")
echo "$HEADERS" | grep -qi "X-Frame-Options" && \
  check "X-Frame-Options header present" "ok" || \
  check "X-Frame-Options header present" "header missing"

echo "$HEADERS" | grep -qi "X-Content-Type-Options" && \
  check "X-Content-Type-Options header present" "ok" || \
  check "X-Content-Type-Options header present" "header missing"

# 6. Non-existent path returns 404
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${BASE_URL}/does-not-exist-xyz")
[ "$HTTP" = "404" ] && check "unknown path → 404" "ok" || check "unknown path → 404" "got $HTTP"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  echo "SMOKE TEST FAILED"
  exit 1
fi

echo "SMOKE TEST PASSED"
exit 0
