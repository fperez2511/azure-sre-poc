#!/usr/bin/env bash
# Drive Azure Chaos Studio experiments from the command line.
#
# Usage:
#   ./scripts/chaos.sh list
#   ./scripts/chaos.sh start  blackout|failover
#   ./scripts/chaos.sh status blackout|failover
#   ./scripts/chaos.sh wait   blackout|failover   # block until the run finishes
#   ./scripts/chaos.sh cancel blackout|failover   # abort: Chaos Studio rolls the fault back
source "$(dirname "$0")/lib.sh"
require az
load_env

resolve() {
  case "$1" in
    blackout) echo "${CHAOS_EXPERIMENT_COSMOS_BLACKOUT:-}" ;;
    failover) echo "${CHAOS_EXPERIMENT_COSMOS_FAILOVER:-}" ;;
    *) echo "$1" ;; # allow a full experiment name
  esac
}

cmd="${1:-list}"
if [[ "$cmd" == "list" ]]; then
  az resource list -g "$AZURE_RESOURCE_GROUP" --resource-type Microsoft.Chaos/experiments \
    --query "[].{name:name, location:location}" -o table
  exit 0
fi

name="$(resolve "${2:-}")"
[[ -n "$name" ]] || die "Experiment not deployed. For 'failover' set COSMOS_SECONDARY_LOCATION and run azd provision."
url="https://management.azure.com$(chaos_experiment_id "$name")"

latest_status() {
  az rest --method get --url "$url/executions?api-version=$CHAOS_API_VERSION" \
    --query "sort_by(value, &properties.startedAt)[-1].{status:properties.status, started:properties.startedAt, stopped:properties.stoppedAt}" \
    -o tsv 2>/dev/null || true
}

case "$cmd" in
  start)
    info "Starting experiment $name at $(now_iso)"
    az rest --method post --url "$url/start?api-version=$CHAOS_API_VERSION" -o none
    echo "Follow it in the portal: Chaos Studio > Experiments > $name, or: ./scripts/chaos.sh wait ${2}"
    ;;
  status)
    latest_status
    ;;
  wait)
    info "Waiting for $name to finish (Ctrl+C stops waiting, not the experiment)"
    while true; do
      s="$(latest_status)"
      printf '%s  %s\n' "$(date -u +%H:%M:%S)" "${s:-no runs yet}"
      case "$s" in
        Success*|Completed*|Failed*|Cancelled*) break ;;
      esac
      sleep 30
    done
    ;;
  cancel)
    warn "Cancelling $name"
    az rest --method post --url "$url/cancel?api-version=$CHAOS_API_VERSION" -o none
    ;;
  *) die "Unknown command '$cmd'" ;;
esac
