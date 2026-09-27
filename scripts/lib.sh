#!/usr/bin/env bash
# Shared helpers for the lab scripts. Source it: `source "$(dirname "$0")/lib.sh"`.
# Works in Cloud Shell, GitHub Codespaces / the dev container, WSL and Linux.

set -euo pipefail

export CHAOS_API_VERSION="2024-01-01"

# Load the active azd environment's values (AZURE_RESOURCE_GROUP, SERVICE_API_URI, ...)
# into the current shell, unless they are already set (e.g. in CI).
load_env() {
  if [[ -z "${AZURE_RESOURCE_GROUP:-}" ]]; then
    if ! command -v azd >/dev/null 2>&1; then
      die "azd not found and AZURE_RESOURCE_GROUP is not set."
    fi
    local values
    values="$(azd env get-values 2>/dev/null)" || die "No azd environment found. Run 'azd up' first."
    set -a
    eval "$values"
    set +a
  fi
  : "${AZURE_RESOURCE_GROUP:?missing – run azd up}"
  : "${AZURE_SUBSCRIPTION_ID:?missing – run azd up}"
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m!!\033[0m $*" >&2; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
  done
}

# ISO-8601 UTC timestamp N days from now (GNU date, with a BSD/macOS fallback).
iso_in_days() {
  local days="$1"
  date -u -d "+${days} days" +%Y-%m-%dT%H:00:00+00:00 2>/dev/null \
    || date -u -v+"${days}"d +%Y-%m-%dT%H:00:00+00:00
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

chaos_experiment_id() {
  echo "/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.Chaos/experiments/$1"
}

# Run a KQL query against the workload's Log Analytics workspace and print a table.
kql() {
  local query="$1"
  : "${LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID:?missing – run azd up}"
  az monitor log-analytics query \
    --workspace "$LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID" \
    --analytics-query "$query" \
    --output table
}
