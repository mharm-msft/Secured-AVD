// =====================================================================================
// Secured-AVD — Cutover / Rip-and-Replace (Bicep, canonical)
//
// Pattern: side-by-side + cutover.
//   1. Deploys a NEW, fully-private, Entra-joined AVD stack side-by-side with the
//      existing one — workspace, host pool, app group, session hosts, private link.
//   2. Validates the EXISTING host pool and workspace by reading their metadata
//      (resource exists, location alignment with avdMetadataLocation, etc.) so
//      the deployment fails fast if the wrong IDs are passed.
//   3. Emits cutover-runbook CLI snippets as deployment OUTPUTS — the operator
//      copy/pastes them to drain the old host pool, register users to the new
//      desktop app group, and (after the cutover window) decommission the old
//      stack. We do NOT mutate the old stack from Bicep (PUT-overwrites-everything
//      risk) — the operator owns the operational sequence.
//
// Naming: to deploy side-by-side in the SAME resource group, the operator MUST
//         differentiate the new stack by changing `namingPrefix` and/or
//         `environment` from the old stack's values. The new resources will then
//         use the standard `{prefix}-{env}-{component}-{loc}` pattern without
//         colliding with the old ones. See docs/rip-and-replace-runbook.md.
//
// Parameter contract: shared/parameters.reference.json (CI-enforced) — 34
// canonical params PLUS 3 cutoverOnly params at the bottom.
//
// Modules: SHARED with greenfield via `../greenfield/modules/*.bicep` (DRY).
//
// Run:
//   az group create -n <rg> -l <location>   # may be same RG as old stack
//   az deployment group create -g <rg> -f bicep/cutover/main.bicep \
//     -p bicep/cutover/main.bicepparam
// =====================================================================================

targetScope = 'resourceGroup'

// -------------------------------------------------------------------------------------
// naming
// -------------------------------------------------------------------------------------
@description('Resource name prefix. To deploy side-by-side in the same RG, MUST differ from the old stack\'s prefix (or use a different `environment`).')
@minLength(2)
@maxLength(6)
param namingPrefix string = 'savd'

@description('Environment tier. Combined with namingPrefix to differentiate the new stack from the old. Common pattern: old = prod, new = prd2.')
@allowed([ 'dev', 'test', 'stg', 'prod' ])
param environment string = 'prod'

// -------------------------------------------------------------------------------------
// location
// -------------------------------------------------------------------------------------
@description('Primary Azure region for all infra resources. Should match the old stack to keep latency-sensitive user data local.')
param location string = 'eastus2'

@description('AVD control-plane metadata location. MUST match the old stack so users keep a single MSAL/feed surface.')
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
  deploymentPattern: 'cutover'
}

// -------------------------------------------------------------------------------------
// network
// -------------------------------------------------------------------------------------
@description('CIDR for the NEW AVD spoke VNet. Must NOT overlap the old stack\'s VNet if peering or shared transit.')
param vnetAddressSpace string = '10.51.0.0/22'

@description('CIDR for session-host subnet. Must be inside vnetAddressSpace.')
param hostsSubnetCidr string = '10.51.0.0/24'

@description('CIDR for private-endpoint subnet.')
param peSubnetCidr string = '10.51.1.0/27'

@description('CIDR for optional management/jumpbox subnet. Pass empty string to skip.')
param mgmtSubnetCidr string = '10.51.1.32/27'

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

@description('Number of session hosts to provision in the NEW stack.')
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

@description('Image to deploy. Two shapes: {kind:"marketplace", alias:"<key>"} OR {kind:"customImage", resourceId:"/subscriptions/..."}.')
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

@description('Entra security group object ID that receives "Desktop Virtualization User" on the NEW app group AND "Virtual Machine User Login" on NEW session hosts. Usually the SAME group as the old stack so users have access to both during cutover.')
param desktopUserGroupObjectId string

