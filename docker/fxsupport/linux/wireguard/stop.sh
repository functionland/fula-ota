#!/bin/bash
# WireGuard support tunnel — stop

FULA_LOG_PATH="/home/pi/fula.sh.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wireguard-stop] $*" | tee -a "$FULA_LOG_PATH"
}

log "Stopping WireGuard support tunnel..."
wg-quick down support 2>&1 | tee -a "$FULA_LOG_PATH" || true
log "Support tunnel stopped"
exit 0
