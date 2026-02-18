#!/bin/bash
# WireGuard support tunnel — complete removal
# Stops tunnel, removes service, keys, config, and state.
# Does NOT remove wireguard-tools package.

FULA_LOG_PATH="/home/pi/fula.sh.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wireguard-uninstall] $*" | tee -a "$FULA_LOG_PATH"
}

log "Uninstalling WireGuard support tunnel..."

# Stop tunnel if active
wg-quick down support 2>/dev/null || true

# Disable and remove systemd service
systemctl stop wireguard-support.service 2>/dev/null || true
systemctl disable wireguard-support.service 2>/dev/null || true
rm -f /etc/systemd/system/wireguard-support.service
systemctl daemon-reload 2>/dev/null || true

# Remove WireGuard config and keys
rm -f /etc/wireguard/support.conf
rm -f /etc/wireguard/support_private.key
rm -f /etc/wireguard/support_public.key

# Remove state directory
rm -rf /home/pi/.internal/wireguard

log "WireGuard support tunnel uninstalled"
