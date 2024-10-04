#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! systemctl list-unit-files | grep -q streamr-node.service; then
    echo "Streamr node service is not installed. Please install it first."
    exit 1
fi

if systemctl is-active --quiet streamr-node.service; then
    echo "Streamr node service is already running."
    exit 0
fi

# start the service
systemctl start streamr-node.service

echo "Streamr node started successfully."