#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if the service is installed
if ! systemctl list-unit-files | grep -q loyal-agent.service; then
    echo "Loyal agent service is not installed."
    exit 1
fi

# Check if the service is running
if ! systemctl is-active --quiet loyal-agent.service; then
    echo "Loyal agent service is not running."
    exit 0
fi

# Stop the service
echo "Stopping Loyal agent service..."
systemctl stop loyal-agent.service

# Check if the service has stopped
if ! systemctl is-active --quiet loyal-agent.service; then
    echo "Loyal agent service stopped successfully."
else
    echo "Failed to stop Loyal agent service."
    exit 1
fi