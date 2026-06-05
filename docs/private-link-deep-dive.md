# AVD Private Link — deep dive

See [`architecture.md`](architecture.md#avd-private-link-sub-resources) for the
high-level table. This doc covers the gotchas.

## Three sub-resources, three private endpoints

AVD Private Link is unusual because the **workspace** carries **two** sub-resources
(`global` + `feed`) while the **host pool** carries one (`connection`). You need three
private endpoints, even though there are only two AVD resources.

| PE | Target resource | Sub-resource | Private DNS zone | Records created |
|---|---|---|---|---|
| `pe-{ws}-global` | Workspace | `global` | `privatelink-global.wvd.microsoft.com` | One A record per region the workspace's metadata location serves |
| `pe-{ws}-feed`   | Workspace | `feed`   | `privatelink.wvd.microsoft.com` | A record for the workspace |
| `pe-{hp}-conn`   | Host pool | `connection` | `privatelink.wvd.microsoft.com` | A record for the host pool |

The `global` sub-resource is what makes Private Link work end-to-end — the AVD client
first contacts the global URL to discover where the regional control plane lives. If
the `global` PE is missing or DNS isn't resolving, the client falls back to public DNS
and either fails (if `publicNetworkAccess = Disabled`) or silently uses public Internet.

## DNS gotchas

1. **Both zones must be linked to the VNet that resolves DNS for clients.** Default
   stack links both to the spoke VNet.
2. **Custom DNS overrides Azure-provided.** If `dnsServers` is set on the VNet, the
   automatic Private DNS resolution via `168.63.129.16` is bypassed. Custom DNS must
   forward the two `*.wvd.microsoft.com` zones to `168.63.129.16` (Azure DNS) which then
   resolves Private DNS records.
3. **Clients off-network** (laptop on a customer's WiFi) can't resolve private FQDNs.
   They must either:
   - Connect through VPN that pushes the right DNS, or
   - Use Bastion → jump host pattern.

## Validating Private Link is working

```bash
# From a VM inside the spoke VNet:
nslookup rdweb.wvd.microsoft.com
# Expected: returns a 10.50.x.x address (your peSubnetCidr range)
# Bad: returns a public IP — means DNS isn't routing through Private DNS

nslookup <your-workspace-id>.global.wvd.microsoft.com
# Expected: 10.50.x.x

# Then connect with the Windows App — connection info should show Transport: UDP (if
# Shortpath enabled) and the gateway IP should be private.
```

## `publicNetworkAccess` semantics

`publicNetworkAccess` is set on the **host pool** AND the **workspace**. Both must be
`Disabled` to achieve a fully-private posture. Setting one without the other leaves a
public path open.

Changing the host pool to `Disabled`:
- **Does not** terminate existing sessions.
- **Does** prevent NEW connections from arriving via the public gateway.
- Effective immediately for new connections.

Plan changes during low-traffic windows or use the cutover pattern.

## Hybrid DNS topologies

The reference architecture defaults to **standalone**: both Private DNS zones
(`privatelink.wvd.microsoft.com`, `privatelink-global.wvd.microsoft.com`) are
linked directly to the spoke VNet, which uses Azure-provided DNS (`168.63.129.16`).
Real-world deployments rarely look like this. Three common topologies:

### Pattern 1 — Hub-and-spoke with central DNS forwarder (DNS Private Resolver)
```
[client on spoke VNet]
   ↓ DNS query: rdweb.wvd.microsoft.com
[VNet DNS = Private Resolver inbound endpoint IP]
   ↓ forwards to Azure DNS
[Azure DNS at 168.63.129.16]
   ↓ resolves via linked Private DNS zone
[Returns 10.x.x.x PE IP]
```
- Link both Private DNS zones to the **hub VNet** (where the resolver lives), not the spoke.
- Set the spoke VNet's `dnsServers` to the resolver inbound endpoint IP.
- Stack input: `dnsServers = [ '10.0.0.4' ]` (your resolver IP).

### Pattern 2 — On-premises AD DNS with conditional forwarder
```
[domain-joined client on-prem]
   ↓
[on-prem DNS (AD)]
   ↓ conditional forwarder for *.wvd.microsoft.com → resolver IP
[Azure Private DNS Resolver inbound endpoint]
   ↓ ...
```
- On-prem AD DNS gets a **conditional forwarder** for both `privatelink.wvd.microsoft.com` and
  `privatelink-global.wvd.microsoft.com` pointing at the Private DNS Resolver inbound endpoint.
- Requires bidirectional connectivity (ExpressRoute or S2S VPN).

### Pattern 3 — Active Directory–integrated split-horizon
Some shops mirror the Azure Private DNS records into their AD-integrated DNS zone
manually (PowerShell + scheduled task). Avoid this pattern — the records are not
static (workspace global maps to a service-managed FQDN that can change) and you
will eventually drift. Use Pattern 1 or 2.

## FSLogix + Storage Private Link interaction

When `enableFSLogix = true`, the storage account gets its own private endpoint
on the `peSubnetCidr` subnet and its own Private DNS zone link
(`privatelink.file.core.windows.net`). Two failure modes to watch:

| Symptom | Cause |
|---|---|
| Session host fails to mount the FSLogix share at sign-in | Storage account `publicNetworkAccess` is `Disabled` AND the session host can't resolve the storage PE FQDN (Private DNS link missing or DNS misrouted) |
| FSLogix mounts but profile load is slow | PE is in a different region than the storage account — latency spikes. Always co-locate. |
| Kerberos auth fails on share mount | Entra Kerberos not enabled OR the user's Entra group isn't on the share's RBAC AND on the storage NTFS ACL. Both layers must allow. |

Validate from a session host:
```powershell
# Resolution: must return a 10.x.x.x address from your peSubnetCidr
Resolve-DnsName "<storageaccount>.file.core.windows.net"

# Kerberos ticket: must show a CIFS/* ticket after sign-in
klist
```

## Troubleshooting matrix

| Symptom | Likely cause | First thing to check |
|---|---|---|
| Client connects but the AVD service appears to be offline | `global` PE missing or DNS not resolving for the global FQDN | `nslookup <wsId>.global.wvd.microsoft.com` from a client — must return private IP |
| Client times out at "Connecting…" | `connection` PE missing on the host pool, OR `publicNetworkAccess = Disabled` and client is off-network | Check host pool PE exists; verify client is on a network that can reach the spoke VNet |
| Client connects via public Internet despite `publicNetworkAccess = Disabled` | DNS is resolving the workspace/host pool FQDNs to public IPs — Private DNS zones not linked to the VNet that serves DNS | `nslookup` of the host pool FQDN must return private IP, not Microsoft public IP |
| Client connects but Transport shows TCP instead of UDP | RDP Shortpath not negotiated — see `docs/rdp-shortpath.md` troubleshooting section | Check session host NSG allows UDP 3478/3479 outbound (Managed mode) or UDP 3390 inbound (Public mode) |
| Session host shows "Unavailable" in the portal even when VM is running | AVD agent can't reach the host pool registration endpoint — usually because the spoke can't resolve the AVD control plane FQDNs via Private Link | Run `Test-NetConnection <hp-name>.wvd.microsoft.com -Port 443` from the session host |
| New session host registration fails | Registration token expired (24-hour lifetime by default) OR the host pool PE is brand new and DNS hasn't propagated | Recreate the registration token via `az desktopvirtualization host-pool retrieve-registration-token`; rerun the join extension |
| Sessions disconnect after ~2 hours despite no idle timeout | Probably NSG dropping the long-lived UDP flow. Shortpath UDP needs a generous flow-idle timer on NSGs | Check NSG flow logs; consider adding an explicit allow rule with `UseUDP = true` |

## Audit + observability

Every PE has a child `networkSecurityGroup` association implicitly through its subnet,
and every connection through the PE is logged in:

- **NSG flow logs** (if enabled on the `peSubnetCidr` NSG) — packet-level
- **Azure Activity log** on the workspace + host pool — control-plane mutations (PE created/deleted, `publicNetworkAccess` flipped, etc.)
- **Log Analytics → AVDConnections** table — per-session connection metadata, including the gateway IP the client landed on (public vs private)

Useful KQL — confirm sessions are landing on private endpoints:
```kusto
AVDConnections
| where TimeGenerated > ago(1d)
| extend GatewayIsPrivate = ipv4_is_private(GatewayIPAddress)
| summarize Total = count(), PrivateGateway = countif(GatewayIsPrivate), PublicGateway = countif(not(GatewayIsPrivate)) by bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```

If `PublicGateway` is non-zero after the cutover settles, you have a DNS or
client-network issue routing some users around Private Link. Use
`UserName` + `ClientIPAddress` to identify which users to investigate.
