# Architecture — Secured-AVD

## Design goals

1. **Zero public-internet exposure of the AVD control plane.** Clients reach the
   workspace feed, broker, and gateway over Private Link.
2. **Identity from Entra ID only.** No AD DS or Azure AD DS dependency.
3. **Low-latency RDP** via Shortpath, with both internet-side (STUN/TURN) and
   intranet-side (UDP 3390) transports.
4. **Parameter parity** across ARM, Bicep, and Terraform so a customer can pick the IaC
   tool of their choice without losing capability.
5. **Greenfield and cutover** in the same repo, sharing modules where possible.

## Component diagram

```
                 ┌───────────────────────────────────────────────┐
                 │  AVD control plane (Microsoft-managed)         │
                 │  Broker · Gateway · Diagnostics · REST API     │
                 └────────────────┬──────────────────────────────┘
                                  │ Private Link (3 sub-resources)
                                  │   global  ─► initial discovery
                                  │   feed    ─► workspace feed
                                  │   connection ─► session host reverse-connect
                                  ▼
        ┌────────────────────────────────────────────────────────────┐
        │  Spoke VNet (10.50.0.0/22)                                 │
        │                                                            │
        │  ┌─────────────────┐  ┌─────────────────┐  ┌───────────┐  │
        │  │ snet-hosts /24  │  │ snet-pe /27     │  │ snet-mgmt │  │
        │  │                 │  │                 │  │  /27      │  │
        │  │  Session hosts  │  │  PE: workspace  │  │ (jumpbox) │  │
        │  │  (Entra joined) │  │      (global)   │  │           │  │
        │  │  Win11 24H2 AVD │  │  PE: workspace  │  │           │  │
        │  │   + M365        │  │      (feed)     │  │           │  │
        │  │                 │  │  PE: hostpool   │  │           │  │
        │  │                 │  │      (connection)│  │           │  │
        │  │                 │  │  PE: storage    │  │           │  │
        │  │                 │  │  (FSLogix opt.) │  │           │  │
        │  └────────┬────────┘  └────────┬────────┘  └─────┬─────┘  │
        │           │                    │                  │        │
        │           │  AVD service tag   │  Private DNS:    │        │
        │           │  egress only       │   privatelink.wvd.microsoft.com
        │           │  + UDP 3478/3479   │   privatelink-global.wvd.microsoft.com
        │           │    if Public SP    │   privatelink.file.core.windows.net (if FSLogix)
        │           │                    │                                              
        └───────────┴────────────────────┴──────────────────────────┘
                                  ▲
                                  │ (optional) hub peering via hubVnetId
                                  │
                            On-prem / hub VNet
                            (ExpressRoute / VPN)
```

## AVD Private Link sub-resources

AVD Private Link exposes three sub-resources, **each requiring its own private endpoint**:

| Sub-resource | Lives on | Purpose | Private DNS zone |
|---|---|---|---|
| `global` | Workspace | Initial connection — client hits the global URL first to discover the regional control-plane endpoint | `privatelink-global.wvd.microsoft.com` |
| `feed` | Workspace | Returns the list of resources (desktops / RemoteApps) the user is entitled to | `privatelink.wvd.microsoft.com` |
| `connection` | Host pool | Reverse-connect — session host calls this to register and to receive incoming session connections | `privatelink.wvd.microsoft.com` |

**`publicNetworkAccess`** is set to `Disabled` on both workspace and host pool, eliminating
the public AVD endpoints entirely.

> **Operational note**: changing `publicNetworkAccess` on a host pool only affects **new**
> sessions. Existing connections survive until they disconnect. See
> [cutover-runbook.md](cutover-runbook.md) for drain coordination.

## Entra-joined session hosts

Session hosts use a clean Entra-only join path:

1. **VM extension** `Microsoft.Azure.ActiveDirectory/AADLoginForWindows` joins the host to
   Entra at first boot.
2. **MDM enrollment** (Intune) is triggered via the extension's `mdmId` setting when
   `enableIntuneEnrollment = true`. Tenant must have Intune auto-enrollment configured
   for the user/device groups.
3. **AVD agent** + **boot loader** are installed via `Microsoft.PowerShell.DSC` using the
   `Configuration.zip` artifact published by the AVD team.
4. **RBAC**: `Virtual Machine User Login` (or `Virtual Machine Administrator Login` for
   ops) on the session hosts to permit Entra sign-in.

No AD DS. No Azure AD DS. No domain controllers in the spoke.

## RDP Shortpath

Shortpath establishes a **UDP** transport for the RDP stream, bypassing the TCP gateway
reverse-connect for the data plane (signaling still flows over the broker).

Two flavors, controlled by `rdpShortpathMode`:

| Mode | Path | When clients can use it |
|---|---|---|
| **Managed** (UDP 3390) | Direct UDP from client to session host on port 3390 | Clients on a network that can route to the session host subnet (VPN, ExpressRoute, MPLS) |
| **Public** (UDP 3478/3479 via STUN/TURN) | Client and host both reach Microsoft STUN/TURN servers; ICE negotiates the best UDP path | Clients on the open internet |
| **Both** | Both transports enabled; ICE picks the best | Hybrid populations |
| **None** | Disabled — TCP-only via reverse-connect | Networks where UDP is blocked or undesirable |

The choice drives:
- NSG rules on the host subnet (UDP 3390 inbound from VPN ranges, or UDP 3478/3479
  outbound to Microsoft service tag)
- Registry settings on the session host (set via DSC):
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\fUseUdpPortRedirector = 1`
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\UdpPortNumber = 3390`
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\ICEControl = 2` (Both)

## Module split

The Bicep canonical decomposition (mirrored in ARM nested templates and Terraform local
modules):

| Module | Responsibility |
|---|---|
| `network` | VNet, subnets, NSGs, optional hub peering |
| `private-link` | Private DNS zones, VNet links, the 3 AVD private endpoints |
| `workspace` | AVD workspace + app group references |
| `host-pool` | Host pool + app group + role assignments + scaling plan |
| `session-hosts` | VMs, NICs, OS disks, extensions (Entra join, Intune, AVD agent, Shortpath DSC) |
| `fslogix` | Storage account + file share + Entra Kerberos config + PE (conditional) |
| `monitoring` | LAW (or BYO) + diagnostic settings on all resources |

## Cutover (side-by-side) variant

The `cutover/` set is the greenfield set **plus** two pieces:

1. An **existing-resource data block** that imports the old workspace + host pool by
   resource ID (Terraform `data` block, Bicep `existing` keyword, ARM nested
   `Microsoft.Resources/deployments` with `Microsoft.DesktopVirtualization/hostpools/read`).
2. A **drain step** that flips `customRdpProperty` / `validationEnvironment` and sets
   `loadBalancerType=Persistent` on the OLD host pool to stop new sessions, then waits
   on session count via deployment script.

The new resources deploy alongside; users get the new feed; the runbook
([cutover-runbook.md](cutover-runbook.md)) walks the operator through removal of the old
workspace from the user feed and final teardown.

## References

- [AVD Private Link overview](https://learn.microsoft.com/azure/virtual-desktop/private-link-overview)
- [Set up Private Link with AVD](https://learn.microsoft.com/azure/virtual-desktop/private-link-setup)
- [RDP Shortpath for AVD](https://learn.microsoft.com/azure/virtual-desktop/rdp-shortpath)
- [AVD network topology guidance](https://learn.microsoft.com/azure/cloud-adoption-framework/scenarios/wvd/eslz-network-topology-connectivity)
- [Azure Verified Modules — AVD](https://github.com/Azure?q=avm-res-desktopvirtualization)
