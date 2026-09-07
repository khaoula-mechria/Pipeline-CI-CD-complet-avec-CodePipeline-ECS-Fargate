// ==============================================================================
// alerts.bicep
//
// Azure Monitor alerting - equivalent of the CloudWatch alarms scattered
// across ecs-autoscaling.yaml and observability.yml, consolidated here into
// one module since Azure doesn't need a separate stack-ordering trick to
// avoid circular SNS-topic dependencies the way pipeline.yml did.
//
// Deliberately NOT included here: a "deployment failure" alert wired through
// Azure Monitor. Azure Pipelines already has a native, no-code notification
// for pipeline/stage failure (Project Settings > Notifications, or a
// per-pipeline "Email" step) - building a custom metric-push-and-alert
// pipeline to replicate what observability.yml's Lambda had to do (because
// CodePipeline itself emits no duration/success metric) would be solving a
// problem Azure DevOps doesn't have. See infrastructure/bicep/README.md.
//
// VERIFY BEFORE RELYING ON THIS MODULE: the exact metric names
// (CpuPercentage, MemoryPercentage, Replicas) for Microsoft.App/containerApps
// are believed correct as of this writing but MUST be confirmed with:
//   az monitor metrics list-definitions --resource <containerAppId>
// before treating these alerts as validated. This is flagged explicitly
// rather than silently assumed, per the project's "do not hallucinate Azure
// features" rule.
// ==============================================================================

@description('Project name, used as a resource naming prefix (lowercase).')
param projectName string

@description('Target environment (dev, staging, prod).')
param environment string

@description('Azure region.')
param location string

@description('Container App resource ID to monitor (container-platform.bicep containerAppId).')
param containerAppId string

@description('Log Analytics workspace ID, for the log-based error-rate alert (monitoring.bicep logAnalyticsWorkspaceId).')
param logAnalyticsWorkspaceId string

@description('Email address for alert notifications. Leave empty to create the Action Group without a subscriber (add one later via az monitor action-group update, same "optional at deploy time" pattern as observability.yml AlarmEmail).')
param alertEmail string = ''

@description('CPU % threshold - mirrors ecs-autoscaling.yaml HighCpuAlarmThreshold (85 by default, intentionally above the 70% scaling target).')
param cpuAlarmThreshold int = 85

@description('Memory % threshold.')
param memoryAlarmThreshold int = 85

var hasAlertEmail = !empty(alertEmail)

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${projectName}-${environment}'
  location: 'global'
  properties: {
    groupShortName: take('${projectName}${environment}', 12)
    enabled: true
    emailReceivers: hasAlertEmail ? [
      {
        name: 'primary-email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ] : []
  }
}

resource highCpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${projectName}-${environment}-cpu-high'
  location: 'global'
  properties: {
    description: 'Average CPU above ${cpuAlarmThreshold}% for 5 minutes - equivalent of ecs-autoscaling.yaml ServiceHighCpuAlarm.'
    severity: 2
    enabled: true
    scopes: [containerAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCpu'
          metricName: 'CpuPercentage'
          metricNamespace: 'Microsoft.App/containerApps'
          operator: 'GreaterThan'
          threshold: cpuAlarmThreshold
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

resource highMemoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${projectName}-${environment}-memory-high'
  location: 'global'
  properties: {
    description: 'Average memory above ${memoryAlarmThreshold}% for 5 minutes.'
    severity: 2
    enabled: true
    scopes: [containerAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighMemory'
          metricName: 'MemoryPercentage'
          metricNamespace: 'Microsoft.App/containerApps'
          operator: 'GreaterThan'
          threshold: memoryAlarmThreshold
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// "Application unavailable" - fires when the running replica count drops to
// zero for a sustained period (min-replicas is normally >= 1, so a
// sustained 0 means every replica is failing to start or failing its
// readiness probe, not a scale-to-zero event).
resource unavailableAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${projectName}-${environment}-app-unavailable'
  location: 'global'
  properties: {
    description: 'Replica count at 0 for 5 minutes - the application is not serving traffic.'
    severity: 0
    enabled: true
    scopes: [containerAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'NoReplicas'
          metricName: 'Replicas'
          metricNamespace: 'Microsoft.App/containerApps'
          operator: 'LessThanOrEqual'
          threshold: 0
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// High error rate - log-based (Scheduled Query Rule / "log alert v2") rather
// than a platform metric, because ACA does not expose an HTTP-status-code
// dimension on a platform metric the way AWS/ApplicationELB's HTTPCode_*
// metrics did. Queries the ContainerAppConsoleLogs table that
// container-platform.bicep's Log Analytics destination populates
// automatically. ADAPT the "Log_s contains" filter to your actual log format
// - this is a starting point, not a guarantee it matches your app's real
// stdout structure.
resource highErrorRateAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${projectName}-${environment}-high-error-rate'
  location: location
  properties: {
    displayName: 'High error rate (${projectName}-${environment})'
    description: 'More than 10 error-level log lines in a 5-minute window.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [logAnalyticsWorkspaceId]
    criteria: {
      allOf: [
        {
          query: 'ContainerAppConsoleLogs_CL | where ContainerAppName_s == "ca-${projectName}-${environment}" | where Log_s contains "error" or Log_s contains "Error" | summarize ErrorCount = count()'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 10
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

output actionGroupId string = actionGroup.id
