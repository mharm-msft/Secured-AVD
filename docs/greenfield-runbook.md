# Greenfield runbook

Use this when you're deploying Secured-AVD into a **net-new** environment (no existing
AVD to replace).

## Pre-deployment checklist

- [ ] [`prerequisites.md`](prerequisites.md) satisfied
- [ ] Subscription selected (`az account set -s <sub>`)
- [ ] Deployment RG name chosen (typically `rg-{namingPrefix}-{env}-{region}`)
- [ ] Parameter values filled in (`*.bicepparam` or `*.tfvars` or `*.parameters.json`)
- [ ] `desktopUserGroupObjectId` resolved to a real Entra group
- [ ] Admin password sourced from Key Vault (not committed)
- [ ] DNS plan confirmed (standalone spoke vs hub-spoke with central DNS)

## Deploy — Bicep

```powershell
$rg     = "rg-savd-prod-eastus2"
$loc    = "eastus2"

az group create -n $rg -l $loc

az deployment group create `
  --resource-group $rg `
  --template-file bicep/greenfield/main.bicep `
  --parameters bicep/greenfield/main.bicepparam
```

What-if first (recommended):
```powershell
az deployment group what-if `
  --resource-group $rg `
  --template-file bicep/greenfield/main.bicep `
  --parameters bicep/greenfield/main.bicepparam
```

## Deploy — ARM

```powershell
az deployment group create `
  --resource-group $rg `
  --template-file arm/greenfield/main.json `
  --parameters arm/greenfield/main.parameters.json
```

## Deploy — Terraform

```powershell
cd terraform/greenfield
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan -out tfplan
terraform apply tfplan
```

## Post-deployment validation

1. **Resources present** — workspace, host pool, app group, 3 PEs, 2 private DNS zones,
   N session hosts (where N = `vmCount`).
2. **Workspace public access** — should be `Disabled`:
   ```powershell
   az desktopvirtualization workspace show -g $rg -n <workspace-name> --query publicNetworkAccess
   # Expected: "Disabled"
   ```
3. **DNS resolves to private IPs** — from inside spoke VNet:
   ```powershell
   nslookup rdweb.wvd.microsoft.com
   # Expected: 10.50.1.x range (peSubnetCidr)
   ```
4. **User can connect** — sign-in to Windows App with a user in the
   `desktopUserGroupObjectId` group, see the workspace, launch a desktop, confirm
   connection info shows UDP transport (Shortpath active).
5. **Diagnostic logs flowing** — Log Analytics workspace shows `WVDConnections`,
   `WVDFeeds`, `WVDAgentHealthStatus` tables populating within ~15 minutes.

## Common first-deploy errors

| Error | Cause | Fix |
|---|---|---|
| `InvalidAuthenticationTokenAudience` on PE creation | Stale Azure CLI session | `az logout && az login` |
| `MissingSubscriptionRegistration` for `Microsoft.DesktopVirtualization` | RP not registered | See prerequisites.md |
| `RoleAssignmentExists` on rerun | Idempotent retry on already-existing role | Safe to ignore |
| Client can't reach AVD after deployment | DNS not routing through Private DNS | See [`private-link-deep-dive.md`](private-link-deep-dive.md#dns-gotchas) |
| Session host extension fails on `AADLoginForWindows` | Tenant blocks Entra device join via Conditional Access | Exempt the AVD device IDs or the deployment principal |
