#!/bin/bash
# WireGuard support tunnel — idempotent one-time installation
# Installs wireguard-tools, generates keys, copies systemd service.
# Does NOT start the tunnel — activation is on-demand only.
set -e

FULA_LOG_PATH="/home/pi/fula.sh.log"
WG_DIR="/etc/wireguard"
STATE_DIR="/home/pi/.internal/wireguard"
SERVICE_FILE="/etc/systemd/system/wireguard-support.service"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wireguard-install] $*" | tee -a "$FULA_LOG_PATH"
}

# Fast-path guard: everything already installed
if command -v wg >/dev/null 2>&1 && \
   [ -f "${WG_DIR}/support_private.key" ] && \
   [ -f "$SERVICE_FILE" ]; then
  log "WireGuard already installed, skipping"
  exit 0
fi

# Install wireguard-tools if wg binary not found
if ! command -v wg >/dev/null 2>&1; then
  log "Installing wireguard-tools..."
  apt-get update -qq && apt-get install -y wireguard-tools 2>&1 | tail -5 | tee -a "$FULA_LOG_PATH"
  if ! command -v wg >/dev/null 2>&1; then
    log "ERROR: wireguard-tools installation failed"
    exit 1
  fi
  log "wireguard-tools installed"
fi

# Generate keypair if not present
if [ ! -f "${WG_DIR}/support_private.key" ] || [ ! -f "${WG_DIR}/support_public.key" ]; then
  log "Generating WireGuard keypair..."
  mkdir -p "$WG_DIR"
  wg genkey | tee "${WG_DIR}/support_private.key" | wg pubkey > "${WG_DIR}/support_public.key"
  chmod 600 "${WG_DIR}/support_private.key"
  chmod 644 "${WG_DIR}/support_public.key"
  log "WireGuard keypair generated"
fi

# Create state directory
mkdir -p "$STATE_DIR"

# Install systemd service (do NOT enable — on-demand only)
if [ ! -f "$SERVICE_FILE" ] || ! cmp -s "${SCRIPT_DIR}/wireguard-support.service" "$SERVICE_FILE"; then
  log "Installing wireguard-support.service..."
  cp "${SCRIPT_DIR}/wireguard-support.service" "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl disable wireguard-support.service 2>/dev/null || true
  log "wireguard-support.service installed (on-demand activation only)"
fi

log "WireGuard installation complete"
