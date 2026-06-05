// =====================================================================================
// monitoring.bicep — Log Analytics workspace (or BYO) for AVD diagnostics.
// Diagnostic settings on host pool + workspace can be added in a follow-up module;
// this file keeps LAW provisioning isolated so callers can plug in BYO without changes.
// =====================================================================================

param location string
param tags object
param workspaceName string
param logAnalyticsWorkspaceId string
param logRetentionDays int

var createNew = empty(logAnalyticsWorkspaceId)

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (createNew) {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output workspaceId string = createNew ? law.id : logAnalyticsWorkspaceId
