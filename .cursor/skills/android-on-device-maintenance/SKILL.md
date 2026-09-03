---
name: android-on-device-maintenance
description: >-
  Build, install, smoke-test, and maintain the native Android on-device app
  (System Optimizer Hub). Use for APK build, ADB install, device smoke,
  refresh/UX bugs, engine modules, or Android parity with desktop analyses.
  Never treat the Android app as a WebView client to the PC dashboard.
---

# Android on-device maintenance

## Scope corretto

L'APK analizza **questo dispositivo Android** (RAM, storage, processi, waste, batteria, rete). **Non** è un client WebView verso PC `:8765`.

## Toolchain

- Config: `config/android-build.json` (SDK `D:\Android\Sdk`, JDK `D:\JDK_17`)
- Build: `scripts/build-android-apk.ps1`
- Install: `scripts/install-android-apk.ps1 -Launch`
- Smoke: `scripts/test-android-device-smoke.ps1`
- Codice: `mobile/android/`
- Engine: `DeviceMaintenanceEngine` + `engine/*` + `ui/UiPresenter.kt`
- APK out: `dist/android/SystemOptimizerHub-android-debug.apk` (gitignored)

## Workflow standard

1. Build debug APK
2. `adb devices` — se nessuno, stop e chiedere USB/debug
3. Install + Launch (wake: smoke fa WAKEUP + dismiss-keyguard)
4. Smoke device (version 1.x, no WebView, no FATAL)
5. Se bug UX/refresh: logcat tag `HubAndroid`, fix, bump `versionCode`/`versionName`, reinstall

```powershell
powershell -File scripts/build-android-apk.ps1
powershell -File scripts/install-android-apk.ps1 -Launch
powershell -File scripts/test-android-device-smoke.ps1
```

## UX (v1.1+)

- Prima vista: stato umano + 3 metriche + max 3 azioni
- Dettagli tecnici collassati
- Copy italiano (`strings.xml` + `UiPresenter`)
- Analyze off UI thread; permesso `ACCESS_NETWORK_STATE` obbligatorio

## Problemi noti (consultare KB)

`KB/multi-platform-install-decision.md` — sezione Android v1.0/v1.1 e tabella problemi risolti (foreground smoke, network permission, storage scan cap).

## Hard don'ts

- Non reintrodurre WebView → PC
- Non force-stop altre app in silenzio (solo Settings intents / own cache)
- Non dichiarare smoke PASS senza device se lo smoke live era richiesto
