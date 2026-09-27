// Azure Container Apps: environment (VNet-integrated, zone-redundant) + the booking API.
//
// Reliability choices (WAF):
//   - Health probes: startup + liveness (process is alive) + readiness (can serve).
//     Readiness deliberately does NOT check Cosmos DB – if a shared dependency failed,
//     every replica would be pulled out of rotation and a partial outage becomes a total one.
//   - Single revision mode: a new revision only receives traffic once it is healthy,
//     so a broken release never replaces a working one (see Lab 8).
//   - HTTP-concurrency autoscaling between minReplicas and maxReplicas (RE:06).
param location string
param tags object
param token string
param appName string
param subnetId string
param zoneRedundant bool
param logAnalyticsWorkspaceName string
@secure()
param appInsightsConnectionString string
param identityId string
param identityClientId string
param registryLoginServer string
param image string
param minReplicas int
param maxReplicas int
param cosmosEndpoint string
param cosmosDatabase string
param cosmosPreferredRegions string

@description('Concurrent HTTP requests per replica before scaling out.')
param concurrentRequestsPerReplica int = 30

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${token}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: subnetId
      internal: false
    }
    zoneRedundant: zoneRedundant
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// Before the first `azd deploy` there is no image in ACR yet, so provision a public
// placeholder that also listens on 8080 but has no /healthz endpoints, hence no probes.
// `azd deploy` only swaps the image; the NEXT `azd provision` adds the probes (see README, Lab 1).
var usePlaceholder = empty(image)
var containerImage = usePlaceholder ? 'mcr.microsoft.com/dotnet/samples:aspnetapp' : image

var probes = usePlaceholder ? [] : [
  {
    type: 'Startup'
    httpGet: { path: '/healthz/live', port: 8080 }
    initialDelaySeconds: 1
    periodSeconds: 3
    failureThreshold: 10
    timeoutSeconds: 2
  }
  {
    type: 'Liveness'
    httpGet: { path: '/healthz/live', port: 8080 }
    periodSeconds: 10
    failureThreshold: 3
    timeoutSeconds: 2
  }
  {
    type: 'Readiness'
    httpGet: { path: '/healthz/ready', port: 8080 }
    periodSeconds: 5
    failureThreshold: 3
    timeoutSeconds: 2
  }
]

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: union(tags, { 'azd-service-name': 'api' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      maxInactiveRevisions: 20 // keep history so you can roll back with `az containerapp revision copy`
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: registryLoginServer
          identity: identityId
        }
      ]
      secrets: [
        {
          name: 'appinsights-connection-string'
          value: appInsightsConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'COSMOS_ENDPOINT', value: cosmosEndpoint }
            { name: 'COSMOS_DATABASE', value: cosmosDatabase }
            { name: 'COSMOS_PREFERRED_REGIONS', value: cosmosPreferredRegions }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
            // Fault-injection switches used by scripts/inject-fault.sh. Changing any of them
            // creates a new revision – exactly like a real (bad) configuration release.
            { name: 'FAULT_LATENCY_MS', value: '0' }
            { name: 'FAULT_ERROR_RATE', value: '0' }
            { name: 'FAULT_CRASH_ON_STARTUP', value: 'false' }
          ]
          probes: probes
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: {
              metadata: {
                concurrentRequests: string(concurrentRequestsPerReplica)
              }
            }
          }
        ]
      }
    }
  }
}

output appId string = app.id
output appName string = app.name
output uri string = 'https://${app.properties.configuration.ingress.fqdn}'
output environmentName string = env.name
