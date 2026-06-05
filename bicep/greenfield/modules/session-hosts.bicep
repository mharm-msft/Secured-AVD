// =====================================================================================
// session-hosts.bicep — N session-host VMs, Entra-joined, registered to host pool.
//
//   Extensions per VM (run in order via dependsOn chain):
//     1. AADLoginForWindows        — Entra Join (+ Intune MDM enroll if enabled)
//     2. CustomScriptExtension     — RDP Shortpath registry settings (per mode)
//     3. DSC (Microsoft.PowerShell.DSC) — AVD agent + register to host pool
//
//   imageReference is the discriminated-union object from main.bicep:
//     { kind:"marketplace", alias:"..." }  OR  { kind:"customImage", resourceId:"..." }
// =====================================================================================

param location string
param tags object
param vmNamePrefix string
param vmSize string
param vmCount int
param availabilityZones array
param osDiskType string
param osDiskSizeGb int
param imageReference object
param adminUsername string
@secure()
param adminPassword string
param subnetId string
param hostPoolName string
@secure()
param hostPoolToken string
param enableIntuneEnrollment bool
param desktopUserGroupObjectId string
param adminUserGroupObjectId string
param rdpShortpathMode string

// -------------------------------------------------------------------------------------
// Image plan resolution
// -------------------------------------------------------------------------------------
var imageMap = loadJsonContent('../../../shared/images.reference.json').images
var marketplaceImage = imageReference.kind == 'marketplace' ? {
  publisher: imageMap[imageReference.alias].publisher
  offer:     imageMap[imageReference.alias].offer
  sku:       imageMap[imageReference.alias].sku
  version:   imageMap[imageReference.alias].version
} : {}
var customImage = imageReference.kind == 'customImage' ? { id: imageReference.resourceId } : {}
var resolvedImage = imageReference.kind == 'marketplace' ? marketplaceImage : customImage

// -------------------------------------------------------------------------------------
// AVD DSC artifact (pinned). To bump, set a newer Configuration_<version>.zip.
// This is a public AVD service artifact (single host, all clouds), so no environment() helper.
// -------------------------------------------------------------------------------------
#disable-next-line no-hardcoded-env-urls
var avdAgentDscUrl = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02990.1444.zip'

// -------------------------------------------------------------------------------------
// RDP Shortpath registry script — written via CustomScriptExtension.
// Keys based on https://learn.microsoft.com/azure/virtual-desktop/configure-rdp-shortpath
// -------------------------------------------------------------------------------------
var shortpathScriptMap = {
  None:    'Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name fUseUdpPortRedirector -Value 0 -Force'
  Managed: 'New-Item -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Force | Out-Null; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name fUseUdpPortRedirector -Value 1 -Force; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name UdpPortNumber -Value 3390 -Force; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name ICEControl -Value 1 -Force; New-NetFirewallRule -DisplayName "AVD Shortpath UDP 3390" -Direction Inbound -Protocol UDP -LocalPort 3390 -Action Allow -ErrorAction SilentlyContinue'
  Public:  'New-Item -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Force | Out-Null; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name fUseUdpPortRedirector -Value 1 -Force; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name ICEControl -Value 0 -Force'
  Both:    'New-Item -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Force | Out-Null; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name fUseUdpPortRedirector -Value 1 -Force; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name UdpPortNumber -Value 3390 -Force; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services" -Name ICEControl -Value 2 -Force; New-NetFirewallRule -DisplayName "AVD Shortpath UDP 3390" -Direction Inbound -Protocol UDP -LocalPort 3390 -Action Allow -ErrorAction SilentlyContinue'
}
var shortpathCommand = 'powershell -ExecutionPolicy Unrestricted -Command "${shortpathScriptMap[rdpShortpathMode]}"'

// -------------------------------------------------------------------------------------
// NICs + VMs + extensions
// -------------------------------------------------------------------------------------
resource nics 'Microsoft.Network/networkInterfaces@2024-01-01' = [ for i in range(0, vmCount): {
  name: '${vmNamePrefix}${padLeft(string(i), 2, '0')}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    enableAcceleratedNetworking: true
  }
} ]

resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' = [ for i in range(0, vmCount): {
  name: '${vmNamePrefix}${padLeft(string(i), 2, '0')}'
  location: location
  tags: tags
  zones: empty(availabilityZones) ? null : [ string(availabilityZones[i % length(availabilityZones)]) ]
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: resolvedImage
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGb
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
    }
    osProfile: {
      computerName: '${vmNamePrefix}${padLeft(string(i), 2, '0')}'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
          properties: { primary: true }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    licenseType: 'Windows_Client'
  }
} ]

// Ext 1 — AADLoginForWindows (Entra join, + Intune enroll when enableIntuneEnrollment)
resource extAadLogin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [ for i in range(0, vmCount): {
  parent: vms[i]
  name: 'AADLoginForWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
    settings: enableIntuneEnrollment ? {
      mdmId: '0000000a-0000-0000-c000-000000000000' // Intune MDM well-known app ID
    } : {}
  }
} ]

// Ext 2 — Shortpath registry (skip when rdpShortpathMode == 'None' and no policy reset needed)
resource extShortpath 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [ for i in range(0, vmCount): {
  parent: vms[i]
  name: 'ShortpathConfig'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {}
    protectedSettings: {
      commandToExecute: shortpathCommand
    }
  }
  dependsOn: [
    extAadLogin[i]
  ]
} ]

// Ext 3 — DSC: install AVD agent + boot loader, register VM with host pool
resource extAvdAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [ for i in range(0, vmCount): {
  parent: vms[i]
  name: 'AVD-DSC'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: avdAgentDscUrl
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostPoolName
        registrationInfoToken: hostPoolToken
        aadJoin: true
      }
    }
  }
  dependsOn: [
    extShortpath[i]
  ]
} ]

// -------------------------------------------------------------------------------------
// RBAC — Virtual Machine User Login for desktop users (lets them sign in to the OS)
// Role definition ID: fb879df8-f326-4884-b1cf-06f3ad86be52
// -------------------------------------------------------------------------------------
resource roleVmUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [ for i in range(0, vmCount): {
  name: guid(vms[i].id, desktopUserGroupObjectId, 'VirtualMachineUserLogin')
  scope: vms[i]
  properties: {
    principalId: desktopUserGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')
  }
} ]

// Optional — Virtual Machine Administrator Login for admin group
// Role definition ID: 1c0163c0-47e6-4577-8991-ea5c82e286e4
resource roleVmAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [ for i in range(0, vmCount): if (!empty(adminUserGroupObjectId)) {
  name: guid(vms[i].id, adminUserGroupObjectId, 'VirtualMachineAdministratorLogin')
  scope: vms[i]
  properties: {
    principalId: adminUserGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
  }
} ]

output vmNames array = [ for i in range(0, vmCount): vms[i].name ]
output vmIds array   = [ for i in range(0, vmCount): vms[i].id ]
