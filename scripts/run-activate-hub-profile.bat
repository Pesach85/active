@echo off
setlocal
set "SCRIPTDIR=%~dp0"
set "HUBROOT=%SCRIPTDIR%.."
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\activate-hub-profile.ps1" -InstallCoreIfMissing -UpdateMachinePath
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\activate-hub-profile.ps1" -InstallCoreIfMissing -UpdateMachinePath
)
