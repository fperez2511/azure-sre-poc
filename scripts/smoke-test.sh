#!/usr/bin/env bash
# Quick end-to-end check of the critical user flows: browse offerings and create a booking.
# Usage: ./scripts/smoke-test.sh
source "$(dirname "$0")/lib.sh"
require curl
load_env
: "${SERVICE_API_URI:?missing – run azd deploy}"

fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "  PASS  $name ($actual)"; else echo "  FAIL  $name (expected $expected, got $actual)"; fail=1; fi
}

info "Target: $SERVICE_API_URI"
check "liveness"      200 "$(curl -s -o /dev/null -w '%{http_code}' "$SERVICE_API_URI/healthz/live")"
check "readiness"     200 "$(curl -s -o /dev/null -w '%{http_code}' "$SERVICE_API_URI/healthz/ready")"
check "dependencies"  200 "$(curl -s -o /dev/null -w '%{http_code}' "$SERVICE_API_URI/healthz/deps")"
check "browse offerings" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$SERVICE_API_URI/api/offerings")"

key="smoke-$(date +%s)"
body=$(printf '{"offeringId":"career-1on1-60","customerId":"cust-smoke","customerEmail":"smoke@example.com","startTimeUtc":"%s","attendees":1}' "$(iso_in_days 7)")
check "create booking" 201 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SERVICE_API_URI/api/bookings" \
  -H 'Content-Type: application/json' -H "Idempotency-Key: $key" -d "$body")"
check "retry is idempotent" 200 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SERVICE_API_URI/api/bookings" \
  -H 'Content-Type: application/json' -H "Idempotency-Key: $key" -d "$body")"
check "list bookings" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$SERVICE_API_URI/api/customers/cust-smoke/bookings")"
check "validation (bad attendees)" 400 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SERVICE_API_URI/api/bookings" \
  -H 'Content-Type: application/json' -d "${body/\"attendees\":1/\"attendees\":3}")"

echo
curl -s "$SERVICE_API_URI/healthz/deps"; echo
[[ $fail -eq 0 ]] && info "All smoke tests passed" || die "Smoke tests failed"
