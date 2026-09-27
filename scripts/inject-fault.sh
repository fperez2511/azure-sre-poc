#!/usr/bin/env bash
# Simulate a BAD RELEASE by changing the API's fault-injection settings.
# Each change creates a new Container Apps revision – to Azure (and to SRE Agent) this looks
# exactly like someone shipped a new version.
#
# Usage:
#   ./scripts/inject-fault.sh errors [rate=0.3]     # ~30% of /api requests throw -> HTTP 500
#   ./scripts/inject-fault.sh latency [ms=2500]     # every /api request is slowed down
#   ./scripts/inject-fault.sh crash                 # new revision cannot start (crash on boot)
#   ./scripts/inject-fault.sh clear                 # ship a "fixed" revision (all faults off)
#   ./scripts/inject-fault.sh status                # show revisions and current settings
source "$(dirname "$0")/lib.sh"
require az
load_env
: "${SERVICE_API_NAME:?missing – run azd up}"

APP=(--name "$SERVICE_API_NAME" --resource-group "$AZURE_RESOURCE_GROUP")

show_status() {
  info "Revisions (newest last):"
  az containerapp revision list "${APP[@]}" --all \
    --query "sort_by(@, &properties.createdTime)[].{revision:name, created:properties.createdTime, active:properties.active, traffic:properties.trafficWeight, health:properties.healthState, state:properties.runningState}" \
    -o table
  info "Fault settings on the latest template:"
  az containerapp show "${APP[@]}" \
    --query "properties.template.containers[0].env[?starts_with(name, 'FAULT_')].{name:name, value:value}" -o table
}

update() {
  info "Rolling out a new revision with: $*"
  az containerapp update "${APP[@]}" --set-env-vars "$@" -o none
  show_status
}

case "${1:-status}" in
  errors)  update "FAULT_ERROR_RATE=${2:-0.3}" "FAULT_LATENCY_MS=0" "FAULT_CRASH_ON_STARTUP=false" ;;
  latency) update "FAULT_LATENCY_MS=${2:-2500}" "FAULT_ERROR_RATE=0" "FAULT_CRASH_ON_STARTUP=false" ;;
  crash)
    warn "The new revision will fail its startup probe. Watch the OLD revision keep serving traffic."
    update "FAULT_CRASH_ON_STARTUP=true" "FAULT_ERROR_RATE=0" "FAULT_LATENCY_MS=0" ;;
  clear)   update "FAULT_ERROR_RATE=0" "FAULT_LATENCY_MS=0" "FAULT_CRASH_ON_STARTUP=false" ;;
  status)  show_status ;;
  *) die "Unknown fault '$1'. Use: errors | latency | crash | clear | status" ;;
esac
