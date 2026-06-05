// =====================================================================================
// workspace.bicep — AVD workspace, attaches application group(s).
// publicNetworkAccess Disabled — feed + global only reachable via the 2 PEs.
// =====================================================================================

param location string
param tags object
param workspaceName string
param appGroupIds array

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    friendlyName: workspaceName
    applicationGroupReferences: appGroupIds
    publicNetworkAccess: 'Disabled'
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
