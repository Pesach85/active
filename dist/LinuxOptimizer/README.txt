Linux Optimizer — Process Pressure Intelligence

Analyze top CPU/RAM/IO processes (deterministic two-snapshot scoring):

  chmod +x scripts/linux/analyze-process-pressure.sh
  ./scripts/linux/analyze-process-pressure.sh 6 8 /tmp/process-pressure.json

Arguments: DURATION_SEC TOP OUTPUT_JSON [CATALOG_PATH]

Catalog: config/process-intelligence.json (shared knowledge base with Windows build).

Safe apply on Linux (renice, reversible):

  chmod +x scripts/linux/apply-process-pressure-safe.sh
  ./scripts/linux/apply-process-pressure-safe.sh /tmp/process-pressure.json /tmp/apply.json
