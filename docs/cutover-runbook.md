# Cutover (side-by-side) runbook

Use this when you're replacing an **existing** AVD environment with a Secured-AVD
posture **without downtime**. Deploys new resources alongside the old, drains users,
then decommissions.

## When to use cutover vs greenfield

- **Greenfield**: no AVD today, or willing to accept an outage during transition
- **Cutover**: production AVD in use, zero-downtime requirement

## Strategy

```
T0  ─►  Old workspace + old host pool serving N users
T1  ─►  Deploy NEW workspace + NEW host pool + NEW session hosts (Private Link, Shortpath, Entra-join)
T2  ─►  Add Entra user group to NEW app group's "Desktop Virtualization User" role
T3  ─►  Users see BOTH feeds; coach them to switch (or push via Intune)
T4  ─►  Set OLD host pool drain mode = true (no new connections; existing sessions remain)
T5  ─►  Wait for old sessions to drain (or scheduled disconnect)
T6  ─►  Remove OLD workspace from users' feed (delete app group user role assignments)
T7  ─►  Tear down OLD workspace + host pool + session hosts
```

## Pre-cutover checklist

- [ ] [`prerequisites.md`](prerequisites.md) satisfied
- [ ] Resource IDs gathered:
      - `existingHostPoolResourceId` → `az desktopvirtualization hostpool show -g <rg> -n <name> --query id -o tsv`
      - `existingWorkspaceResourceId` → `az desktopvirtualization workspace show -g <rg> -n <name> --query id -o tsv`
- [ ] Confirm existing AVD location matches new deployment location (avoid cross-region surprises)
- [ ] Communicate the cutover plan to users (timing, expected behaviour change)
- [ ] Snapshot or backup any FSLogix profiles if migrating to a new storage account
- [ ] Confirm new DNS resolution doesn't shadow the existing public AVD endpoints prematurely

## Deploy NEW alongside OLD — Bicep

```powershell
az deployment group create `
  --resource-group $rg `
  --template-file bicep/cutover/main.bicep `
  --parameters bicep/cutover/main.bicepparam `
  --parameters existingHostPoolResourceId="/subscriptions/.../hostPools/old-hp" `
               existingWorkspaceResourceId="/subscriptions/.../workspaces/old-ws"
```

The cutover Bicep template:
1. Deploys new VNet (or peers into the same VNet — variable controlled)
2. Deploys new workspace + host pool + session hosts
3. Reads the existing host pool (`existing` keyword) for validation only
4. Does NOT modify the old resources at deploy time — drain is a separate explicit step

## Drain the OLD host pool

After users have been notified and the new environment is validated:

```powershell
# Set OLD host pool to drain mode — no new connections accepted
az desktopvirtualization hostpool update `
  --ids $existingHostPoolResourceId `
  --validation-environment false `
  --custom-rdp-property "drainmode:i:1"

# Set load balancer to "Persistent" so no new pooled sessions get assigned
az desktopvirtualization hostpool update `
  --ids $existingHostPoolResourceId `
  --load-balancer-type Persistent

# Watch session count drop
az desktopvirtualization session-host list `
  --host-pool-name <old-hp-name> --resource-group <old-rg> `
  --query "[].{name:name, sessions:sessions}"
```

## Wait for sessions to drain

Options, in order of user impact:

1. **Passive wait** — users log off naturally over days. Lowest impact, slowest.
2. **Scheduled disconnect** — send disconnect message via:
   ```powershell
   az desktopvirtualization user-session send-message `
     --resource-group <old-rg> --host-pool-name <old-hp> `
     --session-host-name <host-fqdn> --user-session-id <id> `
     --message-title "Please log off" `
     --message-body "Your AVD environment has moved. Please log off and reconnect via the new workspace."
   ```
3. **Force disconnect** at cutover time — `az desktopvirtualization user-session disconnect`. Disruptive.

## Remove OLD workspace from user feeds

```powershell
# Remove the Desktop Virtualization User role from the OLD app group
az role assignment delete `
  --assignee <desktopUserGroupObjectId> `
  --role "Desktop Virtualization User" `
  --scope <old-app-group-resource-id>
```

Users' next feed refresh (≤ 5 min) drops the old workspace.

## Teardown OLD environment

Once you've confirmed zero active sessions on the old host pool and users are
exclusively on the new feed:

```powershell
# Delete in dependency order
az desktopvirtualization application-group delete --ids <old-app-group-id> --yes
az desktopvirtualization workspace delete --ids $existingWorkspaceResourceId --yes
# Delete VMs (use loop — no bulk delete)
az vm delete --ids $(az vm list -g <old-rg> --query "[].id" -o tsv) --yes
az desktopvirtualization hostpool delete --ids $existingHostPoolResourceId --yes
# Finally the RG if it was AVD-only
az group delete -n <old-rg> --yes
```

## Rollback (if cutover fails before teardown)

The old environment is untouched until step 6 (remove from feed) and step 7 (teardown).
Rollback at any earlier point:

1. Undo drain on old host pool:
   ```powershell
   az desktopvirtualization hostpool update --ids $existingHostPoolResourceId `
     --custom-rdp-property "drainmode:i:0" `
     --load-balancer-type BreadthFirst
   ```
2. Remove Desktop Virtualization User role from NEW app group.
3. Leave new resources deployed for triage, or `az deployment group delete` to clean up.

Users continue on the old environment. No data loss.
