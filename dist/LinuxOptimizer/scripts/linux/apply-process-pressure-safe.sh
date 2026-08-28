#!/usr/bin/env bash
# Safe apply for Linux process pressure (renice only — reversible).
set -euo pipefail

INPUT_JSON="${1:-}"
OUTPUT_JSON="${2:-}"
DRY_RUN="${3:-false}"

if [[ -z "$INPUT_JSON" || ! -f "$INPUT_JSON" ]]; then
  echo "Usage: apply-process-pressure-safe.sh INPUT.json [OUTPUT.json] [dry-run]" >&2
  exit 1
fi

if [[ -z "$OUTPUT_JSON" ]]; then
  OUTPUT_JSON="$(dirname "$INPUT_JSON")/process-pressure-apply.json"
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required for JSON parsing" >&2
  exit 1
fi

ROLLBACK="$(dirname "$OUTPUT_JSON")/process-pressure-rollback-$(date +%Y%m%d-%H%M%S).json"

python3 - "$INPUT_JSON" "$OUTPUT_JSON" "$ROLLBACK" "$DRY_RUN" <<'PY'
import json, os, subprocess, sys
from datetime import datetime

input_path, output_path, rollback_path, dry_flag = sys.argv[1:5]
dry = dry_flag.lower() == 'true'

with open(input_path, encoding='utf-8') as f:
    report = json.load(f)

applied, skipped, rollback = [], [], []
core_names = {'systemd', 'kthreadd', 'sshd', 'dbus-daemon'}

for proc in report.get('TopProcesses', []):
    priority = proc.get('Priority', 'Review')
    score = float(proc.get('Score', 0))
    pid = int(proc.get('PID', 0))
    name = str(proc.get('ProcessName', ''))

    if priority == 'Keep':
        skipped.append({'PID': pid, 'ProcessName': name, 'Reason': 'Vital/security preserved'})
        continue
    if score < 40:
        skipped.append({'PID': pid, 'ProcessName': name, 'Reason': 'Score below threshold (40)'})
        continue
    if name in core_names or name.startswith('kworker'):
        skipped.append({'PID': pid, 'ProcessName': name, 'Reason': 'Linux core preserved'})
        continue

    stat_path = f'/proc/{pid}/stat'
    if not os.path.exists(stat_path):
        skipped.append({'PID': pid, 'ProcessName': name, 'Reason': 'Process gone'})
        continue

    with open(stat_path) as sf:
        nice = int(sf.read().split()[18])

    target_nice = 10
    if nice >= target_nice:
        skipped.append({'PID': pid, 'ProcessName': name, 'Reason': f'Already nice={nice}'})
        continue

    if not dry:
        subprocess.run(['renice', '-n', str(target_nice), '-p', str(pid)], check=False)

    applied.append({'PID': pid, 'ProcessName': name, 'BeforeNice': nice, 'AfterNice': target_nice, 'Applied': not dry})
    rollback.append({'PID': pid, 'ProcessName': name, 'RestoreNice': nice})

out = {
    'SchemaVersion': 'ProcessPressureApplyResult.v1',
    'GeneratedAt': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'Platform': 'Linux',
    'DryRun': dry,
    'Applied': applied,
    'Skipped': skipped,
    'RollbackPath': rollback_path,
}
rb = {'SchemaVersion': 'ProcessPressureRollback.v1', 'Actions': rollback}

with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(out, f, indent=2)
with open(rollback_path, 'w', encoding='utf-8') as f:
    json.dump(rb, f, indent=2)

print(f'Applied={len(applied)} Skipped={len(skipped)} Rollback={rollback_path}')
PY
