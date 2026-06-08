# Secured-AVD

**Fully-private, Entra-joined Azure Virtual Desktop reference architecture** — shipped in
ARM, Bicep, and Terraform with parameter parity across all three stacks.

Two deployment patterns:

| Pattern | Path | When to use |
|---|---|---|
| **Greenfield** | `*/greenfield/` | Net-new AVD environment |
| **Cutover (side-by-side)** | `*/cutover/` | Modernize an existing AVD environment without downtime — deploy alongside, drain users, decommission old |

---

## What you get

A reference implementation of the FY26 best-practice AVD posture:

- 🔒 **AVD Private Link** on all three sub-resources (`connection`, `feed`, `global`) with
  `publicNetworkAccess = Disabled` on workspace and host pool.
- 🆔 **Entra ID joined** session hosts. No AD DS. No Azure AD DS. Optional Intune enrollment.
- ⚡ **RDP Shortpath** enabled for both public networks (STUN/TURN, UDP 3478/3479) and
  managed networks (UDP 3390 inbound). Toggle via `rdpShortpathMode` variable.
- 🖥️ **Variabilized session hosts** — VM SKU, count, availability zones, and image
  (marketplace alias or Compute Gallery resource ID) all parameterized.
- 📁 **Optional FSLogix** on Azure Files with Entra Kerberos auth, behind a private endpoint.
- 📊 **Diagnostics** wired to Log Analytics (create new or BYO workspace).
- 🌐 **Standalone VNet** by default, optional hub-spoke peering via `hubVnetId` variable.

See [`docs/architecture.md`](docs/architecture.md) for the full design.

---

## Repository layout

```
Secured-AVD/
├── README.md                            ← you are here
├── LICENSE                              ← MIT
├── CONTRIBUTING.md                      ← parameter parity contract, PR rules
├── docs/                                ← architecture + runbooks
├── shared/
│   ├── parameters.reference.json        ← canonical variable contract (single source of truth)
│   └── images.reference.json            ← marketplace image alias map
├── arm/{greenfield,cutover}/            ← ARM JSON (generated from Bicep via `bicep build`)
├── bicep/{greenfield,cutover}/          ← Bicep (canonical authoring)
├── terraform/{greenfield,cutover}/      ← Terraform using Azure Verified Modules (AVM)
└── .github/workflows/                   ← CI: bicep build, ARM what-if, terraform plan, conftest
```

**Bicep is canonical.** ARM is generated via `bicep build` to guarantee parity.
Terraform is hand-authored using [Azure Verified Modules](https://aka.ms/avm). All three
stacks consume the same parameter names defined in `shared/parameters.reference.json`.

---

## Quick start

### Bicep
```powershell
az deployment sub create `
  --location eastus2 `
  --template-file bicep/greenfield/main.bicep `
  --parameters bicep/greenfield/main.bicepparam
```

### ARM
```powershell
az deployment sub create `
  --location eastus2 `
  --template-file arm/greenfield/main.json `
  --parameters arm/greenfield/main.parameters.json
```

### Terraform
```powershell
cd terraform/greenfield
cp terraform.tfvars.example terraform.tfvars  # edit values
terraform init
terraform plan
terraform apply
```

---

## Prerequisites

See [`docs/prerequisites.md`](docs/prerequisites.md). Highlights:

- Azure subscription with `Owner` or `Contributor + User Access Administrator`
- Entra tenant with **Microsoft.DesktopVirtualization** resource provider registered
- An Entra security group to receive the `Desktop Virtualization User` role
- A workstation with **Azure CLI ≥ 2.60**, **Bicep CLI ≥ 0.30**, and **Terraform ≥ 1.9**
- Network reachability from clients to the future AVD private endpoints
  (typically via VPN, ExpressRoute, or Azure Bastion-fronted jump hosts)

---

## Cutover pattern (side-by-side)

The `cutover/` variant deploys a **second** AVD environment **alongside** an existing one,
with explicit user-drain coordination. Zero downtime. See
[`docs/cutover-runbook.md`](docs/cutover-runbook.md) for the full runbook.

High level:
1. Deploy new (workspace + host pool + session hosts) in the same or adjacent VNet.
2. Add Entra user group to the new app group's `Desktop Virtualization User` role.
3. Disable new connections on the old host pool (`drainMode = true`).
4. Wait for sessions to drain (or message users to log off).
5. Remove the old workspace from users' feeds.
6. Decommission the old AVD resources.

---

## Security posture

| Control | Status |
|---|---|
| Public network access on workspace / host pool | **Disabled** |
| Identity for session hosts | **Entra ID join** (no AD DS) |
| FSLogix profile storage | Azure Files + Entra Kerberos + private endpoint |
| Diagnostic logs | All AVD resources → Log Analytics |
| RBAC | Least-privilege role assignments scoped to RG |
| Network egress from hosts | NSG with AVD service tags only (plus STUN/TURN if Public Shortpath enabled) |

---

## License

[MIT](LICENSE) © 2026 Michael Harmon


## Contributing

This repository's `main` branch is protected. Direct pushes are blocked for all users (including admins). Workflow:

```bash
git checkout -b feat/your-change
# ...edits...
git push origin feat/your-change
gh pr create --fill
# wait for CI (6 required checks must pass)
gh pr merge --squash
```