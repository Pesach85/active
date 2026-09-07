# System Optimizer Hub — Android native maintenance client

Monitors and maintains **this Android device** (RAM, storage, running processes) — same product mission as Windows/Linux Hub, not a remote PC viewer.

## Features (v0.9.0)

- `DeviceMaintenanceEngine` — local RAM/storage/process analysis
- Pressure tier (Low/Medium/High/Critical) + score
- Running process list with trust/advisory labels
- Storage hotspots on internal partition
- Safe actions: open storage settings, app settings, usage access

## Build & install

```powershell
powershell -File scripts/build-android-apk.ps1
powershell -File scripts/install-android-apk.ps1 -Launch
powershell -File scripts/test-android-device-smoke.ps1
```

Toolchain: `config/android-build.json` (SDK `D:\Android\Sdk`, JDK `D:\JDK_17` from I_Tuoi_Versetti).

## Limitations (Android)

- Per-app RAM without usage-access permission is limited by Android sandbox
- Force-stop/kill other apps requires user action in Settings (no silent kill)
- Root-only ops shown as advisory only

## Deprecated

WebView MVP pointing to PC `:8765` transparency dashboard — removed in v0.9.0 (ADR-0008 revision).
