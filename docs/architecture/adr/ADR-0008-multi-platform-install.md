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

### Android (v1.1.0 UX — 2026-09-02)

- **Native maintenance APK** — engine v1.0 (analisi on-device) + **UX v1.1** basso carico cognitivo
- `UiPresenter.kt`: tier → copy italiano; metriche GB; max 3 azioni; dettagli collassati
- Modular engine unchanged: process pressure, storage, waste, memory, battery/network/boot, transparency JSON
- **NOT** WebView client to PC dashboard
- Build: `config/android-build.json`, `build-android-apk.ps1`

## Consequences

- Developers must run `dev-sync-production.ps1` after code changes (or rely on junction + package only)
- Android per-app metrics limited by sandbox unless usage-access granted
- Inno Setup build is optional separate step from PS install

## References

- `KB/multi-platform-install-decision.md`
- `docs/product/ROADMAP.md` §3.3
- ADR-0002, ADR-0007
