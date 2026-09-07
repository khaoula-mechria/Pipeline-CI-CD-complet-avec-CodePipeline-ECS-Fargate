// ==============================================================================
// main.bicep
//
// Entry point - orchestrates every module below in the same dependency order
// the AWS project's 12 CloudFormation stacks used, collapsed to what Azure
// actually needs (see infrastructure/bicep/README.md for the full AWS->Azure
// module mapping). Deploy with:
//
//   az deployment group create \
//     --resource-group rg-taskmanager-dev \
//     --template-file infrastructure/bicep/main.bicep \
//     --parameters infrastructure/bicep/parameters/dev.bicepparam
//
// Unlike the AWS templates (12 independent stacks wired together with
// Fn::ImportValue, deployed one at a time in a documented order), this is a
// SINGLE deployment: Bicep resolves the module dependency graph itself from
// the outputs/inputs wired below, so there is no "deployment order" document
// to keep in sync by hand.
// ==============================================================================

targetScope = 'resourceGroup'

@description('Project name, used as a resource naming prefix (lowercase).')
@minLength(2)
@maxLength(20)
param projectName string = 'taskmanager'

@description('Target environment.')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

@description('Azure region for every resource.')
param location string = resourceGroup().location

@description('Email address for Azure Monitor alerts. Leave empty to skip the subscription (same optional pattern as the AWS AlarmEmail parameter).')
param alertEmail string = ''

@description('Full image reference for the FIRST deployment only. Every deployment after that is driven by the pipeline (scripts/blue-green-deploy.sh), not by re-running this template - see container-platform.bicep header.')
param bootstrapContainerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Create Application Insights alongside Log Analytics. Off by default - see monitoring.bicep header.')
param enableAppInsights bool = false

// Deterministic-but-unique suffix for globally-unique resource names (ACR,
// Key Vault). Derived from the resource group's own resourceId, so it stays
// stable across re-deployments of the SAME resource group instead of
// changing every run (uniqueString() is a pure hash of its inputs, not
// random - this is not the same category of value as newGuid() used for the
// Key Vault secret placeholders in keyvault.bicep).
var uniqueSuffix = uniqueString(resourceGroup().id)

module networking 'modules/networking.bicep' = {
  name: 'networking'
  params: {
    projectName: projectName
    environment: environment
    location: location
  }
}

module identities 'modules/identities.bicep' = {
  name: 'identities'
  params: {
    projectName: projectName
    environment: environment
    location: location
  }
}

module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    projectName: projectName
    environment: environment
    location: location
    pullPrincipalId: identities.outputs.principalId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    privateDnsZoneId: networking.outputs.acrPrivateDnsZoneId
    uniqueSuffix: uniqueSuffix
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyVault'
  params: {
    projectName: projectName
    environment: environment
    location: location
    readPrincipalId: identities.outputs.principalId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    privateDnsZoneId: networking.outputs.kvPrivateDnsZoneId
    uniqueSuffix: uniqueSuffix
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    projectName: projectName
    environment: environment
    location: location
    enableAppInsights: enableAppInsights
  }
}

// Log Analytics primary shared key is a listKeys()-style secret output -
// resolved here (main.bicep) rather than exposed as a monitoring.bicep
// output, keeping module outputs free of secret values wherever avoidable.
resource lawExisting 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'law-${projectName}-${environment}'
  dependsOn: [monitoring]
}

module containerPlatform 'modules/container-platform.bicep' = {
  name: 'containerPlatform'
  params: {
    projectName: projectName
    environment: environment
    location: location
    acaSubnetId: networking.outputs.acaSubnetId
    logAnalyticsCustomerId: monitoring.outputs.logAnalyticsCustomerId
    logAnalyticsSharedKey: lawExisting.listKeys().primarySharedKey
    managedIdentityId: identities.outputs.identityId
    managedIdentityClientId: identities.outputs.clientId
    acrLoginServer: acr.outputs.acrLoginServer
    dbUsernameSecretUri: keyVault.outputs.dbUsernameSecretUri
    dbPasswordSecretUri: keyVault.outputs.dbPasswordSecretUri
    apiKeySecretUri: keyVault.outputs.apiKeySecretUri
    containerImage: bootstrapContainerImage
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  params: {
    projectName: projectName
    environment: environment
    location: location
    containerAppId: containerPlatform.outputs.containerAppId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    alertEmail: alertEmail
  }
}

output containerAppFqdn string = containerPlatform.outputs.containerAppFqdn
output acrLoginServer string = acr.outputs.acrLoginServer
output acrName string = acr.outputs.acrName
output keyVaultName string = keyVault.outputs.keyVaultName
output containerAppName string = containerPlatform.outputs.containerAppName
output managedEnvironmentId string = containerPlatform.outputs.managedEnvironmentId
output managedIdentityClientId string = identities.outputs.clientId
