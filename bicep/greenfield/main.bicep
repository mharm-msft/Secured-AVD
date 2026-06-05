// =====================================================================================
// Secured-AVD — Greenfield (Bicep, canonical)
// Subscription/RG-scoped orchestrator. Deploys a fully-private, Entra-joined AVD
// stack: VNet+NSGs, Private DNS + 3 PEs (workspace/global, workspace/feed,
// hostpool/connection), host pool, app group, workspace, session-hosts with
// AADLoginForWindows + Intune (optional) + RDP Shortpath registry + AVD agent,
// optional FSLogix on Azure Files with Entra Kerberos, Log Analytics + diag.
//
// Parameter contract: shared/parameters.reference.json (CI-enforced).
// Modules:
//   network.bicep          — VNet, 3 subnets, NSGs (Shortpath-aware rules)
//   private-link.bicep     — 2 Private DNS zones + 3 PEs (workspace x2, hostpool x1)
//   monitoring.bicep       — Log Analytics (or BYO) + diag settings on AVD plane
//   host-pool.bicep        — host pool + desktop app group + scaling plan + RBAC
//   workspace.bicep        — workspace, attaches app group
//   session-hosts.bicep    — N VMs, NICs, extensions, registers to host pool
//   fslogix.bicep          — (optional) storage + Entra Kerberos + PE for profiles
//
// Run:
//   az group create -n <rg> -l <location>
//   az deployment group create -g <rg> -f bicep/greenfield/main.bicep \
//     -p bicep/greenfield/main.bicepparam
// =====================================================================================

targetScope = 'resourceGroup'

// -------------------------------------------------------------------------------------
// naming
// -------------------------------------------------------------------------------------
@description('Resource name prefix. Combined with workload + region short code. Max 6 chars recommended.')
@minLength(2)
@maxLength(6)
param namingPrefix string = 'savd'

@description('Environment tier. Included in tags and resource names.')
@allowed([ 'dev', 'test', 'stg', 'prod' ])
param environment string = 'prod'

// -------------------------------------------------------------------------------------
// location
// -------------------------------------------------------------------------------------
@description('Primary Azure region for all infra resources.')
param location string = 'eastus2'

@description('AVD control-plane metadata location.')
@allowed([ 'eastus', 'westus3', 'westeurope', 'northeurope', 'uksouth', 'australiaeast', 'japaneast' ])
param avdMetadataLocation string = 'eastus'

// -------------------------------------------------------------------------------------
// tags
// -------------------------------------------------------------------------------------
@description('Tags applied to every resource. Merged with stack-generated tags.')
param tags object = {
  workload: 'avd'
  environment: 'prod'
  managedBy: 'Secured-AVD-IaC'
}

// -------------------------------------------------------------------------------------
// network
// -------------------------------------------------------------------------------------
@description('CIDR for the AVD spoke VNet.')
param vnetAddressSpace string = '10.50.0.0/22'

@description('CIDR for session-host subnet. Must be inside vnetAddressSpace.')
param hostsSubnetCidr string = '10.50.0.0/24'

@description('CIDR for private-endpoint subnet.')
param peSubnetCidr string = '10.50.1.0/27'

@description('CIDR for optional management/jumpbox subnet. Pass empty string to skip.')
param mgmtSubnetCidr string = '10.50.1.32/27'

@description('Resource ID of an existing hub VNet to peer with. Empty = standalone spoke.')
param hubVnetId string = ''

@description('Custom DNS server IPs. Empty = Azure-provided DNS (recommended with Private DNS zones).')
param dnsServers array = []

// -------------------------------------------------------------------------------------
// hostPool
// -------------------------------------------------------------------------------------
@description('Pooled = multi-session shared hosts. Personal = 1:1 user-to-host.')
@allowed([ 'Pooled', 'Personal' ])
param hostPoolType string = 'Pooled'

@description('Connection load-balancing algorithm. Persistent applies to Personal only.')
@allowed([ 'BreadthFirst', 'DepthFirst', 'Persistent' ])
param loadBalancerType string = 'BreadthFirst'

@description('Max concurrent user sessions per Pooled host.')
@minValue(1)
@maxValue(999999)
param maxSessionLimit int = 8

@description('Preferred app group type for this host pool.')
@allowed([ 'Desktop', 'RailApplications' ])
param preferredAppGroupType string = 'Desktop'

@description('If true, host pool receives AVD service updates first (canary).')
param validationEnvironment bool = false

@description('Auto-start a stopped host when a user connects.')
param startVMOnConnect bool = true

