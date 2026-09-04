# VMware Health — mksSandbox / ISBRendererComm repair decision

**Date:** 2026-09-04  
**Trigger:** Workstation dialog `ISBRendererComm: Lost connection to mksSandbox (3093)` on Win10 LTSC Rockwell VM.

## Decision

| Signal | Action |
|--------|--------|
| Log hit `Lost connection to mksSandbox` / `unrecoverable error: (mks)` | Finding `VMWARE-MKS-001` |
| `mks.enable3d = TRUE` (or unset) + MKS crash | Safe repair `REPAIR-DISABLE-3D` after `.vmx` backup under `logs/vmware-vmx-rollback/` |
| `.lck` present + **no** live `vmware-vmx` for that `.vmx` | Safe repair `REPAIR-CLEAR-STALE-LOCKS` |
| `.lck` + live `vmware-vmx` | Info only — do **not** clear |
| Missing `.vmdk` / snapshot delete / service restart / `vm-support` | HITL only |
| VM powered on | Refuse mutating repairs (`SkippedPoweredOn`) |

## Entry points

- CLI: `scripts/analyze-vmware-health.ps1` (audit default; `-Apply` for safe repairs)
- GUI: **More tools → VMware Health** (Yes=audit, No=apply)
- Report: `logs/vmware-health-latest.json` (`VmwareHealthReport.v1`)
- Roots: `config/sys-maintenance.json` → `Vmware.InventoryRoots` (default includes `D:\Macchine_Virtuali`)

## Guest notes

Host-side inventory/locks/MKS apply to XP / 7 / 10 alike. Guest-family notes only advise Tools/3D fragility (esp. Win7 industrial + modern host GPU).
