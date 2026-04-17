Windows Optimizer Suite

Install:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\install-suite.ps1

Uninstall:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\uninstall-suite.ps1

Build GUI EXE:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\build-gui-exe.ps1 -SourceScript .\\scripts\\system-optimizer-gui.ps1 -OutputExe .\\WindowsOptimizer.exe

Analyze Compute Resources:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\analyze-compute-resources.ps1 -DurationSec 8 -Top 8

Quick Cleanup (safe targets):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\quick-cleanup-safe.ps1 -Execute -RetentionDays 2 -MaxFilesPerTarget 2000
