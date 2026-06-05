# =============================================================================
# locals.tf — naming, tags, image lookup, derived flags.
# =============================================================================

locals {
  regionShortMap = {
    eastus        = "eus"
    eastus2       = "eus2"
    centralus     = "cus"
    westus        = "wus"
    westus2       = "wus2"
    westus3       = "wus3"
    westeurope    = "weu"
    northeurope   = "neu"
    uksouth       = "uks"
    australiaeast = "aue"
    japaneast     = "jpe"
  }

  locShort = lookup(local.regionShortMap, var.location, substr(replace(lower(var.location), " ", ""), 0, 5))

  names = {
    rg             = "${var.namingPrefix}-${var.environment}-rg-${local.locShort}"
    vnet           = "${var.namingPrefix}-${var.environment}-vnet-${local.locShort}"
    nsgHosts       = "${var.namingPrefix}-${var.environment}-nsg-hosts-${local.locShort}"
    nsgPe          = "${var.namingPrefix}-${var.environment}-nsg-pe-${local.locShort}"
    nsgMgmt        = "${var.namingPrefix}-${var.environment}-nsg-mgmt-${local.locShort}"
    hostPool       = "${var.namingPrefix}-${var.environment}-hp-${local.locShort}"
    appGroup       = "${var.namingPrefix}-${var.environment}-dag-${local.locShort}"
    workspace      = "${var.namingPrefix}-${var.environment}-ws-${local.locShort}"
    scalingPlan    = "${var.namingPrefix}-${var.environment}-sp-${local.locShort}"
    law            = "${var.namingPrefix}-${var.environment}-law-${local.locShort}"
    fslogixStorage = lower("${var.namingPrefix}${var.environment}fslg${substr(md5(local.fslogixUniqSeed), 0, 6)}")
    vmPrefix       = "${var.namingPrefix}${var.environment}h"
    peerHubToSpoke = "${var.namingPrefix}-${var.environment}-peer-hub-to-spoke"
    peerSpokeToHub = "${var.namingPrefix}-${var.environment}-peer-spoke-to-hub"
  }

  # Stable per-stack seed for the FSLogix storage account name (must be globally unique, ≤24 chars).
  fslogixUniqSeed = "${var.namingPrefix}-${var.environment}-${var.location}-fslogix"

  mergedTags = merge(var.tags, {
    environment = var.environment
    workload    = "avd"
  })

  # ---------------------------------------------------------------------------
  # Marketplace image lookup. Source of truth lives in shared/images.reference.json.
  # ---------------------------------------------------------------------------
  imageMap = jsondecode(file("${path.module}/../../shared/images.reference.json")).images

  marketplaceImage = lookup(local.imageMap, try(var.imageReference.alias, ""), {
    publisher = ""
    offer     = ""
    sku       = ""
    version   = ""
  })

  # ---------------------------------------------------------------------------
  # RDP Shortpath registry script (selected at deploy time, baked into CSE)
  # ---------------------------------------------------------------------------
  shortpathScripts = {
    None    = "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name fUseUdpPortRedirector -Value 0 -Force"
    Managed = "New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name fUseUdpPortRedirector -Value 1 -Force; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name UdpPortNumber -Value 3390 -Force; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name ICEControl -Value 1 -Force; New-NetFirewallRule -DisplayName 'AVD Shortpath UDP 3390' -Direction Inbound -Protocol UDP -LocalPort 3390 -Action Allow -ErrorAction SilentlyContinue"
    Public  = "New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name fUseUdpPortRedirector -Value 1 -Force; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name ICEControl -Value 0 -Force"
    Both    = "New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name fUseUdpPortRedirector -Value 1 -Force; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name UdpPortNumber -Value 3390 -Force; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' -Name ICEControl -Value 2 -Force; New-NetFirewallRule -DisplayName 'AVD Shortpath UDP 3390' -Direction Inbound -Protocol UDP -LocalPort 3390 -Action Allow -ErrorAction SilentlyContinue"
  }

  shortpathScript = local.shortpathScripts[var.rdpShortpathMode]

  # Custom RDP property string baked into the host pool — required for Entra-only sign-in.
  customRdpProperties = "targetisaadjoined:i:1;enablerdsaadauth:i:1;audiocapturemode:i:1;audiomode:i:0;camerastoredirect:s:*;redirectclipboard:i:1;redirectprinters:i:1;redirectsmartcards:i:1;usbdevicestoredirect:s:*"

  # AVD agent DSC artifact. Bump per AVD release.
  avdAgentDscUrl = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02990.1444.zip"

  # Derived booleans
  createLaw        = var.logAnalyticsWorkspaceId == ""
  createMgmtSubnet = var.mgmtSubnetCidr != ""
  enablePeering    = var.hubVnetId != ""
  grantVmAdmin     = var.adminUserGroupObjectId != ""

  # Built-in Azure role definition IDs
  roleIds = {
    desktopVirtualizationUser     = "/providers/Microsoft.Authorization/roleDefinitions/1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63"
    vmUserLogin                   = "/providers/Microsoft.Authorization/roleDefinitions/fb879df8-f326-4884-b1cf-06f3ad86be52"
    vmAdminLogin                  = "/providers/Microsoft.Authorization/roleDefinitions/1c0163c0-47e6-4577-8991-ea5c82e286e4"
    storageFileDataSmbContributor = "/providers/Microsoft.Authorization/roleDefinitions/0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb"
  }

  # ---------------------------------------------------------------------------
  # Cutover: parse the OLD host pool + workspace resource IDs into parts. We do
  # NOT data-source-read them; the cutover deployment is meant to work even when
  # the old stack is in a different subscription the deploying SPN can't read.
  # ---------------------------------------------------------------------------
  oldHpParts = split("/", var.existingHostPoolResourceId)
  oldWsParts = split("/", var.existingWorkspaceResourceId)

  oldHpSubId  = local.oldHpParts[2]
  oldHpRgName = local.oldHpParts[4]
  oldHpName   = element(local.oldHpParts, length(local.oldHpParts) - 1)

  oldWsSubId  = local.oldWsParts[2]
  oldWsRgName = local.oldWsParts[4]
  oldWsName   = element(local.oldWsParts, length(local.oldWsParts) - 1)

  # Operator runbook — emitted as an output, never executed by Terraform.
  drainScript = var.drainOldHostPool ? join("\n", [
    "# Drain runbook for the OLD host pool. Review, then run from a session signed in to subscription ${local.oldHpSubId}.",
    "az config set defaults.group=${local.oldHpRgName}",
    "az desktopvirtualization host-pool update ``",
    "  --resource-group ${local.oldHpRgName} ``",
    "  --name ${local.oldHpName} ``",
    "  --load-balancer-type DepthFirst",
    "$hosts = az desktopvirtualization session-host list --resource-group ${local.oldHpRgName} --host-pool-name ${local.oldHpName} -o json | ConvertFrom-Json",
    "foreach ($h in $hosts) {",
    "  az desktopvirtualization session-host update ``",
    "    --resource-group ${local.oldHpRgName} ``",
    "    --host-pool-name ${local.oldHpName} ``",
    "    --name $h.name.Split('/')[-1] ``",
    "    --allow-new-session false",
    "}",
    "# When sessions reach zero, run:",
    "# az desktopvirtualization host-pool delete -g ${local.oldHpRgName} -n ${local.oldHpName} --force",
  ]) : "Drain disabled (drainOldHostPool = false). The new host pool has been deployed; coordinate user migration manually."

  cutoverChecklist = [
    "1. Validate the NEW host pool: connect a pilot user via the new workspace feed (privatelink.wvd.microsoft.com).",
    "2. Add pilot users to the new desktop application group (already done via desktopUserGroupObjectId).",
    "3. Notify all users of the cutover window (T-7d, T-1d, T-1h).",
    "4. Run the drain script in cutoverDrainScript output during the cutover window.",
    "5. Move the remaining production users to the new workspace feed; for managed clients (Intune) push the new feed URL via policy.",
    "6. After 14 days of zero connections to the old host pool, decommission: az desktopvirtualization host-pool delete; remove old workspace; release old subnet CIDR.",
  ]
}
