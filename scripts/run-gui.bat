@echo off
if exist C:\dist\WindowsOptimizer\WindowsOptimizer.exe (
  start "" C:\dist\WindowsOptimizer\WindowsOptimizer.exe
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\scripts\system-optimizer-gui.ps1
)
