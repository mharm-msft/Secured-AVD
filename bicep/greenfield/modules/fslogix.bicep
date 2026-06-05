// =====================================================================================
// fslogix.bicep — Azure Files + Entra Kerberos + private endpoint for FSLogix profiles.
//
// Notes:
//   - AzureFilesIdentityBasedAuthentication.directoryServiceOptions = 'AADKERB' for
//     Entra-joined session hosts (no AD DS).
//   - File share quota is Premium-tier (provisionedGiB); for Standard, use shareQuota.
//   - PE uses Storage's "file" sub-resource and privatelink.file.core.windows.net zone.
//   - SMB Share Contributor role on desktop users group → allows profile R/W.
//   - FSLogix client-side configuration (VHD locations, profile path) is set on session
//     hosts via DSC or Intune — not in this module.
// =====================================================================================

param location string
param tags object
param storageAccountName string
param fslogixStorageSkuName string
param fslogixShareQuotaGb int
param vnetId string
param peSubnetId string
param desktopUserGroupObjectId string

var isPremium = startsWith(fslogixStorageSkuName, 'Premium')
var storageKind = isPremium ? 'FileStorage' : 'StorageV2'

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: fslogixStorageSkuName }
  kind: storageKind
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // Entra Kerberos still uses storage key for some ops; keep true
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    protocolSettings: {
      smb: {
        versions: 'SMB3.1.1'
        authenticationMethods: 'Kerberos'
        kerberosTicketEncryption: 'AES-256'
        channelEncryption: 'AES-256-GCM'
      }
    }
  }
}

resource profilesShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: fileService
  name: 'profiles'
  properties: {
    shareQuota: fslogixShareQuotaGb
    enabledProtocols: 'SMB'
    accessTier: isPremium ? 'Premium' : 'TransactionOptimized'
  }
}

// -------------------------------------------------------------------------------------
// Private DNS zone for Files
// -------------------------------------------------------------------------------------
resource fileDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource fileDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: fileDnsZone
  name: 'link-${last(split(vnetId, '/'))}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

// -------------------------------------------------------------------------------------
// Private endpoint — Files sub-resource
// -------------------------------------------------------------------------------------
resource peFile 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: '${storageAccountName}-pe-file'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'file'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [ 'file' ]
        }
      }
    ]
  }
}

resource peFileDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peFile
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file'
        properties: { privateDnsZoneId: fileDnsZone.id }
      }
    ]
  }
  dependsOn: [ fileDnsLink ]
}

// -------------------------------------------------------------------------------------
// RBAC — Storage File Data SMB Share Contributor for desktop users group
// Role definition ID: 0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb
// -------------------------------------------------------------------------------------
resource roleSmbContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(profilesShare.id, desktopUserGroupObjectId, 'StorageFileDataSMBShareContributor')
  scope: storage
  properties: {
    principalId: desktopUserGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
  }
}

output storageAccountId string = storage.id
output storageAccountName string = storage.name
output profilesShareId string = profilesShare.id
output profilesUncPath string = '\\\\${storage.name}.file.${environment().suffixes.storage}\\profiles'
