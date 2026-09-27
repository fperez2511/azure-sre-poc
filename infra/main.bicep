// =============================================================================
// Summit Coaching – SRE learning environment
// Entry point for `azd provision` (subscription scope).
//
// Creates:
//   rg-<env>            workload: Container Apps, Cosmos DB, ACR, monitoring,
//                       VNet/NSG, alerts, Chaos Studio experiments
//   rg-<env>-sreagent   (optional) Azure SRE Agent – kept in its own resource
//                       group so you can delete it (and stop its always-on
//                       billing) with a single command.
//
// Every knob is a parameter so a fork can run in any personal subscription.
// See infra/main.parameters.json for the azd environment variable mapping.
// =============================================================================
targetScope = 'subscription'

// ---------- Core ----------
@minLength(1)
@maxLength(20)
@description('Name of the azd environment. Used to name resource groups and derive a unique suffix.')
param environmentName string

@minLength(1)
@description('Primary Azure region for the workload (must support Container Apps, Cosmos DB and Chaos Studio, e.g. eastus2, swedencentral, uksouth).')
param location string

@description('Object ID of the person (or CI service principal) running the deployment. Gets Cosmos DB data access (to seed data) and SRE Agent admin rights.')
param principalId string = ''

@allowed([ 'User', 'ServicePrincipal' ])
@description('Type of principalId. Use ServicePrincipal when deploying from CI.')
param principalType string = 'User'

// ---------- App ----------
@description('Container image for the API. azd fills this in after the first `azd deploy`; leave empty on the very first provision (a placeholder image is used).')
param apiImage string = ''

@description('Set by azd (SERVICE_API_RESOURCE_EXISTS). When true and apiImage is empty, the currently running image is kept.')
param apiExists bool = false

@minValue(0)
@maxValue(10)
@description('Minimum replicas. 0 = scale to zero (cheapest). Use 2+ during reliability labs so one replica can fail without an outage.')
param minReplicas int = 0

@minValue(1)
@maxValue(10)
@description('Maximum replicas for HTTP autoscaling.')
param maxReplicas int = 3

@description('Spread the Container Apps environment across availability zones. No extra charge on the Consumption profile, but the region must support zones and this cannot be changed after the environment is created.')
param containerAppsZoneRedundant bool = true

// ---------- Data ----------
@description('Use the Cosmos DB free tier (1000 RU/s + 25 GB free). Only ONE free-tier account is allowed per subscription – set false if you already used it.')
param cosmosEnableFreeTier bool = true

@description('Optional secondary region for Cosmos DB (e.g. centralus). Empty = single region. Adding a region enables the Cosmos DB failover chaos experiment.')
param cosmosSecondaryLocation string = ''

@minValue(400)
@description('Shared (database-level) throughput in RU/s. 400 RU/s per region keeps a 2-region free-tier account inside the 1000 RU/s allowance.')
param cosmosThroughput int = 400

// ---------- Observability ----------
@description('Optional e-mail address for alert notifications. Empty = alerts still fire (and reach the SRE Agent) but nobody is e-mailed.')
param alertEmail string = ''

@description('Log Analytics daily ingestion cap in GB (decimal as string). Protects you from a runaway logging bill.')
param logDailyCapGb string = '0.5'

@description('Create the SLO burn-rate log alert (a scheduled query rule, billed monthly per rule).')
param enableBurnRateAlert bool = true

// ---------- Chaos ----------
@description('Create Chaos Studio targets, capabilities and experiments.')
param deployChaos bool = true

@description('Region for Chaos Studio experiment resources. Must be a region where Chaos Studio is available. Defaults to the workload region.')
param chaosLocation string = ''

@description('How long each chaos fault stays active (ISO 8601 duration).')
param chaosFaultDuration string = 'PT10M'

// ---------- SRE Agent ----------
@description('Deploy Azure SRE Agent. OFF by default: an agent is billed 4 AAU per hour for as long as it exists (waived during the 30-day evaluation). Turn on for the SRE Agent labs, then delete it.')
param deploySreAgent bool = false

@allowed([
  'australiaeast'
  'canadacentral'
  'eastus2'
  'francecentral'
  'italynorth'
  'koreacentral'
  'southafricanorth'
  'southeastasia'
  'swedencentral'
  'uksouth'
])
@description('Region for the SRE Agent itself (supported regions only). It can manage resources in any region.')
param sreAgentLocation string = 'eastus2'

@allowed([ 'Low', 'High' ])
@description('Low = Reader-style access (investigate only). High = adds Contributor on the workload resource group so the agent can mitigate (e.g. roll back a revision).')
param sreAgentAccessLevel string = 'High'

@allowed([ 'Review', 'Automatic' ])
@description('Review = a human approves every write action (recommended for learning).')
param sreAgentActionMode string = 'Review'

@minValue(500)
@description('Monthly cap on active-flow AAUs (minimum 500). When reached, the agent stops chatting/acting until next month.')
param sreAgentMonthlyAauLimit int = 500

// ---------- Naming ----------
var token = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  workload: 'summit-coaching'
  purpose: 'sre-learning'
}
var workloadRgName = 'rg-${environmentName}'
var sreAgentRgName = 'rg-${environmentName}-sreagent'
var effectiveChaosLocation = empty(chaosLocation) ? location : chaosLocation

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: workloadRgName
  location: location
  tags: tags
}

