#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "Uninstalling Blox AI..."

USER="pi"
INTERNAL_DIR="/home/$USER/.internal"
BLOX_AI_DIR="$INTERNAL_DIR/plugins/blox-ai"
COMMANDS_DIR="/home/$USER/commands"

# Note: cleanup proceeds even when the unit is absent (e.g. partial install,
# or a device that has the BLOX_AI_DIR staged but never got the unit copied).
# Exiting early on missing-unit would leave the internal dir and the BLE
# manifest behind, so the core scanner would keep proxying to a non-existent
# service.

# Stop and force remove any containers using the blox-ai image
echo "Stopping and removing any containers using the blox-ai image..."
docker ps -a --filter ancestor=functionland/blox-ai -q | xargs -r docker rm -f 2>/dev/null || true
sync
sleep 1

# Remove the Docker image
if docker images | grep -q functionland/blox-ai; then
    echo "Removing blox-ai Docker image..."
    docker rmi functionland/blox-ai 2>/dev/null || true
else
    echo "blox-ai Docker image not found. Skipping image removal."
fi
sync
sleep 1

# Note: the prior loyal-agent uninstall.sh ran `docker system prune -f`
# here. Removed in Phase 6 per Codex post-review — global prune can drop
# unrelated stopped containers and dangling images from other plugins or
# user workloads. The explicit `docker rm`/`docker rmi` above is the
# scoped cleanup we actually need for blox-ai.

# Remove the configuration directory (also drops staged ble_commands.json)
if [ -d "$BLOX_AI_DIR" ]; then
    echo "Removing Blox AI configuration directory..."
    rm -rf "$BLOX_AI_DIR" || true
else
    echo "Blox AI configuration directory not found. Skipping directory removal."
fi
sync
sleep 1

# Phase 14 — stop + disable the isolation timer (before removing the unit
# file; otherwise a fired timer mid-uninstall would start a removed unit).
if systemctl list-unit-files 2>/dev/null | grep -q blox-ai-isolation.timer; then
    systemctl stop blox-ai-isolation.timer 2>/dev/null || true
    systemctl disable blox-ai-isolation.timer 2>/dev/null || true
fi
rm -f /etc/systemd/system/blox-ai-isolation.timer /etc/systemd/system/blox-ai-isolation.service 2>/dev/null || true

# Disable and remove the systemd service
if systemctl list-unit-files | grep -q blox-ai.service; then
    echo "Disabling and removing Blox AI systemd service..."
    systemctl stop blox-ai.service 2>/dev/null || true
    systemctl disable blox-ai.service 2>/dev/null || true
    rm -f /etc/systemd/system/blox-ai.service
    systemctl daemon-reload
else
    echo "Blox AI systemd service not found. Skipping service removal."
fi
sync
sleep 1

# Signal core to re-scan so ai/* and diag/* commands are de-registered.
# Done last so the scanner doesn't try to proxy to a half-removed plugin.
mkdir -p "$COMMANDS_DIR" 2>/dev/null || true
touch "$COMMANDS_DIR/.command_plugin_reload" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Migration shim — defensive cleanup for devices that ended up with BOTH the
# old loyal-agent slot AND blox-ai (e.g. mid-rollout reinstall edge cases).
# Same shim as install.sh; idempotent.
# ---------------------------------------------------------------------------
if systemctl list-unit-files 2>/dev/null | grep -q '^loyal-agent\.service'; then
  echo "Migration: cleaning lingering loyal-agent slot"
  if [ -f "/home/pi/.internal/plugins/loyal-agent/docker-compose.yml" ]; then
    # 60s timeout: `|| true` handles non-zero exit, not hangs (Codex post-review)
    timeout 60 docker-compose -f /home/pi/.internal/plugins/loyal-agent/docker-compose.yml down 2>/dev/null || true
  fi
  systemctl stop loyal-agent.service 2>/dev/null || true
  systemctl disable loyal-agent.service 2>/dev/null || true
  rm -f /etc/systemd/system/loyal-agent.service
  systemctl daemon-reload || true
fi
if [ -d "/home/pi/.internal/plugins/loyal-agent" ]; then
  rm -rf /home/pi/.internal/plugins/loyal-agent || true
fi

echo "Blox AI uninstallation complete."

exit 0
