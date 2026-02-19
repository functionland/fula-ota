#!/bin/bash
# WireGuard support tunnel — stop + deregister

FULA_LOG_PATH="/home/pi/fula.sh.log"
WG_DIR="/etc/wireguard"
STATE_DIR="/home/pi/.internal/wireguard"
STATE_FILE="${STATE_DIR}/registration.state"
DEREGISTER_URL="https://support.fx.land/api/v1/wireguard/deregister"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wireguard-stop] $*" | tee -a "$FULA_LOG_PATH"
}

# Deregister from support server (best-effort)
if [ -f "$STATE_FILE" ]; then
  device_id=$(cat /etc/machine-id 2>/dev/null) || true
  if [ -n "$device_id" ]; then
    log "Deregistering from support server..."
    if curl -s -f --max-time 15 \
      -H "Content-Type: application/json" \
      -d "{\"device_id\":\"${device_id}\"}" \
      "$DEREGISTER_URL" >/dev/null 2>&1; then
      log "Deregistered successfully"
      rm -f "$STATE_FILE"
      rm -f "${WG_DIR}/support.conf"
    else
      log "WARNING: Deregistration failed (server unreachable) — will clean up on next register"
    fi
  fi
fi

log "Stopping WireGuard support tunnel..."
wg-quick down support 2>&1 | tee -a "$FULA_LOG_PATH" || true
log "Support tunnel stopped"
exit 0
