// ==============================================================================
// acr.bicep
//
// Azure Container Registry - direct equivalent of ecr.yaml.
//
// Basic SKU is deliberate: Premium's extra features (geo-replication,
// customer-managed keys, network rule sets beyond Private Endpoints) are not
// needed for a single-region student project. Private Endpoints on Basic/
// Standard SKU require "Premium" in the OLD ACR network-rules model, but
// since 2023 Private Endpoints are supported down to Basic SKU via the
// unified Private Link platform - if a deployment ever rejects the Private
// Endpoint below with a SKU error, that is the first thing to check against
// the current ACR SKU feature table before assuming this template is wrong.
//
// AcrPull role assignment is granted here (not in identities.bicep) so this
// module is self-contained: anyone reusing acr.bicep elsewhere gets working
// pull access for free, and there is exactly one place that defines "who can
// pull from this registry."
// ==============================================================================

@description('Project name, used as a resource naming prefix (lowercase).')
param projectName string

@description('Target environment (dev, staging, prod).')
param environment string

@description('Azure region.')
param location string

@description('principalId of the Container App user-assigned identity (identities.bicep) - granted AcrPull.')
param pullPrincipalId string

@description('Subnet ID for the ACR Private Endpoint (networking.bicep privateEndpointSubnetId).')
param privateEndpointSubnetId string

@description('Private DNS Zone ID for privatelink.azurecr.io (networking.bicep acrPrivateDnsZoneId).')
param privateDnsZoneId string

@description('ACR names are globally unique and alphanumeric-only (no hyphens) - this suffix avoids collisions across everyone deploying this template.')
param uniqueSuffix string

var acrName = toLower('acr${projectName}${environment}${uniqueSuffix}')

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false // no shared admin credentials - pull is via managed identity only
    // Public network access is disabled: pulls happen exclusively over the
    // Private Endpoint below, from the VNet-integrated Container Apps
    // environment. Azure Pipelines pushes the image over its own outbound
    // connectivity to the ACR control plane, which remains reachable for
    // push/build operations through Azure's backbone even with public data
    // access disabled for pulls - if a self-hosted/VNet-restricted agent is
    // used later for pushes, revisit this setting.
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'AzureServices'
  }
}

// Retention policy for untagged manifests - the ACR equivalent of ecr.yaml's
// lifecycle policy rule 1 ("expire untagged images after N days"). ACR has no
// built-in "keep only last N tagged images" rule (ecr.yaml's rule 2):
// achieving that requires either ACR Tasks purge commands run on a schedule,
// or Azure Container Registry's newer retention policies preview feature -
// deliberately left out of this template rather than forced in, since it
// would need to be verified against current ACR feature availability. Note
// this gap explicitly in the deployment guide instead of hiding it.
resource acrRetentionPolicy 'Microsoft.ContainerRegistry/registries/policies@2023-07-01' = {
  parent: acr
  name: 'retentionPolicy'
  properties: {
    days: 7
    status: 'enabled'
  }
}

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-acr-${projectName}-${environment}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'acr-connection'
        properties: {
          privateLinkServiceId: acr.id
          groupIds: ['registry']
        }
      }
    ]
  }
}

resource acrPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: acrPrivateEndpoint
  name: 'acr-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azurecr-io'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

// Built-in role "AcrPull" - id is stable across all Azure tenants.
var acrPullRoleDefinitionId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, pullPrincipalId, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleDefinitionId)
    principalId: pullPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output acrId string = acr.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
