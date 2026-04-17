# PowerShell WinForms Anti-Pattern Catalog

> Patterns distilled from real bugs (17–19) in this project.
> **Every agent touching the GUI MUST read this file first.**

---

## Pattern 1 — WinForms Dock Z-Order (Bug 19)

### Rule
When combining `Dock=Top`, `Dock=Bottom`, and `Dock=Fill` controls in the same container, **add the `Dock=Fill` control FIRST** (lowest index). Edge-docked controls must have higher indices.

### Why
WinForms `DefaultLayout` processes child controls from the **highest index to lowest**. If Fill is at the highest index it's processed first, consuming the entire client area. Edge-docked controls then overlay on top without reducing the Fill area — they **cover** it instead of reserving space.

### Correct pattern
```powershell
$form.SuspendLayout()
$form.Controls.Add($fillCtrl)      # index 0 → processed last  → gets remaining space
$form.Controls.Add($bottomPanel)   # index 1 → processed second → reserves bottom N px
$form.Controls.Add($topPanel)      # index 2 → processed first  → reserves top N px
$form.ResumeLayout($false)
```

### Wrong pattern (causes overlap)
```powershell
$form.Controls.Add($topPanel)      # index 0
$form.Controls.Add($bottomPanel)   # index 1
$form.Controls.Add($fillCtrl)      # index 2 → processed FIRST → grabs all space
```

### Diagnostic
- Tab strip invisible or clipped behind header → check Controls add order.
- Use `$ctrl.Bounds` after `ResumeLayout` to confirm layout.

---

## Pattern 2 — PowerShell .NET Event Handler Scoping (Bugs 17, 18)

### Rule
**Never reference function-local variables inside `.Add_Tick()`, `.Add_Click()`, or any .NET event handler scriptblock** when the handler fires after the function has returned.

### Why
PowerShell scriptblocks used as .NET event delegates do NOT create true closures over the enclosing function's local variables. When the function exits, those variables go out of scope and resolve to `$null` when the event fires later.

### Correct pattern — use `.Tag` + `$sender`
```powershell
$timer.Tag = $targetObject          # store ref in Tag
$timer.Add_Tick({
    param($sender, $eArgs)          # $sender IS the timer
    $target = $sender.Tag           # retrieve ref from Tag
    $sender.Stop()
    if ($target -and -not $target.IsDisposed) {
        $target.Close()
    }
    $sender.Dispose()
})
$timer.Start()
```

### Wrong pattern (null at fire time)
```powershell
$localRef = $someForm
$timer.Add_Tick({ $localRef.Close(); $timer.Stop() })   # $localRef → $null later
```

### Safe alternatives (when Tag is not enough)
- `$script:` scoped variable — accessible from any scriptblock in the script.
- `Register-ObjectEvent` — explicitly captures scope via `-Action {}`.
- DataSource dictionary stored at `$script:` scope.

### Diagnostic
- `Impossibile chiamare un metodo su un'espressione con valore null` after a delay → event handler scoping issue.
- Verify all `.Add_*` handlers reference only `$script:` vars, `$sender`, or `.Tag`.

---

## Pattern 3 — Arithmetic on WinForms Properties in PowerShell (Bug 17)

### Rule
Before performing arithmetic (`-`, `+`, `*`) on WinForms property values, **cast to `[int]` explicitly**. Some properties can resolve to `Object[]` in certain runtime/multi-monitor contexts.

### Why
PowerShell's pipeline and property accessor can return arrays instead of scalars, e.g. `$screen.Right` may become `@(1920)` instead of `1920`. The `-` operator on `Object[]` triggers `op_Subtraction` which doesn't exist.

### Correct pattern
```powershell
$right  = [int]$workingArea.Right
$bottom = [int]$workingArea.Bottom
$x = [Math]::Max(0, $right - 378)
```

### Wrong pattern
```powershell
$x = $screen.Right - 378       # may fail: Object[] has no op_Subtraction
```

### Extra safety for event handlers (where scope can mutate types)
```powershell
$w = [int](@($s.ClientSize.Width) | Select-Object -First 1)
```

---

## Pattern 4 — SuspendLayout / ResumeLayout Guard

### Rule
When adding 3+ controls with `Dock` properties to the same container, wrap in `SuspendLayout()` / `ResumeLayout($false)`.

### Why
Each `.Controls.Add()` triggers a layout pass. Intermediate states with partial control sets can cause incorrect sizing that persists even after all controls are added (stale layout cache).

### Template
```powershell
$container.SuspendLayout()
# Add ALL children here
$container.Controls.Add($child1)
$container.Controls.Add($child2)
$container.Controls.Add($child3)
$container.ResumeLayout($false)    # $false = don't force immediate
```

---

## Pattern 5 — Toast / Transient Form Lifecycle

### Rule
Transient popup forms (toasts, notifications) that auto-close via timer must:
1. Use Tag-based references (Pattern 2)
2. Guard `.Close()` with `IsDisposed` check
3. Wrap entire creation in `try/catch` with degradation to status log
4. Never block the main UI thread

### Template
```powershell
function Show-Toast {
    param([string]$Title, [string]$Body, [string]$Level = "Info")
    try {
        $toast = New-Object System.Windows.Forms.Form
        # ... set properties ...
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 4500
        $timer.Tag  = $toast
        $toast.Tag  = $timer    # prevent GC
        $timer.Add_Tick({
            param($sender, $eArgs)
            $sender.Stop()
            $ref = $sender.Tag
            if ($ref -and -not $ref.IsDisposed) { $ref.Close() }
            $sender.Dispose()
        })
        $timer.Start()
        $toast.Show($parentForm)   # non-blocking
    } catch {
        Append-Status ("Toast warning: {0}" -f $_.Exception.Message)
    }
}
```

---

## Quick Reference — Bug → Pattern Map

| Bug | Error Message (IT) | Pattern Violated |
|-----|-------------------|-----------------|
| 17 | `[System.Object[]] non contiene op_Subtraction` | #3 Arithmetic on WinForms properties |
| 18 | `Impossibile chiamare un metodo su valore null` | #2 Event handler scoping |
| 19 | Tab strip hidden / buttons under header | #1 Dock z-order |

---

## Checklist for Future GUI Changes

- [ ] Any new `Dock=Fill` control added FIRST to its container (Pattern 1)
- [ ] All `.Add_*` event handlers use `$sender`/`.Tag` or `$script:` vars, never function locals (Pattern 2)
- [ ] All arithmetic on WinForms properties uses `[int]` cast (Pattern 3)
- [ ] Multi-control containers wrapped in `SuspendLayout`/`ResumeLayout` (Pattern 4)
- [ ] Transient forms (toasts) fully guarded with `try/catch` + `IsDisposed` (Pattern 5)
- [ ] After ANY GUI edit: run parser check → rebuild EXE → smoke test 5+ seconds