// -------------------------------------------------------------------------------------
// sessionHosts
// -------------------------------------------------------------------------------------
@description('Session-host VM SKU.')
param vmSize string = 'Standard_D4s_v5'

@description('Number of session hosts to provision.')
@minValue(1)
@maxValue(200)
param vmCount int = 2

@description('Availability zones to spread VMs across. Empty array = no zone.')
param availabilityZones array = [ 1, 2, 3 ]

@description('OS disk storage SKU.')
@allowed([ 'Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS', 'PremiumV2_LRS' ])
param osDiskType string = 'Premium_LRS'

@description('OS disk size in GiB.')
@minValue(64)
param osDiskSizeGb int = 128

@description('Image to deploy. Two shapes: {kind:"marketplace", alias:"<key from images.reference.json>"} OR {kind:"customImage", resourceId:"/subscriptions/.../images/..."}.')
param imageReference object = {
  kind: 'marketplace'
  alias: 'win11-24h2-avd-m365'
}

@description('Local admin username on session hosts.')
param adminUsername string = 'savdadmin'

@description('Local admin password. Source from Key Vault in bicepparam files; never commit.')
@secure()
param adminPassword string

// -------------------------------------------------------------------------------------
// identity
// -------------------------------------------------------------------------------------
@description('Enroll Entra-joined hosts into Intune (MDM).')
param enableIntuneEnrollment bool = true

@description('Entra security group object ID that receives "Desktop Virtualization User" on the app group AND "Virtual Machine User Login" on session hosts.')
param desktopUserGroupObjectId string

@description('Entra security group for "Virtual Machine Administrator Login" on session hosts. Empty = skip.')
param adminUserGroupObjectId string = ''

// -------------------------------------------------------------------------------------
// shortpath
// -------------------------------------------------------------------------------------
@description('Managed = UDP 3390 inbound (intranet). Public = STUN/TURN UDP 3478/3479 egress (internet). Both = enable both. None = disabled.')
@allowed([ 'None', 'Managed', 'Public', 'Both' ])
param rdpShortpathMode string = 'Both'

// -------------------------------------------------------------------------------------
// fslogix
// -------------------------------------------------------------------------------------
@description('If true, deploy Azure Files (Entra Kerberos) + private endpoint for FSLogix profiles.')
param enableFSLogix bool = false

@description('Storage account SKU for FSLogix file share.')
@allowed([ 'Standard_LRS', 'Standard_GRS', 'Premium_LRS', 'Premium_ZRS' ])
param fslogixStorageSkuName string = 'Premium_LRS'

@description('Premium file share quota in GiB.')
@minValue(100)
param fslogixShareQuotaGb int = 1024

// -------------------------------------------------------------------------------------
// monitoring
// -------------------------------------------------------------------------------------
@description('BYO Log Analytics workspace resource ID. Empty = create a new workspace in the RG.')
param logAnalyticsWorkspaceId string = ''

@description('Log retention for the new workspace (ignored if BYO).')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

// =====================================================================================
// Locals — naming
// =====================================================================================
var regionShortMap = {
  eastus: 'eus'
  eastus2: 'eus2'
  westus: 'wus'
  westus2: 'wus2'
  westus3: 'wus3'
  centralus: 'cus'
  westeurope: 'weu'
  northeurope: 'neu'
  uksouth: 'uks'
  australiaeast: 'aue'
  japaneast: 'jpe'
}
var locShort = regionShortMap[?location] ?? take(replace(toLower(location), ' ', ''), 5)

// Resource name suffix pattern: {prefix}-{env}-{component}-{loc}
var n = {
  vnet:           '${namingPrefix}-${environment}-vnet-${locShort}'
  hostPool:       '${namingPrefix}-${environment}-hp-${locShort}'
  appGroup:       '${namingPrefix}-${environment}-dag-${locShort}'
  workspace:      '${namingPrefix}-${environment}-ws-${locShort}'
  scalingPlan:    '${namingPrefix}-${environment}-sp-${locShort}'
  law:            '${namingPrefix}-${environment}-law-${locShort}'
  fslogixStorage: toLower('${namingPrefix}${environment}fslg${take(uniqueString(resourceGroup().id), 6)}')
  vmPrefix:       '${namingPrefix}${environment}h'  // hostname prefix; suffixed with 2-digit index
}

var mergedTags = union(tags, {
  environment: environment
  workload: 'avd'
})

