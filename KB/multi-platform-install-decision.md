# Multi-platform install — decision log

## Decisioni (2026-09-02)

| Decisione | Scelta | Rationale |
|-----------|--------|-----------|
| Windows dev → prod immediato | **Junction dev-sync** default (`install-windows-app.ps1 -DevSync`) | Modifiche in repo visibili subito in app installata senza reinstall |
| Install root | `%LOCALAPPDATA%\Programs\SystemOptimizerHub\app` | No admin, per-user, ADR-0002 portable |
| Shortcuts | Start Menu + Desktop opzionale + taskbar pin best-effort | COM `taskbarpin` può fallire su Win11 — documentato |
| Installer production | Inno Setup (`installer/SystemOptimizerHub.iss`) + PS install | ROADMAP 3.3; PS per fase dev |
| Linux scope | User prefix + `hub` single-file + systemd user timer | No root; parity CLI; bash PPI retained |
| Linux mutator | `renice`/`kill` via Core Linux | Rimosso stub PlatformNotSupported per throttle/terminate base |
| Android | **WebView MVP** verso transparency :8765 | Nessun engine manutenzione su device; ADR-0008 |
| APK build | Gradle in `mobile/android/` | Richiede JDK17 + Android SDK; script `build-android-apk.ps1` |

## Workflow dev (Windows)

```powershell
# Prima install (junction dev-sync + shortcut desktop)
powershell -File scripts/install-windows-app.ps1 -DevSync -Desktop -RegisterTasks

# Dopo ogni modifica codebase
powershell -File scripts/dev-sync-production.ps1

# App installata punta a dist via junction — aggiornamento immediato
```

## Workflow Linux

```powershell
powershell -File scripts/package-linux-suite.ps1
# on Linux host:
chmod +x dist/LinuxOptimizer/scripts/linux/install-linux-suite.sh
./dist/LinuxOptimizer/scripts/linux/install-linux-suite.sh
```

## Problemi incontrati

| Problema | Soluzione |
|----------|-----------|
| `install-suite.ps1` incompleto (no lib/gui/hub) | Delegato a `install-windows-app.ps1` + `package-suite.ps1` |
| `uninstall-suite` path legacy `C:\SystemOptimizer` | Allineato a manifest + `install-profile.json` |
| `run-gui.bat` path errato in dist | `Launch-Hub.bat` in root dist con HUBROOT=%~dp0 |
| Taskbar pin programmatico fragile | `-PinToTaskbar` best-effort + messaggio manuale |
| Android senza SDK in CI locale | Smoke valida skeleton; APK build opzionale con SDK |
| Gradle wrapper jar non in repo | Aggiunto gradlew + wrapper jar da Gradle 8.7 |
| `package-linux-suite.ps1` line continuation | Rimossi blank line tra backtick (parse `-p:`) |
| Em-dash in PS throw string | Sostituito con `-` ASCII in windows-app-install.ps1 |
| Switch `$Desktop` vs path case-insensitive | Rinominato in `CreateDesktopShortcuts` / `desktopFolder` |

## Quality gate

- `scripts/test-install-smoke.ps1`
- `dotnet test` (Linux mutator)
- `test-hub-smoke.ps1` (existing)
- `package-suite.ps1` + `package-linux-suite.ps1`
