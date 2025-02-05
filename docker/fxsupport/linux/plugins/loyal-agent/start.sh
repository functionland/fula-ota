#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! systemctl list-unit-files | grep -q loyal-agent.service; then
    echo "Loyal agent service is not installed. Please install it first."
    exit 1
fi

if systemctl is-active --quiet loyal-agent.service; then
    echo "Loyal agent service is already running."
    exit 0
fi

# start the service
systemctl start loyal-agent.service

echo "Loyal agent started successfully."