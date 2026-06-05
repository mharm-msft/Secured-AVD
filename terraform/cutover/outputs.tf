# =============================================================================
# outputs.tf (CUTOVER) — Surface BOTH new and old IDs, plus the operator
# runbook for draining and decommissioning the old AVD stack.
# =============================================================================

# ---- New stack (just deployed) ----------------------------------------------
output "resourceGroupName" {
  value       = azurerm_resource_group.rg.name
  description = "Resource group hosting the NEW AVD stack."
}

output "vnetId" {
  value       = azurerm_virtual_network.vnet.id
  description = "NEW VNet resource ID."
}

output "newHostPoolId" {
  value       = azapi_resource.hostPool.id
  description = "NEW AVD host pool resource ID."
}

output "newHostPoolName" {
  value       = azapi_resource.hostPool.name
  description = "NEW AVD host pool name."
}

output "newWorkspaceId" {
  value       = azapi_resource.workspace.id
  description = "NEW AVD workspace resource ID."
}

output "newWorkspaceName" {
  value       = azapi_resource.workspace.name
  description = "NEW AVD workspace name."
}

output "newAppGroupId" {
  value       = azapi_resource.appGroup.id
  description = "NEW AVD application group resource ID."
}

output "logAnalyticsWorkspaceId" {
  value       = local.createLaw ? azurerm_log_analytics_workspace.law[0].id : var.logAnalyticsWorkspaceId
  description = "Log Analytics workspace (created or BYO)."
}

output "fslogixStorageAccountName" {
  value       = var.enableFSLogix ? azurerm_storage_account.fslogix[0].name : null
  description = "NEW FSLogix storage account name (null when disabled)."
}

# ---- Old stack (untouched by this deployment) -------------------------------
output "oldHostPoolId" {
  value       = var.existingHostPoolResourceId
  description = "OLD AVD host pool resource ID (untouched by this deployment)."
}

output "oldHostPoolName" {
  value       = local.oldHpName
  description = "OLD AVD host pool name."
}

output "oldWorkspaceId" {
  value       = var.existingWorkspaceResourceId
  description = "OLD AVD workspace resource ID (untouched by this deployment)."
}

output "oldWorkspaceName" {
  value       = local.oldWsName
  description = "OLD AVD workspace name."
}

# ---- Operator runbook -------------------------------------------------------
output "cutoverDrainScript" {
  value       = local.drainScript
  description = "PowerShell snippet to drain users from the OLD host pool. NEVER executed by Terraform; review then run manually."
}

output "cutoverChecklist" {
  value       = local.cutoverChecklist
  description = "Six-step cutover runbook. Follow in order from pilot through decommission."
}
