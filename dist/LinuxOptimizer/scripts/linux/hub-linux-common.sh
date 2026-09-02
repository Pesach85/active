#!/usr/bin/env bash
# Shared paths for Linux Optimizer Hub install.
set -euo pipefail

HUB_PREFIX="${HUB_PREFIX:-${HOME}/.local/opt/systemoptimizerhub}"
HUB_BIN="${HOME}/.local/bin/hub"
HUB_CONFIG="${HUB_PREFIX}/config"
HUB_LOGS="${HUB_PREFIX}/logs"
HUB_SCRIPTS="${HUB_PREFIX}/scripts/linux"

mkdir -p "${HUB_LOGS}" "${HUB_CONFIG}"

hub_cli() {
  if [[ -x "${HUB_PREFIX}/bin/hub" ]]; then
    "${HUB_PREFIX}/bin/hub" "$@"
  elif command -v hub >/dev/null 2>&1; then
    hub "$@"
  else
    echo "hub CLI not found. Run install-linux-suite.sh from packaged dist." >&2
    return 1
  fi
}
