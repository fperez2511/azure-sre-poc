#!/usr/bin/env bash
# SLO report from Application Insights data (server-side SLIs).
# Usage: ./scripts/slo-report.sh [window_hours=24]
#
# Note: telemetry arrives in Log Analytics with a 2-5 minute delay.
source "$(dirname "$0")/lib.sh"
require az
load_env

HOURS="${1:-24}"
KQL_DIR="$(dirname "$0")/../docs/kql"

run() {
  local title="$1" file="$2"
  echo
  info "$title (last ${HOURS}h)"
  kql "$(sed "s/{{WINDOW}}/${HOURS}h/g" "$KQL_DIR/$file")"
}

run "Availability SLI per flow (target 99.5%)" sli-availability.kql
run "Latency SLI per flow"                   sli-latency.kql
run "Error budget"                            error-budget.kql
