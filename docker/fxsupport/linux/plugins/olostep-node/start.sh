#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! systemctl list-unit-files | grep -q olostep-node.service; then
    echo "Olostep node service is not installed. Please install it first."
    exit 1
fi

if systemctl is-active --quiet olostep-node.service; then
    echo "Olostep node service is already running."
    exit 0
fi

# start the service
systemctl start olostep-node.service

echo "Olostep node started successfully."
