#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "Uninstalling Streamr node..."

USER="pi"
INTERNAL_DIR="/home/$USER/.internal"
STREAMR_DIR="$INTERNAL_DIR/plugins/streamr-node"

if ! systemctl list-unit-files | grep -q streamr-node.service; then
    echo "Streamr node service is not installed. No action needed"
    exit 0
fi

# Stop and force remove any containers using the streamr/node image
echo "Stopping and removing any containers using the Streamr node image..."
docker ps -a --filter ancestor=streamr/node -q | xargs -r docker rm -f
sync
sleep 1

# Remove the Docker image
if docker images | grep -q streamr/node; then
    echo "Removing Streamr node Docker image..."
    docker rmi streamr/node
else
    echo "Streamr node Docker image not found. Skipping image removal."
fi
sync
sleep 1

# Prune any dangling images and containers
echo "Pruning dangling images and containers..."
docker system prune -f
sync
sleep 1

# Remove the configuration directory
if [ -d "$STREAMR_DIR" ]; then
    echo "Removing Streamr node configuration directory..."
    rm -rf "$STREAMR_DIR"
else
    echo "Streamr node configuration directory not found. Skipping directory removal."
fi
sync
sleep 1

# Disable and remove the systemd service
if systemctl list-unit-files | grep -q streamr-node.service; then
    echo "Disabling and removing Streamr node systemd service..."
    systemctl stop streamr-node.service
    systemctl disable streamr-node.service
    rm /etc/systemd/system/streamr-node.service
    systemctl daemon-reload
else
    echo "Streamr node systemd service not found. Skipping service removal."
fi
sync
sleep 1

echo "Streamr node uninstallation complete."

exit 0