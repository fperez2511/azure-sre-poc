// Azure Cosmos DB for NoSQL – system of record for offerings and bookings.
//
// Reliability choices (WAF):
//   - Session consistency (read-your-writes for a customer, cheapest multi-region option)
//   - Service-managed failover enabled, optional second region (RE:05 redundancy)
//   - Continuous backup, 7-day tier (point-in-time restore; backup storage is free) (RE:09)
//   - Entra ID only (disableLocalAuth) – no keys to leak or rotate
//   - Container definitions live in data/schema/containers.json (loaded below)
param location string
param tags object
param name string
param enableFreeTier bool
param secondaryLocation string
param throughput int
param appPrincipalId string
param userPrincipalId string
param logAnalyticsWorkspaceId string

@description('Database name used by the API.')
param databaseName string = 'coaching'

var containerDefs = loadJsonContent('../../data/schema/containers.json')

var primaryLocation = [
  {
    locationName: location
    failoverPriority: 0
    isZoneRedundant: false // zone redundancy multiplies RU cost; enable it for production
  }
]
var extraLocations = empty(secondaryLocation) ? [] : [
  {
    locationName: secondaryLocation
    failoverPriority: 1
    isZoneRedundant: false
  }
]

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: name
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: enableFreeTier
    locations: concat(primaryLocation, extraLocations)
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    enableAutomaticFailover: true
    enableMultipleWriteLocations: false // Chaos Studio's failover fault needs a single write region
    disableLocalAuth: true
    disableKeyBasedMetadataWriteAccess: true
    publicNetworkAccess: 'Enabled' // private endpoints cost extra; access is still Entra-ID-only
    minimalTlsVersion: 'Tls12'
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: {
        tier: 'Continuous7Days'
      }
    }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: { id: databaseName }
    options: { throughput: throughput } // shared by all containers in the database
  }
}

resource containers 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = [
  for c in containerDefs: {
    parent: database
    name: c.name
    properties: {
      resource: {
        id: c.name
        partitionKey: {
          paths: [ c.partitionKeyPath ]
          kind: 'Hash'
          version: 2
        }
        indexingPolicy: c.indexingPolicy
        defaultTtl: c.defaultTtl
      }
    }
  }
]

// Built-in "Cosmos DB Built-in Data Contributor" data-plane role.
var dataContributorRoleId = '00000000-0000-0000-0000-000000000002'

resource appDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: account
  name: guid(account.id, appPrincipalId, dataContributorRoleId)
  properties: {
    roleDefinitionId: '${account.id}/sqlRoleDefinitions/${dataContributorRoleId}'
    principalId: appPrincipalId
    scope: account.id
  }
}

// The person running the labs gets data access too, so `data/seed.py` and `data/query.py` work.
resource userDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = if (!empty(userPrincipalId)) {
  parent: account
  name: guid(account.id, userPrincipalId, dataContributorRoleId)
  properties: {
    roleDefinitionId: '${account.id}/sqlRoleDefinitions/${dataContributorRoleId}'
    principalId: userPrincipalId
    scope: account.id
  }
}

// Resource logs: data-plane requests (status codes, RU charge, latency) and control-plane
// events (failovers, region changes). The daily cap on the workspace bounds the cost.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: account
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'DataPlaneRequests', enabled: true }
      { category: 'ControlPlaneRequests', enabled: true }
    ]
  }
}

// Region display names ("East US 2") in failover-priority order – the SDK's preferred
// regions and Chaos Studio's failover fault both expect display names.
var orderedPolicies = sort(account.properties.failoverPolicies, (a, b) => a.failoverPriority < b.failoverPriority)

output id string = account.id
output name string = account.name
output endpoint string = account.properties.documentEndpoint
output databaseName string = database.name
output regionDisplayNames string = join(map(orderedPolicies, p => p.locationName), ',')
output secondaryRegionDisplayName string = empty(secondaryLocation) ? '' : (first(filter(orderedPolicies, p => p.failoverPriority == 1)).?locationName ?? '')
