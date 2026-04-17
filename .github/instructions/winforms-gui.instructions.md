---
applyTo: "scripts/system-optimizer-gui.ps1"
description: "Mandatory anti-pattern checks for PowerShell WinForms GUI edits. Read KB/powershell-winforms-patterns.md BEFORE making any change."
---

# PowerShell WinForms GUI — Mandatory Pre-Edit Gate

Before editing `scripts/system-optimizer-gui.ps1`, you **MUST**:

1. Read `KB/powershell-winforms-patterns.md` (anti-pattern catalog)
2. Verify every change against the checklist in that file
3. After editing: parser check → rebuild EXE → smoke test ≥ 5 seconds

## Critical patterns (summary)

- **Dock z-order**: `Dock=Fill` control added FIRST (lowest index). Edge controls added AFTER.
- **Event handler scope**: Never close over function-local vars in `.Add_Tick` / `.Add_Click`. Use `.Tag` + `$sender`.
- **Arithmetic safety**: Cast WinForms properties to `[int]` before math.
- **Layout guard**: Wrap multi-control additions in `SuspendLayout` / `ResumeLayout`.
- **Transient forms**: `try/catch`, `IsDisposed` guard, `.Tag`-based timer lifecycle.

Failure to follow these patterns has caused Bugs 17, 18, 19 (see `KB/bugs-fixed.md`).
