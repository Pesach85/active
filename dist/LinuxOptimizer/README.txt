Linux Optimizer Hub (0.8.0)

Install (user scope, no root):
  chmod +x scripts/linux/install-linux-suite.sh
  ./scripts/linux/install-linux-suite.sh

Uninstall:
  ./scripts/linux/uninstall-linux-suite.sh

CLI (after install):
  hub version
  hub analyze pressure --duration 6 --top 8
  hub network deep-scan --catalog config/process-intelligence.json

PPI bash (offline):
  ./scripts/linux/analyze-process-pressure.sh 6 8 /tmp/process-pressure.json
  ./scripts/linux/apply-process-pressure-safe.sh /tmp/process-pressure.json /tmp/apply.json

Systemd user timer: systemoptimizerhub-orchestrator.timer (optional, install script enables)
