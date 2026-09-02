# ADR-0008: Multi-platform install and client strategy

## Status

Accepted — 2026-09-02

## Context

Hub needs to behave as installable Windows software (shortcuts, uninstall, scheduled tasks) while keeping dev edits instantly visible in the "installed" app. Linux and Android were requested for cross-platform operation.

## Decision

### Windows

- **Install profile:** `config/install-profile.json`
- **Dev-sync (default in dev):** NTFS junction `{LOCALAPPDATA}\Programs\SystemOptimizerHub\app` → `{repo}\dist\WindowsOptimizer`
- **Refresh:** `dev-sync-production.ps1` runs `package-suite.ps1` (+ optional GUI build)
- **Shortcuts:** Start Menu folder + optional Desktop via WScript.Shell
- **Production installer:** Inno Setup script optional; copies dist mirror when `-NoDevSync`

### Linux

- User-scope install under `~/.local/opt/systemoptimizerhub`
- `package-linux-suite.ps1` publishes self-contained `hub` binary (`linux-x64`)
- Bash PPI scripts retained; Core Linux mutator implements `renice`/`kill`
- systemd user timer for periodic `hub analyze pressure`

### Android (revised v0.9.0 — 2026-09-02)

- **Native maintenance APK** (`mobile/android`) — monitors THIS device (RAM, storage, processes)
- `DeviceMaintenanceEngine.kt` — pressure tier, process trust/advisory, storage hotspots
- **NOT** a WebView client to PC transparency dashboard (v0.8 WebView MVP was incorrect scope)
- Build: `config/android-build.json`, `build-android-apk.ps1`
- Safe actions via Android Settings intents; no silent cross-app kill without user

## Consequences

- Developers must run `dev-sync-production.ps1` after code changes (or rely on junction + package only)
- Android per-app metrics limited by sandbox unless usage-access granted
- Inno Setup build is optional separate step from PS install

## References

- `KB/multi-platform-install-decision.md`
- `docs/product/ROADMAP.md` §3.3
- ADR-0002, ADR-0007
