# =============================================================================
# private-link.tf — Private DNS zones + 3 PEs (workspace global/feed +
# host-pool connection) + VNet links to both zones.
#
# Zones:
#   privatelink.wvd.microsoft.com          (workspace/feed + hostpool/connection)
#   privatelink-global.wvd.microsoft.com   (workspace/global)
# =============================================================================

resource "azurerm_private_dns_zone" "wvd" {
  name                = "privatelink.wvd.microsoft.com"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags
}

resource "azurerm_private_dns_zone" "wvd_global" {
  name                = "privatelink-global.wvd.microsoft.com"
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags
}

resource "azurerm_private_dns_zone_virtual_network_link" "wvd_link" {
  name                  = "link-${local.names.vnet}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.wvd.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = local.mergedTags
}

resource "azurerm_private_dns_zone_virtual_network_link" "wvd_global_link" {
  name                  = "link-${local.names.vnet}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.wvd_global.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = local.mergedTags
}

# -----------------------------------------------------------------------------
# PE 1/3: Workspace — `global` sub-resource → privatelink-global zone
# -----------------------------------------------------------------------------
resource "azurerm_private_endpoint" "ws_global" {
  name                = "${var.namingPrefix}-${var.environment}-pe-ws-global-${local.locShort}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.mergedTags

  private_service_connection {
    name                           = "psc-ws-global"
    private_connection_resource_id = azapi_resource.workspace.id
    subresource_names              = ["global"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.wvd_global.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.wvd_global_link]
}

# -----------------------------------------------------------------------------
# PE 2/3: Workspace — `feed` sub-resource → privatelink.wvd zone
# -----------------------------------------------------------------------------
resource "azurerm_private_endpoint" "ws_feed" {
  name                = "${var.namingPrefix}-${var.environment}-pe-ws-feed-${local.locShort}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.mergedTags

  private_service_connection {
    name                           = "psc-ws-feed"
    private_connection_resource_id = azapi_resource.workspace.id
    subresource_names              = ["feed"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.wvd.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.wvd_link]
}

# -----------------------------------------------------------------------------
# PE 3/3: Host pool — `connection` sub-resource → privatelink.wvd zone
# This is the data-plane endpoint session hosts use to register and stream.
# -----------------------------------------------------------------------------
resource "azurerm_private_endpoint" "hp_connection" {
  name                = "${var.namingPrefix}-${var.environment}-pe-hp-conn-${local.locShort}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.mergedTags

  private_service_connection {
    name                           = "psc-hp-connection"
    private_connection_resource_id = azapi_resource.hostPool.id
    subresource_names              = ["connection"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.wvd.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.wvd_link]
}
