# RDP Shortpath

RDP Shortpath establishes a **UDP-based** transport for RDP, bypassing the TCP gateway
reverse-connect on the data plane. Lower latency, better resilience to packet loss,
better experience on congested networks.

## Modes

Controlled by the `rdpShortpathMode` variable:

| Mode | Direction | Port | Use when |
|---|---|---|---|
| `Managed` | Inbound to session host | UDP 3390 | Clients reach hosts over a private network (VPN, ER, MPLS) |
| `Public` | Outbound from client and host to Microsoft STUN/TURN | UDP 3478, UDP 3479 | Clients on the open internet |
| `Both` | Both transports enabled | 3390 + 3478/3479 | Hybrid client populations; ICE picks best path |
| `None` | Disabled | — | TCP-only via reverse-connect |

## What the stack configures

### NSG rules

When **Managed** is enabled, the host subnet NSG includes:
```
Name:        AllowRDPShortpathFromVPN
Protocol:    UDP
Direction:   Inbound
Source:      hubVnetAddressSpace (or named source ranges)
Destination: VirtualNetwork
Dest port:   3390
Action:      Allow
Priority:    200
```

When **Public** is enabled, the host subnet NSG egress allows:
```
Name:        AllowSTUNTURNOutbound
Protocol:    UDP
Direction:   Outbound
Destination: Internet (or AzureCloud service tag)
Dest port:   3478, 3479
Action:      Allow
Priority:    300
```

### Registry settings on session hosts

Applied via DSC extension at host provisioning:

| Key | Value | Effect |
|---|---|---|
| `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\fUseUdpPortRedirector` | `1` | Enable UDP transport |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\UdpPortNumber` | `3390` | Listen port for Managed mode |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\ICEControl` | `0` (Public), `1` (Managed), `2` (Both) | ICE behavior |

## Client requirements

| Client | Supports Shortpath |
|---|---|
| Windows App (modern, ≥ 2.0) | ✅ |
| Windows Desktop client (msrdc.exe ≥ 1.2.4677) | ✅ |
| macOS Remote Desktop client ≥ 10.9 | ✅ Public only |
| iOS / Android Remote Desktop | ✅ Public only |
| Web client (browser) | ❌ TCP only |

## Verifying Shortpath is in use

After connecting, on the client:
- **Windows App / msrdc**: open the connection bar → "Connection info" → check
  *Transport: UDP*.
- **Server-side**: `Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-ClientUSBDevices/Operational"`
  is the easiest local check; AVD Insights workbook has a Shortpath panel.

## When to disable Shortpath (`None`)

- Networks where UDP egress is blocked end-to-end (rare, but some financial-services
  perimeters do this).
- Troubleshooting — fall back to TCP when isolating a UDP-specific issue.

## References

- [RDP Shortpath for Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/rdp-shortpath)
- [Configure RDP Shortpath](https://learn.microsoft.com/azure/virtual-desktop/configure-rdp-shortpath)
