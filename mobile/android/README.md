# System Optimizer Hub — Android transparency client (MVP)

WebView shell for the Hub transparency dashboard. Does **not** run maintenance on the phone — connects to a PC/Linux host running `serve-transparency-dashboard.ps1` or future ASP.NET host.

## Default URL

- Emulator / USB reverse: `http://127.0.0.1:8765`
- LAN: `http://<PC_IP>:8765` (ensure firewall allows 8765)

## Build APK

Toolchain paths from **I_Tuoi_Versetti** (`config/android-build.json`):

| Setting | Path |
|---------|------|
| SDK | `D:\Android\Sdk` |
| JDK | `D:\JDK_17` |

```powershell
powershell -File scripts/build-android-apk.ps1 -Variant debug
# Output: dist/android/SystemOptimizerHub-transparency-debug.apk
powershell -File scripts/test-install-smoke.ps1 -BuildApk
```

Or open `mobile/android` in Android Studio → Build → Build APK.

## Scope (MVP)

- Read-only transparency UI via WebView
- Configurable hub URL (persisted)
- Cleartext HTTP allowed for local/LAN dev (see `network_security_config.xml`)

## Future

- mTLS / token auth for remote access
- Native notifications from hub webhooks
- Not a replacement for Windows/Linux maintenance engine (ADR-0008)
