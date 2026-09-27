// Azure SRE Agent (optional – deployed only when deploySreAgent = true).
//
// Adapted from Microsoft's reference templates:
//   https://github.com/microsoft/sre-agent/tree/main/sreagent-templates/bicep
//
// COST: an agent is billed 4 AAU per hour ("always-on flow") for as long as it EXISTS –
// stopping it does not stop that charge; only deleting does. New customers get a 30-day
// evaluation that waives the always-on charge. Active-flow AAUs (the agent actually
// thinking) are capped by monthlyAgentUnitLimit. That is why this module lives in its own
// resource group: `scripts/sre-agent.sh down` deletes it in one command.
//
// Deployed here: agent + identity + RBAC + data connectors (App Insights, Log Analytics,
// Azure Monitor). Knowledge files, response plans, custom agents and scheduled tasks are
// data-plane settings you configure in the portal during Lab 7 (that is part of the learning).
param location string
param tags object
param agentName string
param workloadResourceGroupName string

@allowed([ 'Low', 'High' ])
param accessLevel string

@allowed([ 'Review', 'Automatic' ])
param actionMode string

param monthlyAgentUnitLimit int
param appInsightsId string
param appInsightsAppId string
@secure()
param appInsightsConnectionString string
param logAnalyticsWorkspaceId string
param adminPrincipalId string
param adminPrincipalType string

@allowed([ 'Stable', 'Preview' ])
param upgradeChannel string = 'Stable'

@description('Model provider for the agent (see the SRE Agent pricing page for AAU rates per model).')
param defaultModelProvider string = 'MicrosoftFoundry'

@description('Model name. "Automatic" lets the service choose.')
param defaultModelName string = 'Automatic'

// ---------- Identity ----------
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${agentName}-id'
  location: location
  tags: tags
}

// ---------- RBAC for the user-assigned identity on the workload resource group ----------
module uamiRbac 'sre-agent-rbac.bicep' = {
  name: 'sre-agent-rbac-uami'
  scope: resourceGroup(workloadResourceGroupName)
  params: {
    principalId: identity.properties.principalId
    accessLevel: accessLevel
  }
}

// ---------- The agent ----------
#disable-next-line BCP081
resource agent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: identity.id
      // Resource groups "in scope" – shown as Connected resources in sre.azure.com.
      managedResources: [
        subscriptionResourceId('Microsoft.Resources/resourceGroups', workloadResourceGroupName)
      ]
    }
    actionConfiguration: {
      accessLevel: accessLevel
      identity: identity.id
      mode: actionMode
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
    upgradeChannel: upgradeChannel
    monthlyAgentUnitLimit: monthlyAgentUnitLimit
    defaultModel: {
      provider: defaultModelProvider
      name: defaultModelName
    }
  }
  dependsOn: [ uamiRbac ]
}

// The system-assigned identity is used for connector queries (App Insights / Log Analytics).
module systemRbac 'sre-agent-rbac.bicep' = {
  name: 'sre-agent-rbac-system'
  scope: resourceGroup(workloadResourceGroupName)
  params: {
    principalId: agent.identity.principalId
    accessLevel: accessLevel
  }
}

// ---------- Data connectors: where the agent looks during an investigation ----------
#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: appInsightsId
    extendedProperties: {
      armResourceId: appInsightsId
      resource: { name: last(split(appInsightsId, '/')) }
      appId: appInsightsAppId
    }
    identity: 'system'
  }
  dependsOn: [ systemRbac ]
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsWorkspaceId
    extendedProperties: {
      armResourceId: logAnalyticsWorkspaceId
      resource: { name: last(split(logAnalyticsWorkspaceId, '/')) }
    }
    identity: 'system'
  }
  dependsOn: [ appInsightsConnector ] // connectors must be created one at a time
}

#disable-next-line BCP081
resource azureMonitorConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'azure-monitor'
  properties: {
    dataConnectorType: 'AzureMonitor'
    dataSource: subscription().id
    extendedProperties: {
      armResourceId: subscription().id
      lookbackDays: 7
    }
    identity: 'system'
  }
  dependsOn: [ logAnalyticsConnector ]
}

// ---------- Let the lab user administer the agent ----------
var sreAgentAdministratorRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

resource adminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminPrincipalId)) {
  name: guid(agent.id, adminPrincipalId, sreAgentAdministratorRoleId)
  scope: agent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdministratorRoleId)
    principalId: adminPrincipalId
    principalType: adminPrincipalType
  }
}

output agentName string = agent.name
output portalUrl string = 'https://sre.azure.com/#/agent/${subscription().subscriptionId}/${resourceGroup().name}/${agent.name}'