// =====================================================================================
// 1. Network — VNet + 3 NSGs + 3 subnets (mgmt subnet optional) + optional hub peering
// =====================================================================================
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: mergedTags
    vnetName: n.vnet
    vnetAddressSpace: vnetAddressSpace
    hostsSubnetCidr: hostsSubnetCidr
    peSubnetCidr: peSubnetCidr
    mgmtSubnetCidr: mgmtSubnetCidr
    hubVnetId: hubVnetId
    dnsServers: dnsServers
    rdpShortpathMode: rdpShortpathMode
    namingPrefix: namingPrefix
    environment: environment
    locShort: locShort
  }
}

// =====================================================================================
// 2. Monitoring — Log Analytics (or BYO) + diag settings (host pool + workspace)
// =====================================================================================
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: mergedTags
    workspaceName: n.law
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    logRetentionDays: logRetentionDays
  }
}

// =====================================================================================
// 3. Host Pool + Desktop App Group + Scaling Plan + RBAC
// =====================================================================================
module hostPool 'modules/host-pool.bicep' = {
  name: 'hostPool'
  params: {
    location: avdMetadataLocation
    tags: mergedTags
    hostPoolName: n.hostPool
    appGroupName: n.appGroup
    scalingPlanName: n.scalingPlan
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    preferredAppGroupType: preferredAppGroupType
    validationEnvironment: validationEnvironment
    startVMOnConnect: startVMOnConnect
    desktopUserGroupObjectId: desktopUserGroupObjectId
  }
}

// =====================================================================================
// 4. Workspace — attaches the desktop app group
// =====================================================================================
module workspace 'modules/workspace.bicep' = {
  name: 'workspace'
  params: {
    location: avdMetadataLocation
    tags: mergedTags
    workspaceName: n.workspace
    appGroupIds: [ hostPool.outputs.appGroupId ]
  }
}

// =====================================================================================
// 5. Private Link — 2 DNS zones + 3 PEs (after host pool + workspace exist)
// =====================================================================================
module privateLink 'modules/private-link.bicep' = {
  name: 'privateLink'
  params: {
    location: location
    tags: mergedTags
    namingPrefix: namingPrefix
    environment: environment
    locShort: locShort
    vnetId: network.outputs.vnetId
    peSubnetId: network.outputs.peSubnetId
    hostPoolId: hostPool.outputs.hostPoolId
    workspaceId: workspace.outputs.workspaceId
  }
}

// =====================================================================================
// 6. FSLogix (optional) — storage + Entra Kerberos + private endpoint
// =====================================================================================
module fslogix 'modules/fslogix.bicep' = if (enableFSLogix) {
  name: 'fslogix'
  params: {
    location: location
    tags: mergedTags
    storageAccountName: n.fslogixStorage
    fslogixStorageSkuName: fslogixStorageSkuName
    fslogixShareQuotaGb: fslogixShareQuotaGb
    vnetId: network.outputs.vnetId
    peSubnetId: network.outputs.peSubnetId
    desktopUserGroupObjectId: desktopUserGroupObjectId
  }
}

// =====================================================================================
// 7. Session hosts — N VMs, NICs, extensions, registers to host pool
// =====================================================================================
module sessionHosts 'modules/session-hosts.bicep' = {
  name: 'sessionHosts'
  params: {
    location: location
    tags: mergedTags
    vmNamePrefix: n.vmPrefix
    vmSize: vmSize
    vmCount: vmCount
    availabilityZones: availabilityZones
    osDiskType: osDiskType
    osDiskSizeGb: osDiskSizeGb
    imageReference: imageReference
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: network.outputs.hostsSubnetId
    hostPoolName: hostPool.outputs.hostPoolName
    hostPoolToken: hostPool.outputs.registrationToken
    enableIntuneEnrollment: enableIntuneEnrollment
    desktopUserGroupObjectId: desktopUserGroupObjectId
    adminUserGroupObjectId: adminUserGroupObjectId
    rdpShortpathMode: rdpShortpathMode
  }
  dependsOn: [
    privateLink
  ]
}

// =====================================================================================
// Outputs
// =====================================================================================
output vnetId string = network.outputs.vnetId
output hostPoolId string = hostPool.outputs.hostPoolId
output workspaceId string = workspace.outputs.workspaceId
output workspaceFeedPrivateIp string = privateLink.outputs.workspaceFeedPrivateIp
output hostPoolConnectionPrivateIp string = privateLink.outputs.hostPoolConnectionPrivateIp
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output sessionHostNames array = sessionHosts.outputs.vmNames
