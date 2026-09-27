// Observability foundation (WAF RE:10 – continuously monitor system health).
// One Log Analytics workspace for everything + workspace-based Application Insights.
param location string
param tags object
param token string

@description('Daily ingestion cap in GB, as a decimal string (e.g. "0.5").')
param dailyCapGb string

@description('Optional e-mail receiver for the action group.')
param alertEmail string = ''

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${token}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30 // 30 days of retention are included in the ingestion price
    workspaceCapping: {
      dailyQuotaGb: json(dailyCapGb) // cost guardrail – ingestion stops for the day at the cap
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${token}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 30
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmail)) {
  name: 'ag-${token}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'sre-oncall'
    enabled: true
    emailReceivers: [
      {
        name: 'on-call'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

output logAnalyticsWorkspaceId string = law.id
output logAnalyticsWorkspaceName string = law.name
output logAnalyticsCustomerId string = law.properties.customerId
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output appInsightsAppId string = appInsights.properties.AppId
#disable-next-line outputs-should-not-contain-secrets // connection string is an ingestion endpoint, not a credential
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output actionGroupId string = empty(alertEmail) ? '' : actionGroup.id
