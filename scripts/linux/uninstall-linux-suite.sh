#!/usr/bin/env bash
set -euo pipefail

PREFIX="${HUB_PREFIX:-${HOME}/.local/opt/systemoptimizerhub}"
BIN_LINK="${HOME}/.local/bin/hub"
DESKTOP="${HOME}/.local/share/applications/systemoptimizerhub.desktop"

systemctl --user disable --now systemoptimizerhub-orchestrator.timer 2>/dev/null || true
systemctl --user disable --now systemoptimizerhub-orchestrator.service 2>/dev/null || true
rm -f "${HOME}/.config/systemd/user/systemoptimizerhub-orchestrator.service" \
      "${HOME}/.config/systemd/user/systemoptimizerhub-orchestrator.timer"
systemctl --user daemon-reload 2>/dev/null || true

rm -f "${BIN_LINK}" "${DESKTOP}"
if [[ -d "${PREFIX}" ]]; then
  rm -rf "${PREFIX}"
fi

echo "[UNINSTALL] Linux Optimizer Hub removed."
