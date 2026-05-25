#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if the service is installed
if ! systemctl list-unit-files | grep -q blox-ai.service; then
    echo "Blox AI service is not installed."
    exit 1
fi

# Check if the service is running
if ! systemctl is-active --quiet blox-ai.service; then
    echo "Blox AI service is not running."
    exit 0
fi

# Stop the service
echo "Stopping Blox AI service..."
systemctl stop blox-ai.service

# Check if the service has stopped
if ! systemctl is-active --quiet blox-ai.service; then
    echo "Blox AI service stopped successfully."
else
    echo "Failed to stop Blox AI service."
    exit 1
fi
