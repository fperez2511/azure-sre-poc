// Virtual network for the Container Apps environment.
//
// Why a VNet in a "keep it cheap" lab? The NSG on the Container Apps subnet is the
// lever Chaos Studio pulls to simulate a dependency outage: the chaos experiment
// adds an outbound DENY rule for the AzureCosmosDB service tag. VNets and NSGs are free.
param location string
param tags object
param token string

@description('Address space for the lab VNet.')
param addressPrefix string = '10.40.0.0/16'

@description('Subnet for the Container Apps environment (workload profiles environments need at least a /27).')
param acaSubnetPrefix string = '10.40.0.0/27'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-aca-${token}'
  location: location
  tags: tags
  properties: {
    // Intentionally no custom rules: the Azure default rules allow the outbound traffic
    // Container Apps needs. Chaos Studio adds (and later removes) a temporary DENY rule.
    // Do NOT manage rules here with Bicep while an experiment runs – external changes fail the experiment.
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${token}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ addressPrefix ]
    }
    subnets: [
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: acaSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
          delegations: [
            {
              name: 'aca-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]
  }
}

output acaSubnetId string = vnet.properties.subnets[0].id
output nsgName string = nsg.name
output nsgId string = nsg.id
