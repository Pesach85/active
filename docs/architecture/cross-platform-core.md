# Cross-Platform Core — SystemOptimizerHub

## Principle

**Contract-first, adapter-second.** All behavior that can be expressed as JSON schema + deterministic logic lives in `SystemOptimizerHub.Core`. OS-specific code never imports domain rules — only implements ports.

## Layer responsibilities

### Core (OS-agnostic)

| Module | PS origin | Status |
|--------|-----------|--------|
| `CatalogLoader` | `Get-ProcessIntelligenceCatalog` | Phase 0 done |
| `ProcessNecessityResolver` | `Resolve-ProcessNecessity` | Phase 0 done |
| `ProcessNecessityResolver.TestCatalogActionBlocked` | `Test-ProcessCatalogActionBlocked` | Phase 0 done |
| `PressureScorer` | `Get-DominantPressure`, composite score | Phase 0 done |
| Transparency policy T0–T3 | `transparency-policy.ps1` | Phase 1 |
| Resolution advisory | `process-resolution-policy.ps1` | Phase 1 |
| Process knowledge merge | `process-knowledge.ps1` | Phase 2 |
| Report builders | `build-transparency-report.ps1` | Phase 2 |

### Abstractions (ports)

```csharp
IProcessSnapshotProvider  // live process metrics
IProcessMutator           // throttle / terminate (HITL gated in Core)
IPlatformServices         // bundles platform + version info
// Phase 2+: IRegistryStore, IDefenderPolicy, IScheduledJobHost, IForensicsReader
```

### Windows adapter

- Process: `System.Diagnostics.Process` (Phase 0)
- Phase 2: WMI/CIM, registry, Defender cmdlets via `Microsoft.PowerShell.SDK` embedded or dedicated NuGet
- Phase 2: Task Scheduler COM wrapper
- Phase 2: PE forensics (port `HubProcessMemoryReader` P/Invoke)

### Linux adapter

- Process: `/proc/{pid}/status`, `/proc/{pid}/stat` (Phase 0 stub)
- Phase 2: renice apply (parity with `apply-process-pressure-safe.sh`)
- Phase 2: systemd user/session awareness
- **Not in scope:** DD-WRT bash stays separate (router NVRAM domain)

## Host applications

| Host | Replaces | Phase |
|------|----------|-------|
| `hub` CLI | Individual `.ps1` invocations | 0–3 |
| `SystemOptimizerHub.Web` | `serve-transparency-dashboard.ps1` | 3 |
| `SystemOptimizerHub.Desktop` (Avalonia) | WinForms + ps2exe | 4 |
| PS thin wrappers | Direct script logic | 1–3 (transition) |

### Transition pattern (no regression)

```powershell
# scripts/resolve-unknown-process.ps1 (transition)
if ($env:HUB_USE_CORE -eq '1') {
    & hub resolve --request-json $RequestJsonPath
    exit $LASTEXITCODE
}
# ... existing PS implementation unchanged
```

Feature flag `HUB_USE_CORE` per domain until parity gate passes.

## Shared configuration

All hosts read the same JSON — **no fork**:

- `config/process-intelligence.json`
- `config/process-knowledge.json`
- `config/process-resolution.json`
- `config/sys-maintenance.json`

Core uses `System.Text.Json` with case-insensitive property names matching PS `ConvertFrom-Json` behavior.

## CLI quick start

```bash
# Build
dotnet build src/SystemOptimizerHub.sln

# Classify (Windows or Linux)
dotnet run --project src/SystemOptimizerHub.Cli -- catalog classify --name MsMpEng

# Version
dotnet run --project src/SystemOptimizerHub.Cli -- version
```

Publish single-file:

```bash
dotnet publish src/SystemOptimizerHub.Cli -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
dotnet publish src/SystemOptimizerHub.Cli -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true
```

## Quality gates

| Gate | Command |
|------|---------|
| Core unit tests | `dotnet test src/SystemOptimizerHub.sln` |
| PS smoke (unchanged) | `powershell -File scripts/test-hub-smoke.ps1` |
| Core parity | `powershell -File scripts/test-core-parity.ps1` |
| GUI PS5.1 parse | `powershell.exe -File scripts/test-gui-parse-ps51.ps1` |

Parity gate rule: **C# output must match PS golden JSON** for the same catalog + inputs before `HUB_USE_CORE=1` is enabled for that domain.
