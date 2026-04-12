#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "Uninstalling Olostep node..."

USER="pi"
INTERNAL_DIR="/home/$USER/.internal"
OLOSTEP_DIR="$INTERNAL_DIR/plugins/olostep-node"
PLUGIN_EXEC_DIR="/usr/bin/fula/plugins/olostep-node"

# Remove firewall isolation rules
if [ -f "$PLUGIN_EXEC_DIR/custom/firewall-remove.sh" ]; then
    bash "$PLUGIN_EXEC_DIR/custom/firewall-remove.sh"
fi

if ! systemctl list-unit-files | grep -q olostep-node.service; then
    echo "Olostep node service is not installed. No action needed"
    exit 0
fi

# Stop and force remove any containers using the olostep image
echo "Stopping and removing any Olostep node containers..."
docker ps -a --filter ancestor=olostep/olostep-fx-land -q | xargs -r docker rm -f
sync
sleep 1

# Remove the Docker image
if docker images | grep -q "olostep/olostep-fx-land"; then
    echo "Removing Olostep node Docker image..."
    docker rmi olostep/olostep-fx-land || true
else
    echo "Olostep node Docker image not found. Skipping image removal."
fi
sync
sleep 1

# Prune any dangling images and containers
echo "Pruning dangling images and containers..."
docker system prune -f
sync
sleep 1

# Remove the configuration directory
if [ -d "$OLOSTEP_DIR" ]; then
    echo "Removing Olostep node configuration directory..."
    rm -rf "$OLOSTEP_DIR"
else
    echo "Olostep node configuration directory not found. Skipping directory removal."
fi
sync
sleep 1

# Remove the plugin's Docker network (if it exists)
if docker network ls | grep -q "olostep-isolated"; then
    echo "Removing Olostep isolated network..."
    docker network rm olostep-node_olostep-isolated 2>/dev/null || true
fi

# Disable and remove the systemd service
if systemctl list-unit-files | grep -q olostep-node.service; then
    echo "Disabling and removing Olostep node systemd service..."
    systemctl stop olostep-node.service 2>/dev/null || true
    systemctl disable olostep-node.service
    rm /etc/systemd/system/olostep-node.service
    systemctl daemon-reload
else
    echo "Olostep node systemd service not found. Skipping service removal."
fi
sync
sleep 1

echo "Olostep node uninstallation complete."

exit 0
