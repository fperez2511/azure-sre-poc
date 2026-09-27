#!/usr/bin/env bash
# Synthetic user traffic: browse the catalog, create bookings, view "my bookings".
# Every request is logged to a CSV so you can compare what USERS saw (client-side SLI)
# with what the server recorded in Application Insights (server-side SLI).
#
# Usage: ./scripts/traffic.sh [duration_seconds=300] [requests_per_second=3]
#   TRAFFIC_LOG=path.csv ./scripts/traffic.sh 600 5
source "$(dirname "$0")/lib.sh"
require curl awk
load_env
: "${SERVICE_API_URI:?missing – run azd deploy}"

DURATION="${1:-300}"
RPS="${2:-3}"
LOG="${TRAFFIC_LOG:-traffic-$(date -u +%Y%m%dT%H%M%SZ).csv}"
echo "epoch,flow,status,latency_s,revision" > "$LOG"

customers=(cust-ana cust-ben cust-carla cust-dev cust-eli cust-fabrikam)
offerings=(career-1on1-60 exec-1on1-90 group-circle-90 group-mastermind-120 biz-keynote-60 workshop-resilience-halfday)
WRITE_OUT='%{http_code},%{time_total},%header{x-revision}'

request() {
  local flow="$1" out="" customer offering attendees body
  customer="${customers[RANDOM % ${#customers[@]}]}"
  case "$flow" in
    browse)
      out=$(curl -s -o /dev/null -m 10 -w "$WRITE_OUT" "$SERVICE_API_URI/api/offerings" || true) ;;
    mine)
      out=$(curl -s -o /dev/null -m 10 -w "$WRITE_OUT" "$SERVICE_API_URI/api/customers/$customer/bookings" || true) ;;
    book)
      offering="${offerings[RANDOM % ${#offerings[@]}]}"
      attendees=1
      [[ "$offering" == group-* ]] && attendees=2
      [[ "$offering" == workshop-* || "$offering" == biz-* ]] && attendees=12
      body=$(printf '{"offeringId":"%s","customerId":"%s","customerEmail":"%s@example.com","startTimeUtc":"%s","attendees":%d}' \
        "$offering" "$customer" "$customer" "$(iso_in_days $((2 + RANDOM % 60)))" "$attendees")
      out=$(curl -s -o /dev/null -m 10 -w "$WRITE_OUT" -X POST "$SERVICE_API_URI/api/bookings" \
        -H 'Content-Type: application/json' -H "Idempotency-Key: t$(date +%s%N)$RANDOM" -d "$body" || true) ;;
  esac
  echo "$(date +%s),$flow,${out:-000,10,}" >> "$LOG"
}

pick_flow() {
  local r=$((RANDOM % 100))
  if (( r < 60 )); then echo browse; elif (( r < 85 )); then echo book; else echo mine; fi
}

summary() { # $1 = epoch to start from (0 = everything)
  awk -F, -v since="$1" 'NR > 1 && $1 >= since {
      total++; lat += $4
      if ($3 == "000") timeout++; else if ($3 >= 500) err++; else ok++
      if ($5 != "") rev[$5] = 1
    }
    END {
      if (total == 0) { print "  (no requests yet)"; exit }
      revs = ""; for (r in rev) revs = revs r " "
      printf "  requests=%d  ok=%d  5xx=%d  timeouts=%d  availability=%.1f%%  avg_latency=%.2fs  revisions=[%s]\n",
        total, ok, err, timeout, 100 * ok / total, lat / total, revs
    }' "$LOG"
}

info "Sending ~${RPS} req/s to $SERVICE_API_URI for ${DURATION}s  (log: $LOG)"
end=$((SECONDS + DURATION))
window_start=$(date +%s)
while (( SECONDS < end )); do
  for ((i = 0; i < RPS; i++)); do
    request "$(pick_flow)" &
  done
  sleep 1
  if (( $(date +%s) - window_start >= 10 )); then
    printf '%s last 10s:' "$(date -u +%H:%M:%S)"
    summary "$window_start"
    window_start=$(date +%s)
  fi
done
wait

echo
info "Overall (client-side view, what users experienced):"
summary 0
echo "  Per flow:"
awk -F, 'NR > 1 { t[$2]++; if ($3 != "000" && $3 < 500) ok[$2]++ }
  END { for (f in t) printf "    %-7s %5d requests  availability=%.1f%%\n", f, t[f], 100 * ok[f] / t[f] }' "$LOG"
