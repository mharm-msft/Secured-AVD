# =============================================================================
# fslogix.tf — Optional Azure Files + Entra Kerberos + Private Endpoint + RBAC.
#
# Everything in this file is gated on var.enableFSLogix. When disabled, none of
# these resources are created.
# =============================================================================

resource "azurerm_storage_account" "fslogix" {
  count                           = var.enableFSLogix ? 1 : 0
  name                            = local.names.fslogixStorage
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg.name
  tags                            = local.mergedTags
  account_kind                    = "FileStorage"
  account_tier                    = "Premium"
  account_replication_type        = split("_", var.fslogixStorageSkuName)[1]
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
  public_network_access_enabled   = false

  azure_files_authentication {
    directory_type = "AADKERB"
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_share" "profiles" {
  count              = var.enableFSLogix ? 1 : 0
  name               = "profiles"
  storage_account_id = azurerm_storage_account.fslogix[0].id
  quota              = var.fslogixShareQuotaGb
  enabled_protocol   = "SMB"
  access_tier        = "Premium"
}

# -----------------------------------------------------------------------------
# Private endpoint for the file service
# -----------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "file" {
  count               = var.enableFSLogix ? 1 : 0
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags
}

resource "azurerm_private_dns_zone_virtual_network_link" "file_link" {
  count                 = var.enableFSLogix ? 1 : 0
  name                  = "link-${local.names.vnet}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.file[0].name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = local.mergedTags
}

resource "azurerm_private_endpoint" "fslogix" {
  count               = var.enableFSLogix ? 1 : 0
  name                = "${var.namingPrefix}-${var.environment}-pe-fslogix-${local.locShort}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.mergedTags

  private_service_connection {
    name                           = "psc-fslogix-file"
    private_connection_resource_id = azurerm_storage_account.fslogix[0].id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.file[0].id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.file_link]
}

# -----------------------------------------------------------------------------
# RBAC: Storage File Data SMB Share Contributor on the desktop user group
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "fslogixUser" {
  count              = var.enableFSLogix ? 1 : 0
  scope              = azurerm_storage_account.fslogix[0].id
  role_definition_id = local.roleIds.storageFileDataSmbContributor
  principal_id       = var.desktopUserGroupObjectId
}
