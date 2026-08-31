@echo off
setlocal EnableExtensions
cd /d "%~dp0.."

set "PS_EXE="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PS_EXE if exist "%ProgramFiles%\PowerShell\7-preview\pwsh.exe" (
    set "PS_EXE=%ProgramFiles%\PowerShell\7-preview\pwsh.exe"
)
if not defined PS_EXE (
    where pwsh >nul 2>&1 && set "PS_EXE=pwsh"
)
if not defined PS_EXE (
    where powershell >nul 2>&1 && set "PS_EXE=powershell" || set "PS_EXE=powershell.exe"
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-transparency-web.ps1" -OpenBrowser
exit /b %ERRORLEVEL%
