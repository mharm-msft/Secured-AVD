// =====================================================================================
// main.bicepparam — sample parameter file for the Secured-AVD greenfield deployment.
//
// Run:
//   az deployment group create \
//     -g rg-savd-prod-eus2 \
//     -f bicep/greenfield/main.bicep \
//     -p bicep/greenfield/main.bicepparam
//
// adminPassword MUST come from Key Vault — never hard-code. Example:
//   using './main.bicep'
//   param adminPassword = az.getSecret('<subId>', '<rg>', '<vault>', 'savd-local-admin')
// The line below uses a readEnvironmentVariable() placeholder so this file
// compiles in CI without secrets — replace with getSecret() in real use.
// =====================================================================================

using './main.bicep'

param namingPrefix = 'savd'
param environment  = 'prod'

param location            = 'eastus2'
param avdMetadataLocation = 'eastus'

param tags = {
  workload: 'avd'
  environment: 'prod'
  managedBy: 'Secured-AVD-IaC'
  costCenter: 'IT-Eng-001'
}

// network
param vnetAddressSpace = '10.50.0.0/22'
param hostsSubnetCidr  = '10.50.0.0/24'
param peSubnetCidr     = '10.50.1.0/27'
param mgmtSubnetCidr   = '10.50.1.32/27'
param hubVnetId        = ''
param dnsServers       = []

// host pool
param hostPoolType          = 'Pooled'
param loadBalancerType      = 'BreadthFirst'
param maxSessionLimit       = 8
param preferredAppGroupType = 'Desktop'
param validationEnvironment = false
param startVMOnConnect      = true

// session hosts
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
// CANONICAL: param adminPassword = az.getSecret('<subId>','<kvRg>','<kvName>','savd-local-admin')
// The line below sources the password from the SAVD_ADMIN_PASSWORD env var with NO default —
// builds fail loud if the operator forgets to set it. For real deployments, replace with the
// az.getSecret() call above so the value never leaves the keyvault control plane.
param adminPassword  = readEnvironmentVariable('SAVD_ADMIN_PASSWORD')

// identity
param enableIntuneEnrollment    = true
param desktopUserGroupObjectId  = '00000000-0000-0000-0000-000000000000' // replace with Entra group object ID
param adminUserGroupObjectId    = ''

// shortpath
param rdpShortpathMode = 'Both'

// fslogix
param enableFSLogix         = false
param fslogixStorageSkuName = 'Premium_LRS'
param fslogixShareQuotaGb   = 1024

// monitoring
param logAnalyticsWorkspaceId = ''
param logRetentionDays        = 30
