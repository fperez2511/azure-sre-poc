// Azure Chaos Studio experiments (WAF RE:08 – test for resiliency with chaos engineering).
//
// Uses the Experiments (classic) resource model because it is GA and fully deployable
// with Bicep. Chaos Studio Workspaces (the newer model, in preview) is covered as an
// optional lab in the README.
//
// Container Apps has no native Chaos Studio fault, so we fault its *dependency path*:
//   1. cosmos-blackout : NSG rule on the Container Apps subnet denies outbound traffic to
//                        the AzureCosmosDB service tag  -> "database unreachable".
//   2. cosmos-failover : Cosmos DB write region fails over to the secondary region
//                        (only created when a secondary region is configured).
// App-level faults (latency, errors, crash) are injected via scripts/inject-fault.sh.
param location string
param tags object
param token string
param nsgName string
param cosmosAccountName string
param cosmosSecondaryRegionDisplayName string
param faultDuration string

@description('Service tag to block. Use a regional tag such as AzureCosmosDB.EastUS2 to black out only one Cosmos DB region.')
param blockedServiceTag string = 'AzureCosmosDB'

var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'
var cosmosDbOperatorRoleId = '230815da-be43-4aae-9cb4-875f7bd000aa'
var deployFailover = !empty(cosmosSecondaryRegionDisplayName)

// =============================================================================
// Experiment 1 – Cosmos DB network blackout (NSG fault)
// =============================================================================
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = {
  name: nsgName
}

// Onboard the NSG as a Chaos Studio target and enable only the capability we use
// (least privilege: nothing else can be faulted on this resource).
resource nsgTarget 'Microsoft.Chaos/targets@2024-01-01' = {
  name: 'Microsoft-NetworkSecurityGroup'
  scope: nsg
  properties: {}
}

resource nsgCapability 'Microsoft.Chaos/targets/capabilities@2024-01-01' = {
  parent: nsgTarget
  name: 'SecurityRule-1.0'
}

resource blackout 'Microsoft.Chaos/experiments@2024-01-01' = {
  name: 'exp-cosmos-blackout-${token}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    selectors: [
      {
        type: 'List'
        id: 'aca-subnet-nsg'
        targets: [
          {
            type: 'ChaosTarget'
            id: nsgTarget.id
          }
        ]
      }
    ]
    steps: [
      {
        name: 'Block egress to Cosmos DB'
        branches: [
          {
            name: 'nsg-deny-cosmos'
            actions: [
              {
                type: 'continuous'
                name: 'urn:csci:microsoft:networkSecurityGroup:securityRule/1.0'
                duration: faultDuration
                selectorId: 'aca-subnet-nsg'
                parameters: [
                  { key: 'name', value: 'chaos-deny-cosmos' }
                  { key: 'protocol', value: 'Any' }
                  { key: 'sourceAddresses', value: '["*"]' }
                  { key: 'destinationAddresses', value: '["${blockedServiceTag}"]' }
                  // The fault library table names this key "action"; one sample in the docs uses
                  // "access". If the experiment fails validation, see README > Troubleshooting.
                  { key: 'action', value: 'Deny' }
                  { key: 'destinationPortRanges', value: '["*"]' }
                  { key: 'sourcePortRanges', value: '["*"]' }
                  { key: 'priority', value: '100' }
                  { key: 'direction', value: 'Outbound' }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
  dependsOn: [ nsgCapability ]
}

// The experiment's managed identity is the blast-radius boundary: it can modify this NSG only.
resource blackoutRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(nsg.id, blackout.id, networkContributorRoleId)
  scope: nsg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: blackout.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// Experiment 2 – Cosmos DB regional failover (requires a secondary region)
// =============================================================================
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosAccountName
}

resource cosmosTarget 'Microsoft.Chaos/targets@2024-01-01' = if (deployFailover) {
  name: 'Microsoft-CosmosDB'
  scope: cosmos
  properties: {}
}

resource cosmosCapability 'Microsoft.Chaos/targets/capabilities@2024-01-01' = if (deployFailover) {
  parent: cosmosTarget
  name: 'Failover-1.0'
}

resource failover 'Microsoft.Chaos/experiments@2024-01-01' = if (deployFailover) {
  name: 'exp-cosmos-failover-${token}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    selectors: [
      {
        type: 'List'
        id: 'cosmos-account'
        targets: [
          {
            type: 'ChaosTarget'
            id: cosmosTarget.id
          }
        ]
      }
    ]
    steps: [
      {
        name: 'Fail over the write region'
        branches: [
          {
            name: 'cosmos-failover'
            actions: [
              {
                type: 'continuous'
                name: 'urn:csci:microsoft:cosmosDB:failover/1.0'
                duration: faultDuration
                selectorId: 'cosmos-account'
                parameters: [
                  { key: 'readRegion', value: cosmosSecondaryRegionDisplayName }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
  dependsOn: [ cosmosCapability ]
}

resource failoverRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFailover) {
  name: guid(cosmos.id, 'exp-cosmos-failover', cosmosDbOperatorRoleId)
  scope: cosmos
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosDbOperatorRoleId)
    principalId: failover!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output blackoutExperimentName string = blackout.name
output failoverExperimentName string = deployFailover ? failover!.name : ''
