@echo off
if exist C:\SystemOptimizerHub\active\dist\WindowsOptimizer\WindowsOptimizer.exe (
  start "" C:\SystemOptimizerHub\active\dist\WindowsOptimizer\WindowsOptimizer.exe
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\SystemOptimizerHub\active\scripts\system-optimizer-gui.ps1
)
