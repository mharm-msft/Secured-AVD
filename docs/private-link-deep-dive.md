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
