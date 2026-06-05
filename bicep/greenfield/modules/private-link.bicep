// =====================================================================================
// private-link.bicep — AVD Private Link plumbing.
//
//   Required DNS zones:
//     privatelink.wvd.microsoft.com         (workspace/feed + hostpool/connection)
//     privatelink-global.wvd.microsoft.com  (workspace/global)
//
//   Required PEs (THREE — common gotcha):
//     1. workspace, sub-resource: global   (uses privatelink-global zone)
//     2. workspace, sub-resource: feed     (uses privatelink zone)
//     3. hostPool,  sub-resource: connection (uses privatelink zone)
//
//   Both workspace and host pool MUST have publicNetworkAccess = Disabled
//   to fully close the public data plane — set in their respective modules.
// =====================================================================================

param location string
param tags object
param namingPrefix string
param environment string
param locShort string
param vnetId string
param peSubnetId string
param hostPoolId string
param workspaceId string

var zoneWvd     = 'privatelink.wvd.microsoft.com'
var zoneGlobal  = 'privatelink-global.wvd.microsoft.com'

var peWsGlobalName = '${namingPrefix}-${environment}-pe-ws-global-${locShort}'
var peWsFeedName   = '${namingPrefix}-${environment}-pe-ws-feed-${locShort}'
var peHpConnName   = '${namingPrefix}-${environment}-pe-hp-conn-${locShort}'

// -------------------------------------------------------------------------------------
// Private DNS zones (global resources — no location)
// -------------------------------------------------------------------------------------
resource dnsWvd 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneWvd
  location: 'global'
  tags: tags
}

resource dnsGlobal 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneGlobal
  location: 'global'
  tags: tags
}

resource dnsLinkWvd 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsWvd
  name: 'link-${last(split(vnetId, '/'))}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource dnsLinkGlobal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsGlobal
  name: 'link-${last(split(vnetId, '/'))}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

// -------------------------------------------------------------------------------------
// PE 1 — workspace / global   (privatelink-global zone)
// -------------------------------------------------------------------------------------
resource peWsGlobal 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: peWsGlobalName
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'global'
        properties: {
          privateLinkServiceId: workspaceId
          groupIds: [ 'global' ]
        }
      }
    ]
  }
}

resource peWsGlobalDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peWsGlobal
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-global-wvd-microsoft-com'
        properties: { privateDnsZoneId: dnsGlobal.id }
      }
    ]
  }
  dependsOn: [ dnsLinkGlobal ]
}

// -------------------------------------------------------------------------------------
// PE 2 — workspace / feed   (privatelink zone)
// -------------------------------------------------------------------------------------
resource peWsFeed 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: peWsFeedName
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'feed'
        properties: {
          privateLinkServiceId: workspaceId
          groupIds: [ 'feed' ]
        }
      }
    ]
  }
}

resource peWsFeedDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peWsFeed
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-wvd-microsoft-com'
        properties: { privateDnsZoneId: dnsWvd.id }
      }
    ]
  }
  dependsOn: [ dnsLinkWvd ]
}

// -------------------------------------------------------------------------------------
// PE 3 — host pool / connection   (privatelink zone)
// -------------------------------------------------------------------------------------
resource peHpConn 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: peHpConnName
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'connection'
        properties: {
          privateLinkServiceId: hostPoolId
          groupIds: [ 'connection' ]
        }
      }
    ]
  }
}

resource peHpConnDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peHpConn
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-wvd-microsoft-com'
        properties: { privateDnsZoneId: dnsWvd.id }
      }
    ]
  }
  dependsOn: [ dnsLinkWvd ]
}

// -------------------------------------------------------------------------------------
// Outputs — first private IP on each NIC (useful for validation / DNS troubleshooting)
// -------------------------------------------------------------------------------------
output workspaceGlobalPrivateIp string  = peWsGlobal.properties.customDnsConfigs[0].ipAddresses[0]
output workspaceFeedPrivateIp string    = peWsFeed.properties.customDnsConfigs[0].ipAddresses[0]
output hostPoolConnectionPrivateIp string = peHpConn.properties.customDnsConfigs[0].ipAddresses[0]
output dnsZoneWvdId string    = dnsWvd.id
output dnsZoneGlobalId string = dnsGlobal.id