resource sreRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deploySreAgent) {
  name: sreAgentRgName
  location: sreAgentLocation
  tags: tags
}

// ---------- Workload modules ----------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
    token: token
    dailyCapGb: logDailyCapGb
    alertEmail: alertEmail
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  scope: rg
  params: {
    location: location
    tags: tags
    name: 'id-api-${token}'
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    location: location
    tags: tags
    token: token
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  scope: rg
  params: {
    location: location
    tags: tags
    name: 'cr${token}'
    pullPrincipalId: identity.outputs.principalId
  }
}

module cosmos 'modules/cosmos.bicep' = {
  name: 'cosmos'
  scope: rg
  params: {
    location: location
    tags: tags
    name: 'cosmos-${token}'
    enableFreeTier: cosmosEnableFreeTier
    secondaryLocation: cosmosSecondaryLocation
    throughput: cosmosThroughput
    appPrincipalId: identity.outputs.principalId
    userPrincipalId: principalId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

// Keep whatever image is already running when re-provisioning (e.g. from CI, where the azd
// environment does not know SERVICE_API_IMAGE_NAME).
var apiAppName = 'ca-api-${token}'

module fetchApiImage 'modules/fetch-container-image.bicep' = {
  name: 'fetch-api-image'
  scope: rg
  params: {
    exists: apiExists
    name: apiAppName
  }
}

var resolvedApiImage = !empty(apiImage) ? apiImage : (apiExists ? fetchApiImage.outputs.containers[0].image : '')

module app 'modules/containerapps.bicep' = {
  name: 'containerapps'
  scope: rg
  params: {
    location: location
    tags: tags
    token: token
    appName: apiAppName
    subnetId: network.outputs.acaSubnetId
    zoneRedundant: containerAppsZoneRedundant
    logAnalyticsWorkspaceName: monitoring.outputs.logAnalyticsWorkspaceName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    identityId: identity.outputs.id
    identityClientId: identity.outputs.clientId
    registryLoginServer: registry.outputs.loginServer
    image: resolvedApiImage
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    cosmosEndpoint: cosmos.outputs.endpoint
    cosmosDatabase: cosmos.outputs.databaseName
    cosmosPreferredRegions: cosmos.outputs.regionDisplayNames
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  scope: rg
  params: {
    location: location
    tags: tags
    token: token
    appInsightsId: monitoring.outputs.appInsightsId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    containerAppId: app.outputs.appId
    cosmosAccountId: cosmos.outputs.id
    actionGroupId: monitoring.outputs.actionGroupId
    enableBurnRateAlert: enableBurnRateAlert
  }
}

module chaos 'modules/chaos.bicep' = if (deployChaos) {
  name: 'chaos'
  scope: rg
  params: {
    location: effectiveChaosLocation
    tags: tags
    token: token
    nsgName: network.outputs.nsgName
    cosmosAccountName: cosmos.outputs.name
    cosmosSecondaryRegionDisplayName: cosmos.outputs.secondaryRegionDisplayName
    faultDuration: chaosFaultDuration
  }
}

// ---------- Optional: Azure SRE Agent ----------
module sreAgent 'modules/sre-agent.bicep' = if (deploySreAgent) {
  name: 'sre-agent'
  scope: sreRg
  params: {
    location: sreAgentLocation
    tags: tags
    agentName: 'sre-${environmentName}'
    workloadResourceGroupName: rg.name
    accessLevel: sreAgentAccessLevel
    actionMode: sreAgentActionMode
    monthlyAgentUnitLimit: sreAgentMonthlyAauLimit
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsAppId: monitoring.outputs.appInsightsAppId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    adminPrincipalId: principalId
    adminPrincipalType: principalType
  }
}

// ---------- Outputs (become azd environment values) ----------
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = registry.outputs.name
output SERVICE_API_NAME string = app.outputs.appName
output SERVICE_API_URI string = app.outputs.uri
output CONTAINER_APPS_ENVIRONMENT_NAME string = app.outputs.environmentName
output COSMOS_ACCOUNT_NAME string = cosmos.outputs.name
output COSMOS_ENDPOINT string = cosmos.outputs.endpoint
output COSMOS_DATABASE string = cosmos.outputs.databaseName
output APPLICATIONINSIGHTS_NAME string = monitoring.outputs.appInsightsName
output LOG_ANALYTICS_WORKSPACE_NAME string = monitoring.outputs.logAnalyticsWorkspaceName
output LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID string = monitoring.outputs.logAnalyticsCustomerId
output NSG_NAME string = network.outputs.nsgName
output CHAOS_EXPERIMENT_COSMOS_BLACKOUT string = deployChaos ? chaos!.outputs.blackoutExperimentName : ''
output CHAOS_EXPERIMENT_COSMOS_FAILOVER string = deployChaos ? chaos!.outputs.failoverExperimentName : ''
output SRE_AGENT_RESOURCE_GROUP string = deploySreAgent ? sreAgentRgName : ''
output SRE_AGENT_NAME string = deploySreAgent ? sreAgent!.outputs.agentName : ''
output SRE_AGENT_PORTAL_URL string = deploySreAgent ? sreAgent!.outputs.portalUrl : ''
