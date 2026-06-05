# =============================================================================
# main.tf — Resource group + cross-cutting data sources.
#
# All other resources live in topic-named files (network.tf, private-link.tf,
# host-pool.tf, session-hosts.tf, fslogix.tf, monitoring.tf).
# =============================================================================

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = local.names.rg
  location = var.location
  tags     = local.mergedTags
}
