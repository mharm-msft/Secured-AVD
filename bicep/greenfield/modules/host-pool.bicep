// =====================================================================================
// host-pool.bicep — host pool + desktop app group + (Pooled-only) scaling plan + RBAC.
//
// publicNetworkAccess: 'Disabled' — data plane reachable only through PE.
// preferredAppGroupType controls whether we attach a Desktop or RailApplications group.
// registrationInfo token is generated inline; exposed as secure output for session-hosts.
// =====================================================================================

param location string
param tags object
param hostPoolName string
param appGroupName string
param scalingPlanName string
param hostPoolType string
param loadBalancerType string
param maxSessionLimit int
param preferredAppGroupType string
param validationEnvironment bool
param startVMOnConnect bool
param desktopUserGroupObjectId string

@description('Registration-token expiration. Default = utcNow + 14 days (computed at deploy time).')
param tokenExpiration string = dateTimeAdd(utcNow(), 'P14D')

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    friendlyName: hostPoolName
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    preferredAppGroupType: preferredAppGroupType
    validationEnvironment: validationEnvironment
    startVMOnConnect: startVMOnConnect
    publicNetworkAccess: 'Disabled' // data plane = PE only
    customRdpProperty: 'targetisaadjoined:i:1;enablerdsaadauth:i:1;audiocapturemode:i:1;audiomode:i:0;camerastoredirect:s:*;redirectclipboard:i:1;redirectprinters:i:1;redirectsmartcards:i:1;usbdevicestoredirect:s:*'
    registrationInfo: {
      expirationTime: tokenExpiration
      registrationTokenOperation: 'Update'
    }
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    friendlyName: appGroupName
    applicationGroupType: preferredAppGroupType
    hostPoolArmPath: hostPool.id
  }
}

// Pooled-only scaling plan (Personal pools use the Personal scaling plan API, omitted here).
resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = if (hostPoolType == 'Pooled') {
  name: scalingPlanName
  location: location
  tags: tags
  properties: {
    timeZone: 'Eastern Standard Time'
    hostPoolType: 'Pooled'
    exclusionTag: 'SkipScaling'
    schedules: [
      {
        name: 'weekdays'
        daysOfWeek: [ 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday' ]
        rampUpStartTime:    { hour: 7,  minute: 0 }
        peakStartTime:      { hour: 9,  minute: 0 }
        rampDownStartTime:  { hour: 17, minute: 0 }
        offPeakStartTime:   { hour: 20, minute: 0 }
        rampUpLoadBalancingAlgorithm:   'BreadthFirst'
        rampUpMinimumHostsPct: 20
        rampUpCapacityThresholdPct: 60
        peakLoadBalancingAlgorithm:     'DepthFirst'
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 10
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'Your session will be logged off in 30 minutes.'
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakLoadBalancingAlgorithm:  'DepthFirst'
      }
    ]
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPool.id
        scalingPlanEnabled: true
      }
    ]
  }
}

// -------------------------------------------------------------------------------------
// RBAC — "Desktop Virtualization User" on the app group for the desktop users group
// Role definition ID: 1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63
// -------------------------------------------------------------------------------------
resource roleDesktopUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appGroup.id, desktopUserGroupObjectId, 'DesktopVirtualizationUser')
  scope: appGroup
  properties: {
    principalId: desktopUserGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  }
}

output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name
output appGroupId string = appGroup.id
output appGroupName string = appGroup.name
@secure()
output registrationToken string = hostPool.properties.registrationInfo.token
