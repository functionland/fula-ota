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
STREAMR_DIR="$INTERNAL_DIR/streamr-node"

if ! systemctl list-unit-files | grep -q streamr-node.service; then
    echo "Streamr node service is not installed. No action needed"
    exit 0
fi

# Stop and remove the Docker container
if docker ps -a | grep -q streamr-node; then
    echo "Stopping and removing Streamr node Docker container..."
    docker stop streamr-node
    docker rm streamr-node
else
    echo "Streamr node Docker container not found. Skipping container removal."
fi

# Remove the Docker image
if docker images | grep -q streamr/node; then
    echo "Removing Streamr node Docker image..."
    docker rmi streamr/node
else
    echo "Streamr node Docker image not found. Skipping image removal."
fi

# Remove the configuration directory
if [ -d "$STREAMR_DIR" ]; then
    echo "Removing Streamr node configuration directory..."
    rm -rf "$STREAMR_DIR"
else
    echo "Streamr node configuration directory not found. Skipping directory removal."
fi

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

echo "Streamr node uninstallation complete."

exit 0