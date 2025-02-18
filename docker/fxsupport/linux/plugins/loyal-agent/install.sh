#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if RAM is greater than 15 GB
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))

if [ "$RAM_GB" -le 15 ]; then
  echo "Insufficient RAM. At least 15 GB of RAM is required."
  exit 1
fi

# Check if streamr service is already installed
if systemctl list-unit-files | grep -q loyal-agent.service; then
  echo "Loyal agent service is already installed."
  exit 0
fi

USER="pi"
PLUGIN_NAME="loyal-agent"
INTERNAL_DIR="/home/$USER/.internal"
LOYAL_AGENT_DIR="$INTERNAL_DIR/plugins/$PLUGIN_NAME"
mkdir -p "$INTERNAL_DIR/plugins"
mkdir -p "$LOYAL_AGENT_DIR"
PLUGIN_EXEC_DIR="/usr/bin/fula/plugins/${PLUGIN_NAME}"

# Create necessary directories
mkdir -p "$INTERNAL_DIR/plugins"

sudo bash ${PLUGIN_EXEC_DIR}/custom/fix_freq_rk3588.sh

mkdir -p /uniondrive/loyal-agent
mkdir -p /uniondrive/loyal-agent/model

# Copy service file
cp "${PLUGIN_EXEC_DIR}/loyal-agent.service" "/etc/systemd/system/"
sync
sleep 1
# Copy docker-compose file

cp "${PLUGIN_EXEC_DIR}/docker-compose.yml" "$LOYAL_AGENT_DIR/"
cp "${PLUGIN_EXEC_DIR}/.env" "$LOYAL_AGENT_DIR/"
sync
sleep 1
# Reload systemd

systemctl daemon-reload
sync
sleep 1

# Enable the service
systemctl enable loyal-agent.service

# Run the download and setup script in the background using nohup and &
nohup bash "${PLUGIN_EXEC_DIR}/custom/download_model.sh" &

exit 0
