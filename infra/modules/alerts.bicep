// Alerts = the "detect" part of incident response (WAF RE:10).
// Every fired alert also becomes an incident for Azure SRE Agent (via its Azure Monitor
// incident platform), so severities matter: the response plan in the README routes Sev0–Sev2.
//
// Cost: metric alerts are billed per monitored time series (cents/month each);
// the burn-rate log alert runs every 15 minutes (the cheapest log-alert frequency).
param location string
param tags object
param token string
param appInsightsId string
param logAnalyticsWorkspaceId string
param containerAppId string
param cosmosAccountId string
param actionGroupId string
param enableBurnRateAlert bool

@description('Availability SLO for the booking API, in percent. Drives the burn-rate alert.')
param availabilitySlo string = '99.5'

var metricActions = empty(actionGroupId) ? [] : [ { actionGroupId: actionGroupId } ]

// ---------- Symptom alerts on the user-facing API (Application Insights) ----------
resource failedRequests 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-api-5xx-${token}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Booking API is returning server errors (HTTP 5xx). Users cannot browse or book. Runbook: docs/runbooks/high-error-rate.md'
    severity: 2
    enabled: true
    scopes: [ appInsightsId ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'failed-requests'
          metricNamespace: 'microsoft.insights/components'
          metricName: 'requests/failed'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Count'
        }
      ]
    }
    actions: metricActions
  }
}

resource slowRequests 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-api-latency-${token}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Booking API average server response time is above 1.5 s. Runbook: docs/runbooks/high-latency.md'
    severity: 3
    enabled: true
    scopes: [ appInsightsId ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'avg-duration'
          metricNamespace: 'microsoft.insights/components'
          metricName: 'requests/duration'
          operator: 'GreaterThan'
          threshold: 1500
          timeAggregation: 'Average'
        }
      ]
    }
    actions: metricActions
  }
}

// ---------- Cause alerts on dependencies and platform ----------
resource dependencyFailures 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-dependency-failures-${token}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Calls from the API to its dependencies (Cosmos DB) are failing. Runbook: docs/runbooks/cosmos-dependency-outage.md'
    severity: 2
    enabled: true
    scopes: [ appInsightsId ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'failed-dependencies'
          metricNamespace: 'microsoft.insights/components'
          metricName: 'dependencies/failed'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Count'
          skipMetricValidation: true // metric only exists after the first dependency failure
        }
      ]
    }
    actions: metricActions
  }
}

resource containerRestarts 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-api-restarts-${token}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Booking API replicas are restarting (crash loop or failing liveness probe). Runbook: docs/runbooks/bad-release.md'
    severity: 2
    enabled: true
    scopes: [ containerAppId ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'restarts'
          metricNamespace: 'microsoft.app/containerapps'
          metricName: 'RestartCount'
          operator: 'GreaterThan'
          threshold: 2
          timeAggregation: 'Total'
          skipMetricValidation: true
        }
      ]
    }
    actions: metricActions
  }
}

resource cosmosThrottling 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-cosmos-429-${token}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Cosmos DB is throttling requests (HTTP 429): provisioned RU/s are exhausted. Runbook: docs/runbooks/high-latency.md'
    severity: 3
    enabled: true
    scopes: [ cosmosAccountId ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'throttled'
          metricNamespace: 'Microsoft.DocumentDB/databaseAccounts'
          metricName: 'TotalRequests'
          dimensions: [
            {
              name: 'StatusCode'
              operator: 'Include'
              values: [ '429' ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 10
          timeAggregation: 'Count'
        }
      ]
    }
    actions: metricActions
  }
}

// ---------- SLO alert: multi-window burn rate (fast burn) ----------
// Fires when the last hour consumed error budget 14.4x faster than "sustainable"
// (at that pace a 30-day budget is gone in ~2 days). This is Google SRE's recommended
// page-worthy alert, and the most important one in this repo.
var burnRateQuery = '''
let slo = ${availabilitySlo} / 100.0;
AppRequests
| where AppRoleName == "coaching-api"
| where Url has "/api/"
| summarize total = count(), bad = countif(toint(ResultCode) >= 500)
| extend errorRate = iff(total == 0, 0.0, todouble(bad) / total)
| extend burnRate = errorRate / (1.0 - slo)
| where total >= 20 and burnRate >= 14.4
| project total, bad, errorRate, burnRate
'''

resource burnRate 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (enableBurnRateAlert) {
  name: 'alert-slo-fast-burn-${token}'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'SLO fast burn - booking API availability'
    description: 'Error budget for the ${availabilitySlo}% availability SLO is burning >= 14.4x (1h window). Runbook: docs/runbooks/high-error-rate.md'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [ logAnalyticsWorkspaceId ]
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: replace(burnRateQuery, '\${availabilitySlo}', availabilitySlo)
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: empty(actionGroupId) ? [] : [ actionGroupId ]
    }
  }
}
