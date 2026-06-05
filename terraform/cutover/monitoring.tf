# =============================================================================
# monitoring.tf — Log Analytics Workspace (or BYO via logAnalyticsWorkspaceId).
# =============================================================================

resource "azurerm_log_analytics_workspace" "law" {
  count               = local.createLaw ? 1 : 0
  name                = local.names.law
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = var.logRetentionDays
  tags                = local.mergedTags
}
