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
| Android | **Native maintenance engine v1.0** on device (parity PPI + waste + transparency) | Pivot v0.9→v1.0: moduli engine, analisi profonde, ottimizzazioni Android-specific |
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
| `test-android-device-smoke` `$Args` param | Rinominato `Invoke-AdbCommand -Command`; regex tab-separated `device` |
| Smoke foreground false negative Motorola | Wake screen + `ResumedActivity:` regex + cold start `-S` |

## Android native maintenance (v1.0.0)

**Correzione requisito:** l'app Android NON deve monitorare il PC via WebView. Deve eseguire manutenzione sul dispositivo Android installato con **parity analitica** rispetto al desktop (adattata al platform).

### Parity matrix (desktop → Android)

| Desktop (Windows/Linux) | Android v1.0 | Note |
|-------------------------|--------------|------|
| Process pressure (PPI) | `ProcessPressureEngine` | Running processes, importance, trust T1/T2/T3 |
| Storage / garbage hotspots | `StorageHotspotAnalyzer` | StatFs + `StorageStatsManager` per-app cache/data |
| Resource waste | `WasteResourceAnalyzer` | Cache hotspots, background compute, cached process count |
| Memory liberation | `MemoryLiberationAdvisor` | Clear own cache, memory trim hint, Settings intents |
| Transparency report | `TransparencyReportBuilder` | JSON export `AndroidTransparencyReport.v1` |
| Network snapshot | `NetworkSnapshotService` | Wi-Fi/cellular/VPN, metered, TrafficStats totals |
| Battery pressure | `BatteryPressureSignal` | Level, charging, power save bonus on pressure score |
| Boot / startup audit | `BootAppsAuditor` | BOOT_COMPLETED receivers |
| Trust / catalog | `AppTrustClassifier` + `process-intelligence-android.json` | T1 system, T2 tunable, T3 unknown |
| Usage / background | `UsageStatsCollector` | Optional usage access for 24h fg/bg minutes |

### Android-specific (non su desktop)

- Per-app cache via `StorageStatsManager` (API 26+)
- Cached process count waste signal (Android LRU)
- Usage access gate for background-heavy apps
- Safe actions only: Settings intents, own cache clear, report export (no force-stop/kill)

### Engine modules

```
DeviceMaintenanceEngine.kt (orchestrator)
engine/ProcessPressureEngine.kt
engine/StorageHotspotAnalyzer.kt
engine/WasteResourceAnalyzer.kt
engine/MemoryLiberationAdvisor.kt
engine/BatteryPressureSignal.kt
engine/NetworkSnapshotService.kt
engine/BootAppsAuditor.kt
engine/AppTrustClassifier.kt
engine/UsageStatsCollector.kt
report/TransparencyReportBuilder.kt
assets/process-intelligence-android.json
```

```powershell
powershell -File scripts/build-android-apk.ps1
powershell -File scripts/install-android-apk.ps1 -Launch
powershell -File scripts/test-android-device-smoke.ps1
```

Limiti Android: kill force-stop solo via Settings utente; per-app RAM richiede usage access opzionale.

### Live device smoke (v1.0.0)

| Check | Esito |
|-------|-------|
| Device | Motorola Edge 40 (`ZY22HFWMGV`) |
| APK v1.0.0 install + cold start | ✓ |
| Foreground (ResumedActivity) | ✓ (dopo fix wake + regex) |
| Logcat no FATAL | ✓ |
| No WebView/PC dependency | ✓ |
| Engine analyze background thread | ✓ (fix ANR risk) |

### Problemi risolti (live smoke 2026-09-02 19:05)

| Problema | Causa | Fix |
|----------|-------|-----|
| `native dashboard foreground FAIL` | Schermo spento/lock → launcher in `ResumedActivity`; regex cercava solo `topResumedActivity=` (assente su Motorola/Android 14) | `Ensure-DeviceAwake` (WAKEUP + dismiss-keyguard), cold start `-S`, regex multi-campo (`ResumedActivity:`, `mFocusedApp=`, `topResumedActivity=`), retry launch |
| Doppio refresh onCreate+onResume | `refresh()` chiamato due volte al boot | Solo `onResume` avvia refresh |
| Analyze su UI thread | `StorageStatsManager` + process scan lenti → rischio jank/ANR | `engine.analyze()` in worker thread, `runOnUiThread` per render |

## Android native maintenance (v0.9.0 — superseded)

| Check | Esito |
|-------|-------|
| Device | Motorola Edge 40 (`ZY22HFWMGV`) |
| APK v0.9.0 install + launch | ✓ |
| Native dashboard foreground | ✓ |
| Logcat no FATAL | ✓ |
| No WebView/PC dependency | ✓ |

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
