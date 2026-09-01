# Network Deep Scan — design (Phase 5)

## Goal

Detect **hidden or untracked network activity** that standard admin tooling (`Get-NetTCPConnection`, Task Manager, Resource Monitor) may miss. Surface actionable findings in the transparency web panel and CLI.

## Layers (current PS implementation)

| Layer | Technique | What it catches |
|-------|-----------|-----------------|
| L1 Cross-diff | `netstat -ano` vs `Get-NetTCPConnection` | Ghost sockets, stale PID mapping, enumeration gaps |
| L2 UDP | `netstat -ano -p udp` | Covert UDP channels, DNS tunneling precursors |
| L3 DNS cache | `Get-DnsClientCache` | Recently resolved suspicious domains |
| L4 Tor heuristics | Ports 9050/9150/9051, process names, memory strings | Tor client/proxy presence (not full Tor network probe) |
| L5 Ghost PID | Connections referencing dead/missing processes | Rootkit-style PID reuse, zombie handles |
| L6 Memory forensics | `process-forensics.ps1` string scan on high-risk PIDs | SOCKS/proxy/onion strings in process memory |

## Actions (web panel)

- **Connessioni / Listener**: baseline snapshot + Resolve/Identify per row (HITL wizard).
- **Findings**: deep scan results grouped by severity.
- **Deep scan**: `POST /api/network/deep-scan` → `scan-network-deep.ps1` → `logs/network-deep-scan-latest.json`.

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
