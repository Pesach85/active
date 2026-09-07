Windows Optimizer Suite

Install:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\install-suite.ps1

Uninstall:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\uninstall-suite.ps1

Build GUI EXE:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\build-gui-exe.ps1 -SourceScript .\\scripts\\system-optimizer-gui.ps1 -OutputExe .\\WindowsOptimizer.exe

Analyze Compute Resources (legacy wrapper):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\analyze-compute-resources.ps1 -DurationSec 8 -Top 8

Process Pressure Intelligence (full report):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\analyze-process-pressure.ps1 -DurationSec 8 -Top 8 -IncludeResearch -OutputJson .\\logs\\process-pressure-latest.json

Apply safe auto-actions (audit-first):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\apply-process-pressure-safe.ps1 -InputJson .\\logs\\process-pressure-latest.json -OutputJson .\\logs\\process-pressure-apply.json -MaxLevel Safe

Quick Cleanup (safe targets):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\quick-cleanup-safe.ps1 -Execute -RetentionDays 2 -MaxFilesPerTarget 2000
