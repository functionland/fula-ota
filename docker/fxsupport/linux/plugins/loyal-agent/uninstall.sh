#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "Uninstalling Loyal agent..."

USER="pi"
INTERNAL_DIR="/home/$USER/.internal"
LOYAL_AGENT_DIR="$INTERNAL_DIR/plugins/loyal-agent"

if ! systemctl list-unit-files | grep -q loyal-agent.service; then
    echo "Loyal agent service is not installed. No action needed"
    exit 0
fi

# Stop and force remove any containers using the loyal-agent image
echo "Stopping and removing any containers using the loyal-agent image..."
docker ps -a --filter ancestor=functionland/loyal-agent -q | xargs -r docker rm -f
sync
sleep 1

# Remove the Docker image
if docker images | grep -q functionland/loyal-agent; then
    echo "Removing loyal-agent Docker image..."
    docker rmi functionland/loyal-agent
else
    echo "loyal-agent Docker image not found. Skipping image removal."
fi
sync
sleep 1

# Prune any dangling images and containers
echo "Pruning dangling images and containers..."
docker system prune -f
sync
sleep 1

# Remove the configuration directory
if [ -d "$LOYAL_AGENT_DIR" ]; then
    echo "Removing Loyal agent configuration directory..."
    rm -rf "$LOYAL_AGENT_DIR" || true
else
    echo "Loyal agent configuration directory not found. Skipping directory removal."
fi
sync
sleep 1

# Disable and remove the systemd service
if systemctl list-unit-files | grep -q loyal-agent.service; then
    echo "Disabling and removing Loyal agent systemd service..."
    systemctl stop loyal-agent.service
    systemctl disable loyal-agent.service
    rm /etc/systemd/system/loyal-agent.service
    systemctl daemon-reload
else
    echo "Loyal agent systemd service not found. Skipping service removal."
fi
sync
sleep 1

echo "Loyal agent uninstallation complete."

exit 0