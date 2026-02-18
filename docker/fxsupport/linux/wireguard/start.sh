#!/bin/bash
# WireGuard support tunnel — start
set -e

FULA_LOG_PATH="/home/pi/fula.sh.log"
WG_DIR="/etc/wireguard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wireguard-start] $*" | tee -a "$FULA_LOG_PATH"
}

# Check wg installed
if ! command -v wg >/dev/null 2>&1; then
  log "ERROR: wg not installed"
  exit 1
fi

# Check if already active
if ip link show support >/dev/null 2>&1; then
  log "Support tunnel already active"
  exit 0
fi

# Register if config missing
if [ ! -f "${WG_DIR}/support.conf" ]; then
  log "No support.conf found, running registration..."
  bash "${SCRIPT_DIR}/register_wireguard.sh"
fi

# Bring up tunnel
log "Starting WireGuard support tunnel..."
wg-quick up support

# Re-apply firewall to ensure support interface rules are active
if [ -f "/usr/bin/fula/firewall.sh" ]; then
  log "Re-applying firewall rules..."
  bash /usr/bin/fula/firewall.sh 2>&1 | tail -3 | tee -a "$FULA_LOG_PATH" || true
fi

# Verify interface exists
if ip link show support >/dev/null 2>&1; then
  log "Support tunnel active"
else
  log "ERROR: Support interface not found after wg-quick up"
  exit 1
fi
