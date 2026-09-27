// User-assigned managed identity for the API.
// Used to pull images from ACR and to call Cosmos DB with Entra ID (no keys anywhere).
param location string
param tags object
param name string

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

output id string = uami.id
output principalId string = uami.properties.principalId
output clientId string = uami.properties.clientId
