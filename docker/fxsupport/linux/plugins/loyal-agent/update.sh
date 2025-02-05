#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! systemctl list-unit-files | grep -q loyal-agent.service; then
    echo "Loyal agent service is not installed. No action needed"
    exit 0
fi

bash ./stop.sh
docker pull functionland/loyal-agent
bash ./start.sh