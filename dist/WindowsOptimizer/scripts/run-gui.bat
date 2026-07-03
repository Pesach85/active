@echo off
setlocal
set "SCRIPTDIR=%~dp0"
set "HUBROOT=%SCRIPTDIR%.."
if exist "%HUBROOT%\dist\WindowsOptimizer\WindowsOptimizer.exe" (
  start "" "%HUBROOT%\dist\WindowsOptimizer\WindowsOptimizer.exe"
) else if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\system-optimizer-gui.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\system-optimizer-gui.ps1"
)
