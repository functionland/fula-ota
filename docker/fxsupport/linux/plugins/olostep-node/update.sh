#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! systemctl list-unit-files | grep -q olostep-node.service; then
    echo "Olostep node service is not installed. No action needed"
    exit 0
fi

bash ./stop.sh
docker pull olostep/olostep-fx-land
bash ./start.sh
