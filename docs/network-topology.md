# Network topology

Standalone spoke VNet by default, with optional hub peering.

## Default (standalone) layout

```
VNet: vnet-{prefix}-{env}-{region}      10.50.0.0/22

├── snet-hosts                          10.50.0.0/24       (251 usable IPs)
│   └── NSG: nsg-hosts (AVD service tags egress + optional UDP 3390 in / 3478-9 out)
│
├── snet-pe                             10.50.1.0/27       (27 usable IPs)
│   └── NSG: nsg-pe (private endpoint subnet — egress allow, ingress per-PE)
│
└── snet-mgmt                           10.50.1.32/27      (optional, jumpbox)
    └── NSG: nsg-mgmt (RDP/SSH from named admin ranges only)
```

CIDRs are variables — see `vnetAddressSpace`, `hostsSubnetCidr`, `peSubnetCidr`,
`mgmtSubnetCidr` in [`../shared/parameters.reference.json`](../shared/parameters.reference.json).

## With hub peering (`hubVnetId` set)

The stack creates two peerings:

1. Spoke → Hub (with `useRemoteGateways = true` when hub has a gateway)
2. Hub → Spoke (with `allowGatewayTransit = true` on the hub side)

DNS resolution for AVD private endpoints flows through whatever DNS infrastructure your
hub provides. Common patterns:

- Hub runs a **DNS Private Resolver** with inbound endpoint in the hub. Spoke VNet
  uses the resolver IPs as DNS servers (set via `dnsServers` variable).
- Hub runs **DNS forwarders on VMs** pointing at `168.63.129.16` for Azure-resolvable
  zones. Spoke uses forwarder IPs.

> **Important**: For Private DNS to resolve correctly, the Private DNS Zones must be
> linked to whichever VNet performs the resolution. Default behaviour of this stack is
> to link the zones to the spoke VNet itself; if you're using a centralized resolver in
> the hub, you'll need to link to the hub VNet instead (set `dnsServers` and skip the
> spoke VNet link by extending the `private-link` module).

## NSG details

See [`rdp-shortpath.md`](rdp-shortpath.md) for the conditional UDP rules driven by
`rdpShortpathMode`.

Baseline egress on `nsg-hosts`:
- AVD service tag: `WindowsVirtualDesktop` → 443
- Azure service tags: `Storage` → 443 (FSLogix), `AzureMonitor` → 443, `AzureKeyVault` → 443

Everything else is denied by the implicit deny-all.
