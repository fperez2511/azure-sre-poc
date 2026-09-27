// Role assignments that define what the SRE Agent can see and do in the workload RG.
//   Always : Reader, Monitoring Reader, Log Analytics Reader  -> investigate
//   High   : + Contributor                                    -> mitigate (restart, roll back, scale)
// In Review mode every write action still needs a human approval in the agent's chat.
param principalId string

@allowed([ 'Low', 'High' ])
param accessLevel string

var roles = concat(
  [
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    '43d0d8ad-25c7-4714-9337-8ba259a9fe05' // Monitoring Reader
    '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Reader
  ],
  accessLevel == 'High' ? [ 'b24988ac-6180-42a0-ab88-20f7382dd24c' ] : [] // Contributor
)

resource assignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in roles: {
    name: guid(resourceGroup().id, principalId, roleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]
