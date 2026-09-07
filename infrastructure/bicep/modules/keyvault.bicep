// ==============================================================================
// keyvault.bicep
//
// Azure Key Vault - direct equivalent of secrets-manager.yaml.
//
// Same discipline as the AWS version: no secret VALUE ever appears as a
// plain literal in this template. The DB password and API key placeholder
// use secure parameters whose default is newGuid() - a value generated fresh
// by Azure at each deployment, never written to source control, mirroring
// Secrets Manager's GenerateSecretString. Exactly like the AWS version's
// comment on ApiKeySecret, the real third-party API key value is expected to
// be pushed once, out of band, after this stack deploys:
//   az keyvault secret set --vault-name <name> --name api-key --value <REAL_KEY>
//
// RBAC authorization mode (not access policies) is used because it is the
// current Microsoft-recommended model and composes cleanly with the same
// Azure RBAC role-assignment pattern used for ACR in acr.bicep - one
// permission model across the whole project instead of two.
// ==============================================================================

@description('Project name, used as a resource naming prefix (lowercase).')
param projectName string

@description('Target environment (dev, staging, prod).')
param environment string

@description('Azure region.')
param location string

@description('Azure AD tenant ID that owns this Key Vault.')
param tenantId string = subscription().tenantId

@description('principalId of the Container App user-assigned identity (identities.bicep) - granted Key Vault Secrets User.')
param readPrincipalId string

@description('Subnet ID for the Key Vault Private Endpoint (networking.bicep privateEndpointSubnetId).')
param privateEndpointSubnetId string

@description('Private DNS Zone ID for privatelink.vaultcore.azure.net (networking.bicep kvPrivateDnsZoneId).')
param privateDnsZoneId string

@description('Application DB username - not sensitive on its own, stored alongside the generated password so the app has one source to read (same reasoning as secrets-manager.yaml DbSecret).')
param dbUsername string = 'taskmanager_app'

@secure()
@description('Placeholder DB password, generated fresh at deploy time by Azure - never stored in source. Never override this with a literal value.')
param dbPasswordSeed string = newGuid()

@secure()
@description('Placeholder API key, generated fresh at deploy time. Replace the real value post-deploy via az keyvault secret set, exactly as documented for the AWS ApiKeySecret.')
param apiKeySeed string = newGuid()

@description('Key Vault names are globally unique, max 24 chars.')
param uniqueSuffix string

var kvName = toLower('kv-${take(projectName, 8)}-${environment}-${uniqueSuffix}')

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7 // shortest allowed - keeps teardown between test cycles cheap and fast, same intent as the AWS recovery-window discussion in project notes
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource dbSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'db-username'
  properties: {
    value: dbUsername
  }
}

resource dbPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'db-password'
  properties: {
    value: dbPasswordSeed
  }
}

resource apiKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'api-key'
  properties: {
    value: apiKeySeed
  }
}

resource kvPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-kv-${projectName}-${environment}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'kv-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource kvPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: kvPrivateEndpoint
  name: 'kv-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

// Built-in role "Key Vault Secrets User" - read-only GetSecret/ListSecret,
// the direct analog of EcsTaskExecutionRole's ReadAppSecrets statement
// (secretsmanager:GetSecretValue only, never write/manage).
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, readPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: readPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output dbUsernameSecretUri string = dbSecret.properties.secretUri
output dbPasswordSecretUri string = dbPasswordSecret.properties.secretUri
output apiKeySecretUri string = apiKeySecret.properties.secretUri
