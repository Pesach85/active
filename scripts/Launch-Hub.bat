@echo off
setlocal
set "HUBROOT=%~dp0"
if "%HUBROOT:~-1%"=="\" set "HUBROOT=%HUBROOT:~0,-1%"
if exist "%HUBROOT%\WindowsOptimizer.exe" (
  start "" "%HUBROOT%\WindowsOptimizer.exe"
  exit /b 0
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\system-optimizer-gui.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\system-optimizer-gui.ps1"
)
