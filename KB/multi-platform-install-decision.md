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
| Android | **Native maintenance engine v0.9** on device (RAM/storage/processes) | **Pivot 2026-09-02:** WebView→PC era errata; parity intent con Windows/Linux PPI locale |
| APK build | Gradle in `mobile/android/` + `config/android-build.json` | SDK `D:\Android\Sdk`, JDK `D:\JDK_17` (da I_Tuoi_Versetti) |

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
| Android senza SDK in CI locale | `config/android-build.json` risolve path non standard (I_Tuoi_Versetti) |
| Gradle wrapper jar non in repo | Aggiunto gradlew + wrapper jar da Gradle 8.7 |
| `package-linux-suite.ps1` line continuation | Rimossi blank line tra backtick (parse `-p:`) |
| Em-dash in PS throw string | Sostituito con `-` ASCII in windows-app-install.ps1 |
| Em-dash in dev-sync-production.ps1 | Stesso fix ASCII dash (parse error PS) |
| Switch `$Desktop` vs path case-insensitive | Rinominato in `CreateDesktopShortcuts` / `desktopFolder` |

## Android native maintenance (v0.9.0)

**Correzione requisito:** l'app Android NON deve monitorare il PC via WebView. Deve eseguire manutenzione sul dispositivo Android installato.

Componenti:
- `DeviceMaintenanceEngine.kt` — analyze locale
- `MainActivity` — dashboard nativa (pressure, processi, storage, azioni safe)

```powershell
powershell -File scripts/build-android-apk.ps1
powershell -File scripts/install-android-apk.ps1 -Launch
powershell -File scripts/test-android-device-smoke.ps1
```

Limiti Android: kill force-stop solo via Settings utente; per-app RAM richiede usage access opzionale.

## Android build (toolchain I_Tuoi_Versetti)

```powershell
# config/android-build.json — SdkDir D:\Android\Sdk, JavaHome D:\JDK_17
powershell -File scripts/build-android-apk.ps1
powershell -File scripts/test-install-smoke.ps1 -BuildApk
```

## Quality gate

- `scripts/test-install-smoke.ps1` (+ `-DeviceSmoke` when adb device)
- `scripts/test-android-device-smoke.ps1` (native on-device — no PC :8765)
- `dotnet test` (Linux mutator)
- `test-hub-smoke.ps1` (auto DeviceSmoke if adb connected)
- `package-suite.ps1` + `package-linux-suite.ps1`
