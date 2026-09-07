// ==============================================================================
// networking.bicep
//
// VNet integration for the Container Apps environment.
//
// Deliberately NOT a copy of the AWS vpc.yml topology (2 AZ / 4 subnets / IGW /
// NAT Gateway). Azure Container Apps' managed environment already handles
// availability-zone distribution internally, so this module only needs to
// provide:
//   - one subnet, delegated to Microsoft.App/environments, for the ACA
//     environment to inject itself into (this replaces the role AWS's
//     *private* subnets played for Fargate tasks)
//   - a Network Security Group on that subnet
//   - Private DNS Zones + the subnet's link into them, so acr.bicep and
//     keyvault.bicep can attach Private Endpoints
//
// No NAT Gateway resource is created here. Outbound traffic uses the
// platform's default SNAT. This is a deliberate divergence from the AWS
// design: the NAT Gateway was one of the two dominant hourly costs in the
// original AWS deployment (see project memory / guideme2.md), and nothing in
// this application calls a third party that requires an allow-listed static
// egress IP. If that ever changes, add a Microsoft.Network/natGateways
// resource and associate it with the subnet below - everything else in this
// module stays the same.
// ==============================================================================

@description('Project name, used as a resource naming prefix (lowercase).')
param projectName string

@description('Target environment (dev, staging, prod).')
param environment string

@description('Azure region for all resources in this module.')
param location string

@description('VNet address space.')
param vnetCidr string = '10.0.0.0/16'

@description('Subnet delegated to Microsoft.App/environments. Sized generously (/23) because Workload Profile environments need materially more address space than Consumption-only VNet integration - verify the current minimum in Microsoft Learn before shrinking this.')
param acaSubnetCidr string = '10.0.0.0/23'

var namePrefix = '${projectName}-${environment}'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-aca-${namePrefix}'
  location: location
  properties: {
    // ------------------------------------------------------------------
    // VERIFY BEFORE FIRST DEPLOY: Azure Container Apps requires specific
    // inbound/outbound rules on a delegated VNet-integration subnet for its
    // own management plane traffic (documented under "Provide subnet
    // requirements" / "Network Security Groups" in the Container Apps
    // networking docs). Do not remove or over-restrict this NSG without
    // checking those current required rules first - an incorrectly locked
    // down NSG is a documented cause of environments getting stuck in
    // "Waiting" provisioning state.
    // ------------------------------------------------------------------
    securityRules: [
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowVnetInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-${namePrefix}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetCidr]
    }
    subnets: [
      {
        name: 'snet-aca-${namePrefix}'
        properties: {
          addressPrefix: acaSubnetCidr
          networkSecurityGroup: {
            id: nsg.id
          }
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        // Dedicated subnet for Private Endpoints (ACR, Key Vault): kept
        // separate from the delegated ACA subnet because a subnet with a
        // service delegation cannot also host Private Endpoint NICs.
        name: 'snet-pe-${namePrefix}'
        properties: {
          addressPrefix: cidrSubnet(vnetCidr, 24, 2)
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource acaSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: 'snet-aca-${namePrefix}'
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: 'snet-pe-${namePrefix}'
}

// ------------------------------------------------------------------------
// PRIVATE DNS ZONES for the two Private Endpoints this project needs
// (ACR, Key Vault). acr.bicep / keyvault.bicep create the endpoints
// themselves and link into these zones.
// ------------------------------------------------------------------------
resource acrPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.azurecr.io'
  location: 'global'
}

resource kvPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

resource acrDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: acrPrivateDnsZone
  name: 'link-${namePrefix}'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource kvDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: kvPrivateDnsZone
  name: 'link-${namePrefix}'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

output vnetId string = vnet.id
output acaSubnetId string = acaSubnet.id
output privateEndpointSubnetId string = peSubnet.id
output acrPrivateDnsZoneId string = acrPrivateDnsZone.id
output kvPrivateDnsZoneId string = kvPrivateDnsZone.id
