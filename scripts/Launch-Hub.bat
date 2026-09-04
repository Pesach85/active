@echo off
setlocal
set "HUBROOT=%~dp0"
if "%HUBROOT:~-1%"=="\" set "HUBROOT=%HUBROOT:~0,-1%"
REM Prefer live GUI script so DevSync / package updates are visible without stale PS2EXE embeds.
if exist "%HUBROOT%\scripts\system-optimizer-gui.ps1" (
  set "PWSH="
  if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
  if not defined PWSH if exist "D:\Powershell\7\pwsh.exe" set "PWSH=D:\Powershell\7\pwsh.exe"
  if defined PWSH (
    start "" "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\system-optimizer-gui.ps1"
  ) else (
    where pwsh >nul 2>&1
    if not errorlevel 1 (
      start "" pwsh -NoProfile -ExecutionPolicy Bypass -File "%HUBROOT%\scripts\system-optimizer-gui.ps1"
    ) else (
      start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HUBROOT%\scripts\system-optimizer-gui.ps1"
    )
  )
  exit /b 0
)
if exist "%HUBROOT%\WindowsOptimizer.exe" (
  start "" "%HUBROOT%\WindowsOptimizer.exe"
  exit /b 0
)
echo [ERROR] GUI not found under "%HUBROOT%"
pause
exit /b 1
