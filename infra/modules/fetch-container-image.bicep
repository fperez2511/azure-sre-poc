// Reads the image currently running in an existing container app.
// Lets `azd provision` (locally or in CI) re-apply the infrastructure WITHOUT reverting the app
// to the placeholder image. azd sets SERVICE_API_RESOURCE_EXISTS automatically.
param exists bool
param name string

resource existingApp 'Microsoft.App/containerApps@2024-03-01' existing = if (exists) {
  name: name
}

output containers array = exists ? existingApp!.properties.template.containers : []
