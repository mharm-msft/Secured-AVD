# =============================================================================
# outputs.tf — Surface the IDs/names a consumer or rip-and-replace stack needs.
# =============================================================================

output "resourceGroupName" {
  value       = azurerm_resource_group.rg.name
  description = "Resource group hosting the AVD stack."
}

output "vnetId" {
  value       = azurerm_virtual_network.vnet.id
  description = "VNet resource ID."
}

output "hostPoolId" {
  value       = azapi_resource.hostPool.id
  description = "AVD host pool resource ID."
}

output "hostPoolName" {
  value       = azapi_resource.hostPool.name
  description = "AVD host pool name."
}

output "workspaceId" {
  value       = azapi_resource.workspace.id
  description = "AVD workspace resource ID."
}

output "workspaceName" {
  value       = azapi_resource.workspace.name
  description = "AVD workspace name."
}

output "appGroupId" {
  value       = azapi_resource.appGroup.id
  description = "AVD application group resource ID."
}

output "logAnalyticsWorkspaceId" {
  value       = local.createLaw ? azurerm_log_analytics_workspace.law[0].id : var.logAnalyticsWorkspaceId
  description = "Log Analytics workspace (created or BYO)."
}

output "fslogixStorageAccountName" {
  value       = var.enableFSLogix ? azurerm_storage_account.fslogix[0].name : null
  description = "FSLogix storage account name (null when disabled)."
}
