# Process Pressure Intelligence (PPI)

Deterministic engine for identifying resource-heavy processes (CPU, RAM, disk I/O) with vital-process preservation and safe auto vs HITL remediation paths.

## Components

| Artifact | Role |
|----------|------|
| `config/process-intelligence.json` | Catalog: vital/security/platform patterns, known apps, mitigations, references |
| `scripts/lib/process-pressure-core.ps1` | Shared scoring, necessity classification, action resolution |
| `scripts/analyze-process-pressure.ps1` | Windows analyzer → `ProcessPressureReport.v1` |
| `scripts/apply-process-pressure-safe.ps1` | Audit-first apply (Safe: `LowerProcessPriority` only) + rollback JSON |
| `scripts/analyze-compute-resources.ps1` | Legacy wrapper (backward-compatible JSON) |
| `scripts/linux/analyze-process-pressure.sh` | Linux analyzer (same schema subset) |

## Scoring (deterministic)

Two snapshots `DurationSec` apart (default 6s):

- **CPU%** = delta CPU time / (duration × logical processors)
- **Memory** = working set MB (cap 8192 for normalization)
- **IO MB/s** = delta IO bytes / duration (cap 400 MB/s)
- **Score** = 0.50×CPU + 0.30×Memory + 0.20×IO (each normalized 0–100)
- **DominantPressure** = max of normalized CPU / Memory / IO

## Necessity classes

| Priority | Meaning | Auto-action |
|----------|---------|-------------|
| Keep | OS core, security | Never modify |
| Tune | Platform / known apps | Safe throttle or HITL tuning |
| Review | Unknown / optional background | HITL before disable/kill |

## Safe apply gate

`apply-process-pressure-safe.ps1`:

- Skips `Priority=Keep`
- Skips score &lt; 40
- Default `MaxLevel=Safe` → only `LowerProcessPriority` (reversible)
- Writes `ProcessPressureRollback.v1` before changes
- `-DryRun` for audit-only

## GUI integration (v3.3.0)

Compute button runs `analyze-process-pressure.ps1` with `-IncludeResearch`. Status log shows Necessity, Priority, and legacy Recommendation.

## Cross-platform

- **Windows**: full catalog + apply script
- **Linux**: `scripts/linux/analyze-process-pressure.sh` + `scripts/package-linux-suite.ps1` → `dist/LinuxOptimizer/`

## Operational runbook

1. Run analyze (GUI or CLI) → review `logs/process-pressure-latest.json`
2. Confirm no false positives on vital/security (`Summary.VitalPreserved`)
3. Optional: `apply-process-pressure-safe.ps1 -InputJson ... -MaxLevel Safe -DryRun`
4. Apply without `-DryRun` if satisfied
5. Rollback: restore priorities from rollback JSON if needed

## References

- Microsoft Defender tuning: catalog `MsMpEng.references`
- Browser/IDE mitigations: per-app entries in `knownApplications`
