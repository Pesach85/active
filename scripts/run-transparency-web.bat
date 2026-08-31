@echo off
setlocal
cd /d "%~dp0.."
where pwsh >nul 2>&1 && set PS=pwsh || set PS=powershell
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure-transparency-web.ps1"
if errorlevel 1 exit /b 1
start "" "http://127.0.0.1:8765/"
exit /b 0
