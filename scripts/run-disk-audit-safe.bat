@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File C:\scripts\audit-disk-hotspots.ps1 -Drives C,D -Top 30
pause
