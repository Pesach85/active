Windows Optimizer Suite

Install:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\install-suite.ps1

Uninstall:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\uninstall-suite.ps1

Build GUI EXE:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\build-gui-exe.ps1 -SourceScript .\\scripts\\system-optimizer-gui.ps1 -OutputExe .\\WindowsOptimizer.exe
