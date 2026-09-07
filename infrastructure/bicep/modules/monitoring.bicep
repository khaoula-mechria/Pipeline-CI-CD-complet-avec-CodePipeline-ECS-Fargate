// ==============================================================================
// monitoring.bicep
//
// Log Analytics Workspace - direct equivalent of the CloudWatch Logs role
// played by the various log groups in ecs-task-definition.yaml/codebuild.yaml
// (30-day retention, matching F4 verbatim). This is also the log
// destination wired into the Container Apps environment in
// container-platform.bicep, which is how container stdout/stderr
// (ContainerAppConsoleLogs table) and platform events
// (ContainerAppSystemLogs table) end up here automatically - no separate
// "log group per resource" concept exists in Azure the way CloudWatch
// requires one log group per CodeBuild project / ECS task family.
//
// Application Insights is deliberately NOT created by default
// (enableAppInsights = false). The application exposes only /health and
// /version - there is no request flow complex enough to justify APM-style
// distributed tracing yet. Flip the parameter on later if the app grows
// enough real business logic to make request-level tracing valuable; nothing
// else in this module needs to change.
// ==============================================================================

@description('Project name, used as a resource naming prefix (lowercase).')
param projectName string

@description('Target environment (dev, staging, prod).')
param environment string

@description('Azure region.')
param location string

@description('Log retention, in days - F4 of the requirements specifies 30.')
param retentionInDays int = 30

@description('Create an Application Insights resource wired to the same workspace. Off by default - see module header.')
param enableAppInsights bool = false

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${projectName}-${environment}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (enableAppInsights) {
  name: 'appi-${projectName}-${environment}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output logAnalyticsCustomerId string = logAnalyticsWorkspace.properties.customerId
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
output appInsightsConnectionString string = enableAppInsights ? appInsights.properties.ConnectionString : ''
