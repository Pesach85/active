@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File C:\scripts\ensure-powershell-core.ps1 -InstallIfMissing -UpdateMachinePath -ApplyTasksCoreOnly
pause
