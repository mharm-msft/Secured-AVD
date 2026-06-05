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

@description('Deploy a NAT Gateway + Standard public IP for explicit outbound. When true, subnets set defaultOutboundAccess=false (no implicit default outbound). When false, subnets keep the legacy default outbound IP (deprecated by Microsoft Sept 2025).')
param deployNatGateway bool = true

var deployMgmtSubnet = !empty(mgmtSubnetCidr)
var peerWithHub = !empty(hubVnetId)
var hubVnetName = peerWithHub ? last(split(hubVnetId, '/')) : ''
var allowShortpathInbound = rdpShortpathMode == 'Managed' || rdpShortpathMode == 'Both'
var allowShortpathEgress  = rdpShortpathMode == 'Public'  || rdpShortpathMode == 'Both'

var nsgHostsName  = '${namingPrefix}-${environment}-nsg-hosts-${locShort}'
var nsgPeName     = '${namingPrefix}-${environment}-nsg-pe-${locShort}'
var nsgMgmtName   = '${namingPrefix}-${environment}-nsg-mgmt-${locShort}'
var natGwName     = '${namingPrefix}-${environment}-natgw-${locShort}'
var natPipName    = '${namingPrefix}-${environment}-natgw-pip-${locShort}'

// Common rule block applied to every NSG. Includes:
//  1. AllowLoadBalancerHealthInbound — required by Azure.NSG.DenyAllInbound (AZR-000138),
//     a reliability rule. Without an explicit allow for the AzureLoadBalancer service tag,
//     a catch-all inbound deny will break LB health probes for any current/future LB
//     attached to the subnet (private link, internal LB, gateway LB).
//  2. Inbound deny RDP/SSH — defense in depth against rule-ordering mutation by ops.
//  3. Outbound deny RDP/SSH — required by Azure.NSG.LateralTraversal (AZR-000139),
//     prevents an attacker on a session host from hopping laterally to other VMs in the
//     VNet over RDP/SSH. RDP Shortpath managed-networks uses UDP 3390 (not 3389), so this
//     does not interfere with Shortpath.
//  4. Inbound catch-all deny for Internet — explicit posture statement above implicit 65500.
var commonDenyRules = [
  {
    name: 'Allow-AzureLoadBalancer-In'
    properties: {
      description: 'Required by Azure.NSG.DenyAllInbound reliability rule — allows Azure load-balancer health probes so explicit deny-all-inbound below does not break PE / LB / health probe paths.'
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Deny-Out-RDP-SSH-Hop'
    properties: {
      description: 'Lateral-traversal prevention (Azure.NSG.LateralTraversal). Blocks outbound RDP/SSH from any host in this NSG to anywhere in the VNet so a compromised session host cannot pivot to other VMs. RDP Shortpath uses UDP 3390, not affected.'
      priority: 200
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [ '3389', '22' ]
    }
  }
  {
    name: 'Deny-Any-In-RDP-3389'
    properties: {
      description: 'Explicit deny RDP from any source. AVD session hosts use reverse-connect; inbound 3389 is never required.'
      priority: 4000
      direction: 'Inbound'
      access: 'Deny'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '3389'
    }
  }
  {
    name: 'Deny-Any-In-SSH-22'
    properties: {
      description: 'Explicit deny SSH from any source. AVD session hosts are Windows; no SSH surface expected anywhere in the VNet.'
      priority: 4010
      direction: 'Inbound'
      access: 'Deny'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
    }
  }
  {
    name: 'Deny-Internet-In-Any'
    properties: {
      description: 'Explicit catch-all deny for inbound traffic from Internet across any port.'
      priority: 4090
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
]

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
      ] : [],
      commonDenyRules
    )
  }
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgPeName
  location: location
  tags: tags
  properties: {
    // PE subnet accepts inbound from VNet only via implicit AllowVnetInbound; explicit
    // Deny-Internet-In rules below ensure attack ports are blocked even if rule ordering
    // is later mutated by ops.
    securityRules: commonDenyRules
  }
}

resource nsgMgmt 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (deployMgmtSubnet) {
  name: nsgMgmtName
  location: location
  tags: tags
  properties: {
    securityRules: commonDenyRules
  }
}

// -------------------------------------------------------------------------------------
// NAT Gateway + Standard public IP for explicit outbound (replaces default outbound IP).
// Microsoft deprecates default outbound access Sept 2025; subnets created after that date
// without explicit outbound fail to provision. Standard PIP + NAT GW is the canonical
// replacement and is the basis for zero-trust egress filtering.
// -------------------------------------------------------------------------------------
resource natPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (deployNatGateway) {
  name: natPipName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: [ '1', '2', '3' ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource natGw 'Microsoft.Network/natGateways@2024-01-01' = if (deployNatGateway) {
  name: natGwName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: [ '1' ]
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      { id: natPip.id }
    ]
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
            defaultOutboundAccess: deployNatGateway ? false : null
            natGateway: deployNatGateway ? { id: natGw.id } : null
          }
        }
        {
          name: 'snet-pe'
          properties: {
            addressPrefix: peSubnetCidr
            networkSecurityGroup: { id: nsgPe.id }
            privateEndpointNetworkPolicies: 'Disabled' // PE subnet must disable network policies
            defaultOutboundAccess: deployNatGateway ? false : null
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
            defaultOutboundAccess: deployNatGateway ? false : null
            natGateway: deployNatGateway ? { id: natGw.id } : null
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
output natGatewayId string = deployNatGateway ? natGw.id : ''
output natGatewayPublicIp string = deployNatGateway ? (natPip!.properties.?ipAddress ?? '') : ''
