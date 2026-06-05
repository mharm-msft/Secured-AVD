# =============================================================================
# host-pool.tf — Host pool + workspace + app group + scaling plan + RBAC.
#
# Host pool and workspace use azapi (not azurerm) so that
# publicNetworkAccess=Disabled is reliably set on first create — that posture is
# the entire point of this reference architecture.
# =============================================================================

# -----------------------------------------------------------------------------
# Host pool (azapi — publicNetworkAccess=Disabled is non-negotiable)
# -----------------------------------------------------------------------------
resource "azapi_resource" "hostPool" {
  type      = "Microsoft.DesktopVirtualization/hostPools@2024-04-03"
  name      = local.names.hostPool
  parent_id = azurerm_resource_group.rg.id
  location  = var.avdMetadataLocation
  tags      = local.mergedTags

  body = {
    properties = {
      friendlyName          = local.names.hostPool
      hostPoolType          = var.hostPoolType
      loadBalancerType      = var.loadBalancerType
      maxSessionLimit       = var.maxSessionLimit
      preferredAppGroupType = var.preferredAppGroupType
      validationEnvironment = var.validationEnvironment
      startVMOnConnect      = var.startVMOnConnect
      publicNetworkAccess   = "Disabled"
      customRdpProperty     = local.customRdpProperties
      registrationInfo = {
        expirationTime             = time_offset.tokenExpiry.rfc3339
        registrationTokenOperation = "Update"
      }
    }
  }

  response_export_values = ["properties.registrationInfo.token"]
}

resource "time_offset" "tokenExpiry" {
  offset_days = 14
}

# -----------------------------------------------------------------------------
# Workspace (azapi — publicNetworkAccess=Disabled)
# -----------------------------------------------------------------------------
resource "azapi_resource" "workspace" {
  type      = "Microsoft.DesktopVirtualization/workspaces@2024-04-03"
  name      = local.names.workspace
  parent_id = azurerm_resource_group.rg.id
  location  = var.avdMetadataLocation
  tags      = local.mergedTags

  body = {
    properties = {
      friendlyName        = local.names.workspace
      publicNetworkAccess = "Disabled"
      applicationGroupReferences = [
        azapi_resource.appGroup.id
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# Application group (Desktop or RailApplications, follows preferredAppGroupType)
# -----------------------------------------------------------------------------
resource "azapi_resource" "appGroup" {
  type      = "Microsoft.DesktopVirtualization/applicationGroups@2024-04-03"
  name      = local.names.appGroup
  parent_id = azurerm_resource_group.rg.id
  location  = var.avdMetadataLocation
  tags      = local.mergedTags

  body = {
    properties = {
      friendlyName         = local.names.appGroup
      applicationGroupType = var.preferredAppGroupType
      hostPoolArmPath      = azapi_resource.hostPool.id
    }
  }
}

# -----------------------------------------------------------------------------
# Scaling plan (Pooled only — Personal has its own scaling-plan API).
# -----------------------------------------------------------------------------
resource "azapi_resource" "scalingPlan" {
  count     = var.hostPoolType == "Pooled" ? 1 : 0
  type      = "Microsoft.DesktopVirtualization/scalingPlans@2024-04-03"
  name      = local.names.scalingPlan
  parent_id = azurerm_resource_group.rg.id
  location  = var.location
  tags      = local.mergedTags

  body = {
    properties = {
      friendlyName = local.names.scalingPlan
      hostPoolType = "Pooled"
      timeZone     = "Eastern Standard Time"
      exclusionTag = "AvdScalingExclusion"
      hostPoolReferences = [
        {
          hostPoolArmPath    = azapi_resource.hostPool.id
          scalingPlanEnabled = true
        }
      ]
      schedules = [
        {
          name                           = "WeekdaySchedule"
          daysOfWeek                     = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
          rampUpStartTime                = { hour = 7, minute = 0 }
          rampUpLoadBalancingAlgorithm   = "BreadthFirst"
          rampUpMinimumHostsPct          = 20
          rampUpCapacityThresholdPct     = 60
          peakStartTime                  = { hour = 9, minute = 0 }
          peakLoadBalancingAlgorithm     = "BreadthFirst"
          rampDownStartTime              = { hour = 18, minute = 0 }
          rampDownLoadBalancingAlgorithm = "DepthFirst"
          rampDownMinimumHostsPct        = 10
          rampDownCapacityThresholdPct   = 90
          rampDownForceLogoffUsers       = false
          rampDownWaitTimeMinutes        = 30
          rampDownNotificationMessage    = "You will be logged off in 30 minutes."
          rampDownStopHostsWhen          = "ZeroSessions"
          offPeakStartTime               = { hour = 20, minute = 0 }
          offPeakLoadBalancingAlgorithm  = "DepthFirst"
        }
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# RBAC: Desktop Virtualization User on the application group
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "desktopUser" {
  scope              = azapi_resource.appGroup.id
  role_definition_id = local.roleIds.desktopVirtualizationUser
  principal_id       = var.desktopUserGroupObjectId
}
