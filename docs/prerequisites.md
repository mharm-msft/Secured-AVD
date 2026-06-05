# Prerequisites

## Azure subscription

| Requirement | Notes |
|---|---|
| Subscription with `Owner` or `Contributor + User Access Administrator` | UAA is needed because we assign Desktop Virtualization roles |
| Resource providers registered | `Microsoft.DesktopVirtualization`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.OperationalInsights`, `Microsoft.Insights` |
| Quota in target region | At least `vmCount × vmSize.vCPU` vCPUs of your chosen VM family |

Register providers:
```powershell
az provider register --namespace Microsoft.DesktopVirtualization
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.Insights
```

## Entra ID tenant

| Requirement | Notes |
|---|---|
| Entra tenant tied to the subscription | Same tenant for control + data plane |
| Security group for AVD users | Object ID goes into `desktopUserGroupObjectId` |
| (Optional) Security group for AVD admins | Object ID goes into `adminUserGroupObjectId` |
| (Optional) Intune licensing for users | Required if `enableIntuneEnrollment = true` |

Create the user group:
```powershell
az ad group create --display-name "AVD-DesktopUsers" --mail-nickname "avd-desktopusers"
az ad group show --group "AVD-DesktopUsers" --query id -o tsv  # → desktopUserGroupObjectId
```

## Client tooling

| Tool | Min version | Purpose |
|---|---|---|
| Azure CLI | 2.60 | Deployments |
| Bicep CLI | 0.30 | Build/lint Bicep |
| Terraform | 1.9 | Plan/apply TF |
| AzureRM provider | 4.0 | Used by TF stack |
| AzAPI provider | 2.0 | Used for resources where AzureRM lags |

Install on Windows:
```powershell
winget install Microsoft.AzureCLI
az bicep install
winget install HashiCorp.Terraform
```

## Network reachability for clients

Because `publicNetworkAccess = Disabled`, clients **cannot** reach AVD over the public
internet. They must reach the private endpoints on the spoke VNet:

- **VPN** (Point-to-Site or Site-to-Site)
- **ExpressRoute** private peering
- **Azure Bastion-fronted jump host** with Remote Desktop client installed
- **Azure Virtual Desktop Insider Preview** clients via authorized endpoints

DNS must resolve the AVD private endpoint FQDNs to the private IPs:
- `*.wvd.microsoft.com` → `privatelink.wvd.microsoft.com`
- `rdweb.wvd.microsoft.com` → `privatelink-global.wvd.microsoft.com`

This is handled automatically when the client device's DNS resolver chases the Private
DNS zone via the spoke or hub.

## Optional: hub-spoke peering

If `hubVnetId` is set, the stack creates a bidirectional peering. The user/identity
running the deployment must have `Network Contributor` on both sides for peering to
succeed.
