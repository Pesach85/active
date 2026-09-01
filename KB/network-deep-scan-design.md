# Network Deep Scan — design (Phase 5)

## Goal

Detect **hidden or untracked network activity** that standard admin tooling (`Get-NetTCPConnection`, Task Manager, Resource Monitor) may miss. Surface actionable findings in the transparency web panel and CLI.

## Layers (current PS + Core v0.7.3)

| Layer | Technique | What it catches |
|-------|-----------|-----------------|
| L1 Cross-diff | `netstat -ano` vs `Get-NetTCPConnection` | Ghost sockets, stale PID mapping |
| L2 UDP | `Get-NetUDPEndpoint` | Covert UDP channels |
| L3 DNS cache | `Get-DnsClientCache` | Suspicious / Tor-related domains |
| L4 Tor heuristics | Ports, process names, memory strings | Tor client/proxy presence |
| L5 Ghost PID | Connections referencing dead processes | Rootkit-style PID reuse |
| L6 Memory forensics | PE string scan (bounded) | SOCKS/proxy/onion strings |
| L7 Admin probes | ETW TCPIP log + `netsh wfp show state` | Kernel/WFP visibility (admin) |

## Panel actions (HITL)

| Action | Gate | Effect |
|--------|------|--------|
| Kill conn | Session + understandRisk | `Reset-NetTCPConnection` |
| Block IP | Session + `BLOCK-REMOTE-IP` | Outbound firewall rule |
| Terminate | Session + `TERMINATE-NETWORK-PROCESS` | Process kill via Core |

CLI: `hub network snapshot|deep-scan|action`

## Core port

- `NetworkTransparencyService`, `NetworkDeepScanService`, `NetworkActionService`
- Windows: `WindowsNetworkProbeProvider`, `WindowsNetworkMutator`
- Routing: `HUB_USE_CORE=1` → `hub network deep-scan`

## Limitations (explicit)

- No kernel driver / ETW / WFP session capture in this phase (requires admin + future C# service).
- "Bit-level assembler" = bounded PE + memory string forensics, not disassembly of every network stack hook.
- Tor detection = local heuristics only; no exit-node or circuit probing.
- False positives possible on VPN, WSL, Docker, Hyper-V virtual switches.

## Future (Core port)

- `NetworkDeepScanService` in Hub Core with pluggable `INetworkProbe` (ETW, WFP, pcap).
- Quality gate: parity fixtures for each layer + smoke in `test-hub-smoke.ps1`.

## Decision log

Events tagged `network-deep-scan` append to `logs/hub-decision-log.jsonl` for NBD effectiveness.
