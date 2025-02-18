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

MODEL_DIR="/uniondrive/loyal-agent/model"
MODEL_FILE="$MODEL_DIR/deepseek-llm-7b-chat-rk3588-w8a8_g256-opt-1-hybrid-ratio-0.5.rkllm"
SIZE_LIMIT=7500000000  # Size in bytes (7.5 GB)

# Wait for the file to finish downloading
echo "Checking for the file to be fully downloaded..."

FILE_SIZE=0
if [ -f "$MODEL_FILE" ]; then
  FILE_SIZE=$(stat -c%s "$MODEL_FILE")
fi

if [ -f "$MODEL_FILE" ] && [ "$FILE_SIZE" -ge "$SIZE_LIMIT" ]; then
  echo "File downloaded successfully."
  # start the service
  systemctl start loyal-agent.service
  echo "Loyal agent started successfully."
else
  echo "Download failed or incomplete."
fi