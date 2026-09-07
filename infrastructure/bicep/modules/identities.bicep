// ==============================================================================
// identities.bicep
//
// Single user-assigned managed identity for the Container App.
//
// A user-assigned identity (rather than the Container App's own
// system-assigned identity) is used deliberately: role assignments onto ACR
// and Key Vault are created inside acr.bicep / keyvault.bicep, each of which
// needs the identity's principalId as an input BEFORE the Container App
// itself exists (container-platform.bicep is deployed after them). A
// system-assigned identity does not exist until its parent resource is
// created, which would force a circular module dependency. A user-assigned
// identity has its own lifecycle and solves this cleanly - this is the direct
// analog of AWS's EcsTaskExecutionRole existing independently of the ECS
// service that references it (iam.yaml deploys before ecs-service.yaml).
// ==============================================================================

@description('Project name, used as a resource naming prefix (lowercase).')
param projectName string

@description('Target environment (dev, staging, prod).')
param environment string

@description('Azure region.')
param location string

resource containerAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${projectName}-${environment}'
  location: location
}

output identityId string = containerAppIdentity.id
output principalId string = containerAppIdentity.properties.principalId
output clientId string = containerAppIdentity.properties.clientId
