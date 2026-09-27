#!/usr/bin/env bash
# A complete, repeatable chaos "game day":
#   1. baseline traffic   2. start experiment under load   3. recovery   4. evidence report
#
# Usage: ./scripts/gameday.sh blackout|failover [baseline_s=120] [recovery_s=180] [rps=3]
# Produces gameday-<experiment>-<timestamp>.md (also appended to $GITHUB_STEP_SUMMARY in CI).
source "$(dirname "$0")/lib.sh"
require az curl awk
load_env

EXPERIMENT="${1:?usage: gameday.sh blackout|failover}"
BASELINE="${2:-120}"
RECOVERY="${3:-180}"
RPS="${4:-3}"
DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="gameday-${EXPERIMENT}-${STAMP}.md"
export TRAFFIC_LOG="gameday-${EXPERIMENT}-${STAMP}.csv"

# Fault duration from the deployed experiment (defaults to 10 minutes).
FAULT_SECONDS=600
case "${CHAOS_FAULT_DURATION:-PT10M}" in
  PT*M) FAULT_SECONDS=$(( ${CHAOS_FAULT_DURATION//[!0-9]/} * 60 )) ;;
esac
TOTAL=$((BASELINE + FAULT_SECONDS + RECOVERY))

START="$(now_iso)"
info "Game day '$EXPERIMENT' started $START: ${BASELINE}s baseline, ~${FAULT_SECONDS}s fault, ${RECOVERY}s recovery"
"$DIR/traffic.sh" "$TOTAL" "$RPS" > "gameday-${EXPERIMENT}-${STAMP}.traffic.txt" 2>&1 &
TRAFFIC_PID=$!

sleep "$BASELINE"
FAULT_START="$(now_iso)"
"$DIR/chaos.sh" start "$EXPERIMENT"
"$DIR/chaos.sh" wait "$EXPERIMENT"
FAULT_END="$(now_iso)"

info "Fault finished at $FAULT_END – observing recovery"
wait "$TRAFFIC_PID" || true
END="$(now_iso)"

info "Waiting 5 minutes for telemetry ingestion before querying Log Analytics..."
sleep 300

{
  echo "# Game day report: $EXPERIMENT"
  echo
  echo "| | UTC |"
  echo "|---|---|"
  echo "| Traffic start | $START |"
  echo "| Fault start | $FAULT_START |"
  echo "| Fault end | $FAULT_END |"
  echo "| Traffic end | $END |"
  echo
  echo "## Client-side view (what users saw)"
  echo '```'
  tail -n 12 "gameday-${EXPERIMENT}-${STAMP}.traffic.txt"
  echo '```'
  echo
  echo "## Server-side view (Application Insights, per minute)"
  echo '```'
  kql "$(sed -e "s/{{START}}/$START/" -e "s/{{END}}/$END/" "$DIR/../docs/kql/timeline.kql")"
  echo '```'
  echo
  echo "## Hypothesis check (fill in)"
  echo "- Hypothesis: …"
  echo "- Steady state held? …"
  echo "- Time to detect (first alert): …   Time to recover: …"
  echo "- Follow-up actions: …"
} > "$REPORT"

cat "$REPORT"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
info "Report written to $REPORT"
