# =============================================================================
# variables.tf — 34 canonical parameters.
#
# Variable NAMES are camelCase (not Terraform's usual snake_case) so that the
# parameter-parity CI step can diff names 1:1 against Bicep + ARM. Do not
# rename. Do not add new variables here without updating
# shared/parameters.reference.json and both Bicep + ARM stacks.
# =============================================================================

# ---- 1. Naming & metadata ---------------------------------------------------
variable "namingPrefix" {
  type        = string
  description = "Short alphanumeric prefix used in every resource name."
  default     = "savd"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.namingPrefix))
    error_message = "namingPrefix must be 2-8 chars, lowercase alphanumeric, leading letter."
  }
}

variable "environment" {
  type        = string
  description = "Environment tag and name suffix."
  default     = "prod"
  validation {
    condition     = contains(["dev", "test", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, stage, prod."
  }
}

variable "location" {
  type        = string
  description = "Azure region for compute, network, and storage."
  default     = "eastus2"
}

variable "avdMetadataLocation" {
  type        = string
  description = "Region where AVD control-plane metadata lives (workspace/host pool)."
  default     = "eastus"
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource."
  default = {
    workload    = "avd"
    environment = "prod"
  }
}

# ---- 2. Network -------------------------------------------------------------
variable "vnetAddressSpace" {
  type        = string
  description = "VNet CIDR. Must contain all subnet CIDRs."
  default     = "10.50.0.0/22"
}

variable "hostsSubnetCidr" {
  type        = string
  description = "Subnet CIDR for session hosts."
  default     = "10.50.0.0/24"
}

variable "peSubnetCidr" {
  type        = string
  description = "Subnet CIDR for AVD/Storage private endpoints."
  default     = "10.50.1.0/27"
}

variable "mgmtSubnetCidr" {
  type        = string
  description = "Optional subnet CIDR for management/jumpbox. Empty string = skip."
  default     = ""
}

variable "hubVnetId" {
  type        = string
  description = "Optional hub VNet resource ID for bidirectional peering. Empty = standalone."
  default     = ""
}

variable "dnsServers" {
  type        = list(string)
  description = "Optional list of custom DNS servers on the VNet."
  default     = []
}

# ---- 3. AVD host pool -------------------------------------------------------
variable "hostPoolType" {
  type        = string
  description = "Pooled or Personal."
  default     = "Pooled"
  validation {
    condition     = contains(["Pooled", "Personal"], var.hostPoolType)
    error_message = "hostPoolType must be Pooled or Personal."
  }
}

variable "loadBalancerType" {
  type        = string
  description = "Pool LB algorithm: BreadthFirst, DepthFirst, Persistent."
  default     = "BreadthFirst"
}

variable "maxSessionLimit" {
  type        = number
  description = "Max sessions per session host (Pooled only)."
  default     = 8
}

variable "preferredAppGroupType" {
  type        = string
  description = "Desktop or RailApplications."
  default     = "Desktop"
}

variable "validationEnvironment" {
  type        = bool
  description = "True = host pool receives AVD service-side validation rings first."
  default     = false
}

variable "startVMOnConnect" {
  type        = bool
  description = "Power on stopped session hosts when a user connects."
  default     = true
}

# ---- 4. Session host VMs ----------------------------------------------------
variable "vmSize" {
  type        = string
  description = "Azure VM SKU for session hosts."
  default     = "Standard_D4s_v5"
}

variable "vmCount" {
  type        = number
  description = "Number of session-host VMs to deploy."
  default     = 2
}

variable "availabilityZones" {
  type        = list(number)
  description = "Availability zones VMs round-robin across (per-region capability dependent)."
  default     = [1, 2, 3]
}

variable "osDiskType" {
  type        = string
  description = "OS disk SKU."
  default     = "Premium_LRS"
}

variable "osDiskSizeGb" {
  type        = number
  description = "OS disk size in GiB."
  default     = 128
}

variable "imageReference" {
  type = object({
    kind       = string
    alias      = optional(string)
    resourceId = optional(string)
  })
  description = "Either {kind=marketplace, alias=<key in shared/images.reference.json>} or {kind=customImage, resourceId=<gallery image version id>}."
  default = {
    kind  = "marketplace"
    alias = "win11-24h2-avd-m365"
  }
}

variable "adminUsername" {
  type        = string
  description = "Local admin username on session hosts."
  default     = "savdadmin"
}

variable "adminPassword" {
  type        = string
  description = "Local admin password. Pass via TF_VAR_adminPassword env var or backend secret."
  sensitive   = true
}

variable "enableIntuneEnrollment" {
  type        = bool
  description = "Enroll session hosts into Intune via MDM extension."
  default     = true
}

# ---- 5. Identity ------------------------------------------------------------
variable "desktopUserGroupObjectId" {
  type        = string
  description = "Entra group OID that gets Desktop Virtualization User + VM User Login."
}

variable "adminUserGroupObjectId" {
  type        = string
  description = "Optional Entra group OID that gets VM Administrator Login. Empty = skip."
  default     = ""
}

# ---- 6. RDP Shortpath -------------------------------------------------------
variable "rdpShortpathMode" {
  type        = string
  description = "Public, Managed, Both, None."
  default     = "Both"
  validation {
    condition     = contains(["Public", "Managed", "Both", "None"], var.rdpShortpathMode)
    error_message = "rdpShortpathMode must be Public, Managed, Both, or None."
  }
}

# ---- 7. FSLogix -------------------------------------------------------------
variable "enableFSLogix" {
  type        = bool
  description = "Provision Azure Files + Entra Kerberos profile container."
  default     = false
}

variable "fslogixStorageSkuName" {
  type        = string
  description = "Storage account SKU (Premium_LRS recommended for profile latency)."
  default     = "Premium_LRS"
}

variable "fslogixShareQuotaGb" {
  type        = number
  description = "Share quota in GiB."
  default     = 1024
}

# ---- 8. Observability -------------------------------------------------------
variable "logAnalyticsWorkspaceId" {
  type        = string
  description = "BYO Log Analytics workspace resource ID. Empty = create a new one."
  default     = ""
}

variable "logRetentionDays" {
  type        = number
  description = "LAW retention (only used when creating new LAW)."
  default     = 30
}
