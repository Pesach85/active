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

## Microsoft Defender / MsMpEng — extreme necessity

**Can you disable MsMpEng/Defender?** Yes, **only** through the gated HITL ladder — never auto.

| Tier | Composite score | Action | Risk |
|------|-----------------|--------|------|
| Observe | &lt; 55 | Monitor only | None |
| TuneExclusions | 55–69 | `Add-MpPreference -ExclusionPath` + scan schedule | Low (AV stays on) |
| TemporaryRealtimeOff | 70–84 | `Set-MpPreference -DisableRealtimeMonitoring` (max 60 min) | High — needs Tamper Protection off |
| ExtremeServiceDisable | ≥ 85 | `Stop-Service WinDefend` (max 120 min) | Critical — double confirm + rollback timer |

Scripts: `evaluate-defender-extreme-necessity.ps1` → `apply-defender-extreme-necessity.ps1` → `restore-defender-from-rollback.ps1`

GUI: **Defender KEEP…** button opens evaluation + wizard (3 checkbox + phrase + 3 MessageBox + admin UAC).

### KEEP GUI confirmation gates (v3.5.0)

1. Intro Yes/No before wizard
2. Three explicit checkboxes (risk, prerequisites, responsibility)
3. Typed phrase `DISABLE DEFENDER` (catalog-configurable)
4. MessageBox confirm 1/3 — tier summary
5. MessageBox confirm 2/3 — reduced protection
6. MessageBox confirm 3/3 — final (extra warning for ExtremeServiceDisable)
7. UAC elevation if not already admin
8. Dry-run available without persisting changes

Only processes in `keepExtremeDisableAllowlist` (currently MsMpEng) — core OS (lsass, csrss) never appear.

## Overcoming prior limits

| Limit | Resolution |
|-------|------------|
| Linux apply manual | `scripts/linux/apply-process-pressure-safe.sh` (renice + rollback JSON) |
| No GUI apply | **Safe Throttle** button + post-compute prompt |
| Defender disable blocked | Deterministic evaluation + tiered HITL apply + GUI wizard |
| Research static only | Catalog `extremeNecessityDefender` + escalation ladder in eval JSON |

## References

- Microsoft Defender tuning: catalog `MsMpEng.references`
- Browser/IDE mitigations: per-app entries in `knownApplications`