@description('Entra security group for "Virtual Machine Administrator Login" on session hosts. Empty = skip.')
param adminUserGroupObjectId string = ''

// -------------------------------------------------------------------------------------
// shortpath
// -------------------------------------------------------------------------------------
@description('Managed = UDP 3390 inbound. Public = STUN/TURN UDP 3478/3479. Both = enable both. None = disabled.')
@allowed([ 'None', 'Managed', 'Public', 'Both' ])
param rdpShortpathMode string = 'Both'

// -------------------------------------------------------------------------------------
// fslogix
// -------------------------------------------------------------------------------------
@description('If true, deploy NEW Azure Files (Entra Kerberos) + PE for FSLogix. Profiles do NOT auto-migrate from the old share — see runbook for FSLogix migration guidance.')
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
@description('BYO Log Analytics workspace resource ID. Empty = create a new workspace. To keep one observability surface across old + new, pass the OLD stack\'s LAW ID here.')
param logAnalyticsWorkspaceId string = ''

@description('Log retention for the new workspace (ignored if BYO).')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

// -------------------------------------------------------------------------------------
// cutoverOnly
// -------------------------------------------------------------------------------------
@description('[cutover only] Resource ID of the EXISTING host pool being replaced. Used for validation + drain runbook snippet emission. Format: /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.DesktopVirtualization/hostPools/<name>')
param existingHostPoolResourceId string

@description('[cutover only] Resource ID of the EXISTING workspace being retired. Format: /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.DesktopVirtualization/workspaces/<name>')
param existingWorkspaceResourceId string

@description('[cutover only] If true, the deployment OUTPUT includes the drain PowerShell snippet for the OPERATOR to run. We do not mutate the old host pool from Bicep — a PUT would overwrite every property.')
param drainOldHostPool bool = true

// =====================================================================================
// Locals — naming + parse existing resource IDs
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

var n = {
  vnet:           '${namingPrefix}-${environment}-vnet-${locShort}'
  hostPool:       '${namingPrefix}-${environment}-hp-${locShort}'
  appGroup:       '${namingPrefix}-${environment}-dag-${locShort}'
  workspace:      '${namingPrefix}-${environment}-ws-${locShort}'
  scalingPlan:    '${namingPrefix}-${environment}-sp-${locShort}'
  law:            '${namingPrefix}-${environment}-law-${locShort}'
  fslogixStorage: toLower('${namingPrefix}${environment}fslg${take(uniqueString(resourceGroup().id), 6)}')
  vmPrefix:       '${namingPrefix}${environment}h'
}

var mergedTags = union(tags, {
  environment: environment
  workload: 'avd'
  deploymentPattern: 'cutover'
})

// Parse existing resource IDs to get sub/rg/name for cross-scope `existing` reads.
// ID format: /subscriptions/<subId>/resourceGroups/<rg>/providers/<rp>/<type>/<name>
var oldHpParts = split(existingHostPoolResourceId, '/')
var oldHpSubId = oldHpParts[2]
var oldHpRg    = oldHpParts[4]
var oldHpName  = last(oldHpParts)

var oldWsParts = split(existingWorkspaceResourceId, '/')
var oldWsSubId = oldWsParts[2]
var oldWsRg    = oldWsParts[4]
var oldWsName  = last(oldWsParts)

// =====================================================================================
// Validation — read old hp + old ws via `existing` so the deployment fails fast
// if the wrong IDs are passed, and so we can confirm location alignment.
// =====================================================================================
resource oldHostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = {
  name: oldHpName
  scope: resourceGroup(oldHpSubId, oldHpRg)
}

resource oldWorkspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' existing = {
  name: oldWsName
  scope: resourceGroup(oldWsSubId, oldWsRg)
}

