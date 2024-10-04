#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if the service is installed
if ! systemctl list-unit-files | grep -q streamr-node.service; then
    echo "Streamr node service is not installed."
    exit 1
fi

# Check if the service is running
if ! systemctl is-active --quiet streamr-node.service; then
    echo "Streamr node service is not running."
    exit 0
fi

# Stop the service
echo "Stopping Streamr node service..."
systemctl stop streamr-node.service

# Check if the service has stopped
if ! systemctl is-active --quiet streamr-node.service; then
    echo "Streamr node service stopped successfully."
else
    echo "Failed to stop Streamr node service."
    exit 1
fi