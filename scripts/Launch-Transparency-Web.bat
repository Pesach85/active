@echo off
setlocal
set "HUBROOT=%~dp0"
if "%HUBROOT:~-1%"=="\" set "HUBROOT=%HUBROOT:~0,-1%"
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\run-transparency-web.ps1" -OpenBrowser
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\run-transparency-web.ps1" -OpenBrowser
)
