# =============================================================================
# session-hosts.tf — NICs + VMs + extensions (AAD join → Shortpath registry →
# AVD agent DSC) + RBAC (VM User Login required, VM Admin Login optional).
#
# VMs round-robin across availabilityZones. Hostname is {prefix}{env}h{NN}.
# =============================================================================

resource "azurerm_network_interface" "sh" {
  count               = var.vmCount
  name                = "${local.names.vmPrefix}${format("%02d", count.index)}-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.hosts.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "sh" {
  count                      = var.vmCount
  name                       = "${local.names.vmPrefix}${format("%02d", count.index)}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = var.location
  size                       = var.vmSize
  admin_username             = var.adminUsername
  admin_password             = var.adminPassword
  network_interface_ids      = [azurerm_network_interface.sh[count.index].id]
  zone                       = tostring(element(var.availabilityZones, count.index))
  license_type               = "Windows_Client"
  patch_mode                 = "AutomaticByPlatform"
  hotpatching_enabled        = false
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = false
  tags                       = local.mergedTags

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "${local.names.vmPrefix}${format("%02d", count.index)}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = var.osDiskType
    disk_size_gb         = var.osDiskSizeGb
  }

  dynamic "source_image_reference" {
    for_each = var.imageReference.kind == "marketplace" ? [1] : []
    content {
      publisher = local.marketplaceImage.publisher
      offer     = local.marketplaceImage.offer
      sku       = local.marketplaceImage.sku
      version   = local.marketplaceImage.version
    }
  }

  source_image_id = var.imageReference.kind == "customImage" ? var.imageReference.resourceId : null

  # AutomaticByPlatform requires a patch assessment mode setting on modern azurerm.
  patch_assessment_mode = "AutomaticByPlatform"
}

# -----------------------------------------------------------------------------
# Extension 1/3 — AAD join (with Intune MDM optional via settings.mdmId)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "aadJoin" {
  count                      = var.vmCount
  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.sh[count.index].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true

  settings = var.enableIntuneEnrollment ? jsonencode({
    mdmId = "0000000a-0000-0000-c000-000000000000"
  }) : null
}

# -----------------------------------------------------------------------------
# Extension 2/3 — RDP Shortpath registry (CustomScript)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "shortpath" {
  count                      = var.vmCount
  name                       = "ShortpathConfig"
  virtual_machine_id         = azurerm_windows_virtual_machine.sh[count.index].id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -NoProfile -Command \"${local.shortpathScript}\""
  })

  depends_on = [azurerm_virtual_machine_extension.aadJoin]
}

# -----------------------------------------------------------------------------
# Extension 3/3 — AVD agent DSC (registers session host with the host pool)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "avdAgent" {
  count                      = var.vmCount
  name                       = "AddSessionHost"
  virtual_machine_id         = azurerm_windows_virtual_machine.sh[count.index].id
  publisher                  = "Microsoft.Powershell"
  type                       = "DSC"
  type_handler_version       = "2.77"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    modulesUrl            = local.avdAgentDscUrl
    configurationFunction = "Configuration.ps1\\AddSessionHost"
    properties = {
      hostPoolName             = azapi_resource.hostPool.name
      aadJoin                  = true
      UseAgentDownloadEndpoint = true
      aadJoinPreview           = false
    }
  })

  protected_settings = jsonencode({
    properties = {
      registrationInfoToken = azapi_resource.hostPool.output.properties.registrationInfo.token
    }
  })

  depends_on = [azurerm_virtual_machine_extension.shortpath]
}

# -----------------------------------------------------------------------------
# RBAC: Virtual Machine User Login (required) on the resource group
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "vmUserLogin" {
  scope              = azurerm_resource_group.rg.id
  role_definition_id = local.roleIds.vmUserLogin
  principal_id       = var.desktopUserGroupObjectId
}

# -----------------------------------------------------------------------------
# RBAC: Virtual Machine Administrator Login (optional)
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "vmAdminLogin" {
  count              = local.grantVmAdmin ? 1 : 0
  scope              = azurerm_resource_group.rg.id
  role_definition_id = local.roleIds.vmAdminLogin
  principal_id       = var.adminUserGroupObjectId
}
