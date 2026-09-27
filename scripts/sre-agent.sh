#!/usr/bin/env bash
# Turn Azure SRE Agent on for the labs, and off again to stop its always-on billing.
#
# Usage:
#   ./scripts/sre-agent.sh up       # deploys the agent into rg-<env>-sreagent
#   ./scripts/sre-agent.sh status
#   ./scripts/sre-agent.sh down     # DELETES the agent resource group (billing stops)
#
# Stopping an agent in the portal does NOT stop the always-on charge – only deleting does.
source "$(dirname "$0")/lib.sh"
require az azd
load_env

case "${1:-status}" in
  up)
    warn "An SRE Agent is billed 4 AAU/hour while it exists (waived during the 30-day evaluation)."
    azd env set DEPLOY_SRE_AGENT true
    azd provision
    set -a; eval "$(azd env get-values)"; set +a
    info "Agent portal: ${SRE_AGENT_PORTAL_URL:-https://sre.azure.com}"
    ;;
  status)
    if [[ -n "${SRE_AGENT_RESOURCE_GROUP:-}" ]] && az group exists -n "$SRE_AGENT_RESOURCE_GROUP" | grep -q true; then
      az resource list -g "$SRE_AGENT_RESOURCE_GROUP" --query "[].{name:name, type:type, location:location}" -o table
      echo "Portal: ${SRE_AGENT_PORTAL_URL:-https://sre.azure.com}"
    else
      echo "No SRE Agent deployed for this environment."
    fi
    ;;
  down)
    rg="${SRE_AGENT_RESOURCE_GROUP:-rg-${AZURE_ENV_NAME}-sreagent}"
    if az group exists -n "$rg" | grep -q true; then
      warn "Deleting resource group $rg (agent, its identity and settings)."
      az group delete -n "$rg" --yes
    fi
    azd env set DEPLOY_SRE_AGENT false
    info "SRE Agent removed. Its role assignments on $AZURE_RESOURCE_GROUP become orphaned (harmless); the next 'azd provision' leaves them alone."
    ;;
  *) die "Use: up | status | down" ;;
esac
