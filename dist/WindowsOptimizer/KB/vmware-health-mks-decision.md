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
- GUI: **Home primary row → Salute VMware / VMware Health** and **Health tab** (Yes=audit, No=apply)
- Report: `logs/vmware-health-latest.json` (`VmwareHealthReport.v1`)
- Roots: `config/sys-maintenance.json` → `Vmware.InventoryRoots` (default includes `D:\Macchine_Virtuali`)

## Ship lesson (2026-09-04 follow-up)

`Launch-Hub.bat` used to prefer `WindowsOptimizer.exe` (PS2EXE embed). Production junction had updated **scripts**, but the desktop shortcut launched a **stale EXE (2026-08-31)** without the VMware button — user correctly reported “button missing”.

**Fix:**
1. `Launch-Hub.bat` prefers live `scripts/system-optimizer-gui.ps1` when present (DevSync-safe).
2. VMware Health promoted to Home primary actions + Health tab (not only collapsed More tools).
3. Rebuild EXE on deploy (`dev-sync-production.ps1 -BuildGui`) so icon/fallback matches.

## Guest notes

Host-side inventory/locks/MKS apply to XP / 7 / 10 alike. Guest-family notes only advise Tools/3D fragility (esp. Win7 industrial + modern host GPU).
