// =====================================================================================
// network.bicep — VNet, 3 NSGs, 3 subnets (mgmt optional), optional hub peering.
// NSG rules conditional on rdpShortpathMode (None | Managed | Public | Both).
// =====================================================================================

param location string
param tags object
param vnetName string
param vnetAddressSpace string
param hostsSubnetCidr string
param peSubnetCidr string
param mgmtSubnetCidr string
param hubVnetId string
param dnsServers array
param rdpShortpathMode string
param namingPrefix string
param environment string
param locShort string

var deployMgmtSubnet = !empty(mgmtSubnetCidr)
var peerWithHub = !empty(hubVnetId)
var hubVnetName = peerWithHub ? last(split(hubVnetId, '/')) : ''
var allowShortpathInbound = rdpShortpathMode == 'Managed' || rdpShortpathMode == 'Both'
var allowShortpathEgress  = rdpShortpathMode == 'Public'  || rdpShortpathMode == 'Both'

var nsgHostsName = '${namingPrefix}-${environment}-nsg-hosts-${locShort}'
var nsgPeName    = '${namingPrefix}-${environment}-nsg-pe-${locShort}'
var nsgMgmtName  = '${namingPrefix}-${environment}-nsg-mgmt-${locShort}'

// -------------------------------------------------------------------------------------
// NSGs
// -------------------------------------------------------------------------------------
resource nsgHosts 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgHostsName
  location: location
  tags: tags
  properties: {
    securityRules: concat(
      [
        {
          name: 'Allow-AVD-Reverse-Connect-Out'
          properties: {
            description: 'Session hosts reach AVD broker via outbound 443 over WindowsVirtualDesktop service tag (reverse connect).'
            priority: 100
            direction: 'Outbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: 'WindowsVirtualDesktop'
            destinationPortRange: '443'
          }
        }
        {
          name: 'Allow-AzureCloud-Out-443'
          properties: {
            description: 'Outbound 443 to AzureCloud service tag for management, Storage, Monitor, KeyVault, etc.'
            priority: 110
            direction: 'Outbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: 'AzureCloud'
            destinationPortRange: '443'
          }
        }
        {
          name: 'Allow-AzureActiveDirectory-Out'
          properties: {
            description: 'Outbound to Entra ID for join, sign-in, token refresh.'
            priority: 120
            direction: 'Outbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: 'AzureActiveDirectory'
            destinationPortRange: '443'
          }
        }
      ],
      allowShortpathInbound ? [
        {
          name: 'Allow-Shortpath-UDP-3390-In'
          properties: {
            description: 'RDP Shortpath Managed networks: UDP 3390 inbound from intranet (VirtualNetwork tag).'
            priority: 200
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Udp'
            sourceAddressPrefix: 'VirtualNetwork'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '3390'
          }
        }
      ] : [],
      allowShortpathEgress ? [
        {
          name: 'Allow-Shortpath-STUN-Out'
          properties: {
            description: 'RDP Shortpath Public networks: outbound UDP to STUN/TURN (3478) on Internet.'
            priority: 300
            direction: 'Outbound'
            access: 'Allow'
            protocol: 'Udp'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: 'Internet'
            destinationPortRanges: [ '3478', '3479' ]
          }
        }
      ] : []
    )
  }
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgPeName
  location: location
  tags: tags
  properties: {
    // PE subnet is intentionally restrictive: PEs accept inbound from VNet only.
    // No explicit allow needed — Azure permits intra-VNet by default; default-deny everything else.
    securityRules: []
  }
}

resource nsgMgmt 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (deployMgmtSubnet) {
  name: nsgMgmtName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

// -------------------------------------------------------------------------------------
// VNet
// -------------------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressSpace ]
    }
    dhcpOptions: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    subnets: concat(
      [
        {
          name: 'snet-hosts'
          properties: {
            addressPrefix: hostsSubnetCidr
            networkSecurityGroup: { id: nsgHosts.id }
            privateEndpointNetworkPolicies: 'Enabled'
          }
        }
        {
          name: 'snet-pe'
          properties: {
            addressPrefix: peSubnetCidr
            networkSecurityGroup: { id: nsgPe.id }
            privateEndpointNetworkPolicies: 'Disabled' // PE subnet must disable network policies
          }
        }
      ],
      deployMgmtSubnet ? [
        {
          name: 'snet-mgmt'
          properties: {
            addressPrefix: mgmtSubnetCidr
            networkSecurityGroup: { id: nsgMgmt.id }
            privateEndpointNetworkPolicies: 'Enabled'
          }
        }
      ] : []
    )
  }
}

// -------------------------------------------------------------------------------------
// Optional hub peering (spoke-side only; hub-side must be created out-of-band)
// -------------------------------------------------------------------------------------
resource peeringToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = if (peerWithHub) {
  parent: vnet
  name: 'peering-to-${hubVnetName}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: hubVnetId
    }
  }
}

// -------------------------------------------------------------------------------------
// Outputs
// -------------------------------------------------------------------------------------
output vnetId string = vnet.id
output vnetName string = vnet.name
output hostsSubnetId string = '${vnet.id}/subnets/snet-hosts'
output peSubnetId string = '${vnet.id}/subnets/snet-pe'
output mgmtSubnetId string = deployMgmtSubnet ? '${vnet.id}/subnets/snet-mgmt' : ''
