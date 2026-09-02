#!/usr/bin/env bash
# Install System Optimizer Hub for Linux (user scope, no root required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PREFIX="${HUB_PREFIX:-${HOME}/.local/opt/systemoptimizerhub}"
BIN_DIR="${HOME}/.local/bin"
DESKTOP_DIR="${HOME}/.local/share/applications"
SYSTEMD_USER="${HOME}/.config/systemd/user"

echo "[INSTALL] Linux Optimizer Hub -> ${PREFIX}"

mkdir -p "${PREFIX}/bin" "${PREFIX}/config" "${PREFIX}/logs" "${PREFIX}/scripts/linux" "${BIN_DIR}" "${DESKTOP_DIR}" "${SYSTEMD_USER}"

if [[ -d "${PKG_ROOT}/hub" ]]; then
  cp -a "${PKG_ROOT}/hub/." "${PREFIX}/bin/" 2>/dev/null || true
fi
if [[ -f "${PKG_ROOT}/bin/hub" ]]; then
  cp -a "${PKG_ROOT}/bin/hub" "${PREFIX}/bin/hub"
  chmod +x "${PREFIX}/bin/hub"
fi

cp -a "${PKG_ROOT}/scripts/linux/." "${PREFIX}/scripts/linux/" 2>/dev/null || cp -a "${SCRIPT_DIR}/." "${PREFIX}/scripts/linux/"
cp -a "${PKG_ROOT}/config/." "${PREFIX}/config/" 2>/dev/null || true

cat > "${BIN_DIR}/hub" <<EOF
#!/usr/bin/env bash
exec "${PREFIX}/bin/hub" "\$@"
EOF
chmod +x "${BIN_DIR}/hub"

cat > "${DESKTOP_DIR}/systemoptimizerhub.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=System Optimizer Hub
Comment=Process pressure and transparency CLI
Exec=xdg-open http://127.0.0.1:8765
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
EOF

if [[ -f "${SCRIPT_DIR}/systemoptimizerhub-orchestrator.service" ]]; then
  cp "${SCRIPT_DIR}/systemoptimizerhub-orchestrator.service" "${SYSTEMD_USER}/"
  cp "${SCRIPT_DIR}/systemoptimizerhub-orchestrator.timer" "${SYSTEMD_USER}/"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now systemoptimizerhub-orchestrator.timer 2>/dev/null || echo "[WARN] systemd user timer not enabled (no user session?)."
fi

cat > "${PREFIX}/install-manifest.json" <<EOF
{"SchemaVersion":"HubInstallManifest.v1","Platform":"linux","Prefix":"${PREFIX}","InstalledAt":"$(date -Iseconds)"}
EOF

echo "[INSTALL] Complete. Add to PATH: export PATH=\"${BIN_DIR}:\$PATH\""
echo "[INSTALL] CLI: hub version"
echo "[INSTALL] PPI: ${PREFIX}/scripts/linux/analyze-process-pressure.sh 6 8 /tmp/ppi.json"