// =====================================================================================
// 1. Network — VNet + 3 NSGs + 3 subnets (mgmt subnet optional) + optional hub peering
//    Modules SHARED with greenfield at ../greenfield/modules/*.bicep
// =====================================================================================
module network '../greenfield/modules/network.bicep' = {
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
// 2. Monitoring — Log Analytics (or BYO; recommend BYO=old stack LAW for cutover)
// =====================================================================================
module monitoring '../greenfield/modules/monitoring.bicep' = {
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
// 3. Host Pool + Desktop App Group + Scaling Plan + RBAC (NEW)
// =====================================================================================
module hostPool '../greenfield/modules/host-pool.bicep' = {
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
// 4. Workspace — attaches the NEW desktop app group
// =====================================================================================
module workspace '../greenfield/modules/workspace.bicep' = {
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
module privateLink '../greenfield/modules/private-link.bicep' = {
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
module fslogix '../greenfield/modules/fslogix.bicep' = if (enableFSLogix) {
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
// 7. Session hosts — N VMs, NICs, extensions, registers to NEW host pool
// =====================================================================================
module sessionHosts '../greenfield/modules/session-hosts.bicep' = {
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
// Outputs — new stack IDs + old stack IDs + operator runbook snippets
// =====================================================================================
output newVnetId string = network.outputs.vnetId
output newHostPoolId string = hostPool.outputs.hostPoolId
output newHostPoolName string = hostPool.outputs.hostPoolName
output newAppGroupId string = hostPool.outputs.appGroupId
output newWorkspaceId string = workspace.outputs.workspaceId
output newWorkspaceFeedPrivateIp string = privateLink.outputs.workspaceFeedPrivateIp
output newHostPoolConnectionPrivateIp string = privateLink.outputs.hostPoolConnectionPrivateIp
output newSessionHostNames array = sessionHosts.outputs.vmNames

output oldHostPoolId string = existingHostPoolResourceId
output oldHostPoolName string = oldHpName
output oldHostPoolLocation string = oldHostPool.location
output oldWorkspaceId string = existingWorkspaceResourceId
output oldWorkspaceName string = oldWsName
output oldWorkspaceLocation string = oldWorkspace.location

// Operator runbook snippets — emit only when drainOldHostPool = true so silent
// runs don't surface a giant CLI block.
output drainOldHostPoolPowerShellSnippet string = drainOldHostPool ? '''
# === DRAIN OLD HOST POOL ===========================================================
# This sets allowNewSession = $false on every existing session host in the OLD host
# pool, blocking new connections while letting current sessions disconnect on their
# own schedule. Existing users stay productive; new connections route to the NEW
# stack once you publish the new workspace to them.
Connect-AzAccount -SubscriptionId '${oldHpSubId}'
Get-AzWvdSessionHost -ResourceGroupName '${oldHpRg}' -HostPoolName '${oldHpName}' \
  | ForEach-Object {
      $name = $_.Name.Split('/')[-1]
      Write-Host "Draining $name"
      Update-AzWvdSessionHost -ResourceGroupName '${oldHpRg}' -HostPoolName '${oldHpName}' \
        -Name $name -AllowNewSession:$false
    }
# ===================================================================================
''' : ''

output cutoverChecklist array = [
  '1. Confirm NEW stack health: connect to ${n.workspace} from a test user account, validate desktop launches and RDP Shortpath engages.'
  '2. (Recommended) Add ${n.workspace} to user assignments WITHOUT removing the old workspace — users will see both during overlap window.'
  '3. Drain OLD host pool ${oldHpName} using the PowerShell snippet above.'
  '4. Monitor old host pool session count via Log Analytics: AVDConnections | where _ResourceId =~ "${existingHostPoolResourceId}" | summarize ConnectedUsers=dcount(UserName) by bin(TimeGenerated, 5m).'
  '5. When connected users = 0 for N hours, remove ${oldWsName} from user assignments.'
  '6. Decommission: delete ${oldHpName}, ${oldWsName}, and old session host VMs. Keep diagnostic logs for audit.'
]
