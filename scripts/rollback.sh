#!/usr/bin/env bash
# Roll back the API to a previous revision (the classic first mitigation for a bad release:
# "stop the bleeding first, find the root cause later").
#
# In single-revision mode, rolling back = creating a new revision from the template of a
# known-good one. Container Apps only shifts traffic once the new revision is healthy.
#
# Usage:
#   ./scripts/rollback.sh                 # list revisions and pick interactively
#   ./scripts/rollback.sh <revision-name> # roll back to that revision
source "$(dirname "$0")/lib.sh"
require az
load_env
: "${SERVICE_API_NAME:?missing – run azd up}"
APP=(--name "$SERVICE_API_NAME" --resource-group "$AZURE_RESOURCE_GROUP")

target="${1:-}"
if [[ -z "$target" ]]; then
  info "Revisions (newest first). Pick the last one that was healthy BEFORE the incident started:"
  az containerapp revision list "${APP[@]}" --all \
    --query "reverse(sort_by(@, &properties.createdTime))[].{revision:name, created:properties.createdTime, active:properties.active, health:properties.healthState}" \
    -o table
  read -r -p "Revision to roll back to: " target
fi
[[ -n "$target" ]] || die "No revision given."

info "Creating a new revision from '$target' ..."
az containerapp revision copy "${APP[@]}" --from-revision "$target" -o none
info "Done. Current state:"
az containerapp revision list "${APP[@]}" \
  --query "[].{revision:name, active:properties.active, traffic:properties.trafficWeight, health:properties.healthState}" -o table
echo
echo "Verify recovery with: ./scripts/traffic.sh 120   and   ./scripts/slo-report.sh 1"
