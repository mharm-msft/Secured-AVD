// =====================================================================================
// main.bicepparam — sample parameter file for the Secured-AVD CUTOVER deployment.
//
// Run:
//   az deployment group create \
//     -g rg-savd-prd2-eus2 \
//     -f bicep/cutover/main.bicep \
//     -p bicep/cutover/main.bicepparam
//
// IMPORTANT: To deploy side-by-side in the SAME resource group as the old AVD
// stack, change `namingPrefix` and/or `environment` here so the new resources
// don't collide. Example: old stack used environment = 'prod', so this file
// uses environment = 'prod' but a different namingPrefix ('savd' -> 'savd2'),
// OR keep the prefix and change the env (prod -> prd2).
// =====================================================================================

using './main.bicep'

// naming — DIFFERENTIATE from the old stack
param namingPrefix = 'savd2'
param environment  = 'prod'

// location — typically MATCH the old stack so latency-sensitive user data stays local
param location            = 'eastus2'
param avdMetadataLocation = 'eastus'

param tags = {
  workload: 'avd'
  environment: 'prod'
  managedBy: 'Secured-AVD-IaC'
  deploymentPattern: 'cutover'
  costCenter: 'IT-Eng-001'
}

// network — non-overlapping CIDR with old stack
param vnetAddressSpace = '10.51.0.0/22'
param hostsSubnetCidr  = '10.51.0.0/24'
param peSubnetCidr     = '10.51.1.0/27'
param mgmtSubnetCidr   = '10.51.1.32/27'
param hubVnetId        = ''
param dnsServers       = []

// host pool
param hostPoolType          = 'Pooled'
param loadBalancerType      = 'BreadthFirst'
param maxSessionLimit       = 8
param preferredAppGroupType = 'Desktop'
param validationEnvironment = false
param startVMOnConnect      = true

// session hosts — size the NEW stack for current peak load
param vmSize             = 'Standard_D4s_v5'
param vmCount            = 2
param availabilityZones  = [ 1, 2, 3 ]
param osDiskType         = 'Premium_LRS'
param osDiskSizeGb       = 128
param imageReference     = {
  kind: 'marketplace'
  alias: 'win11-24h2-avd-m365'
}
param adminUsername  = 'savdadmin'
// In production: param adminPassword = az.getSecret('<subId>','<kvRg>','<kvName>','savd-local-admin')
param adminPassword  = readEnvironmentVariable('SAVD_ADMIN_PASSWORD', 'ChangeMeBeforeDeploy!1')

// identity — usually SAME group as old stack so users access both during cutover
param enableIntuneEnrollment    = true
param desktopUserGroupObjectId  = '00000000-0000-0000-0000-000000000000' // replace with Entra group object ID
param adminUserGroupObjectId    = ''

// shortpath
param rdpShortpathMode = 'Both'

// fslogix — note: profiles do NOT auto-migrate; see runbook
param enableFSLogix         = false
param fslogixStorageSkuName = 'Premium_LRS'
param fslogixShareQuotaGb   = 1024

// monitoring — recommend BYO old-stack LAW so observability stays in one workspace
param logAnalyticsWorkspaceId = ''
param logRetentionDays        = 30

// cutoverOnly — REQUIRED: resource IDs of the OLD stack
param existingHostPoolResourceId    = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-savd-prod-eus2/providers/Microsoft.DesktopVirtualization/hostPools/savd-prod-hp-eus2'
param existingWorkspaceResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-savd-prod-eus2/providers/Microsoft.DesktopVirtualization/workspaces/savd-prod-ws-eus2'
param drainOldHostPool              = true
