#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if olostep-node service is already installed
if systemctl list-unit-files | grep -q olostep-node.service; then
  echo "Olostep node service is already installed."
  exit 0
fi

USER="pi"
PLUGIN_NAME="olostep-node"
INTERNAL_DIR="/home/$USER/.internal"
OLOSTEP_DIR="$INTERNAL_DIR/plugins/$PLUGIN_NAME"
STORAGE_DIR="$OLOSTEP_DIR/storage"
DEVICE_ID_FILE="$OLOSTEP_DIR/device_id.txt"
PLUGIN_EXEC_DIR="/usr/bin/fula/plugins/${PLUGIN_NAME}"

# Create necessary directories
mkdir -p "$INTERNAL_DIR/plugins"
mkdir -p "$OLOSTEP_DIR"
mkdir -p "$STORAGE_DIR"

# --- Derive deterministic device_id from box_props.json ---
# Uses HMAC-SHA256 of blox_seed with plugin-specific key.
# One-way: knowing the device_id, the blox_seed cannot be recovered.

BOX_PROPS="$INTERNAL_DIR/box_props.json"
if [ ! -f "$BOX_PROPS" ]; then
  echo "Error: box_props.json not found at $BOX_PROPS"
  exit 1
fi

BLOX_SEED=$(cat "$BOX_PROPS" | grep -o '"blox_seed":"[^"]*"' | cut -d'"' -f4)

if [ -z "$BLOX_SEED" ]; then
    echo "Error: blox_seed not found in box_props.json"
    exit 1
fi

# Derive device_id suffix using HMAC-SHA256 (one-way, plugin-specific)
HASH=$(echo -n "${BLOX_SEED}" | \
  openssl dgst -binary -sha256 -mac HMAC -macopt "key:${PLUGIN_NAME}" | \
  od -An -tx1 -v | \
  tr -d ' \n')

# Take first 10 hex chars (valid subset of olostep's a-z0-9 charset)
SUFFIX=$(echo "$HASH" | cut -c1-10)
DEVICE_ID="olstp_fxland_${SUFFIX}"

if [ -z "$DEVICE_ID" ]; then
    echo "Error: Failed to derive device ID."
    exit 1
fi

# Store the device_id for reference
echo "$DEVICE_ID" > "$DEVICE_ID_FILE"

# Pre-populate storage.json so the container uses the derived ID
# instead of generating a random one
cat > "$STORAGE_DIR/storage.json" <<EOL
{"device_id":"${DEVICE_ID}"}
EOL

echo "Derived Olostep device ID: $DEVICE_ID"

# --- Generate docker-compose.yml with domain blacklist ---
# Read blocked domains from custom/blocked-domains.txt and generate
# extra_hosts entries that resolve them to 0.0.0.0 inside the container.

BLOCKLIST_FILE="${PLUGIN_EXEC_DIR}/custom/blocked-domains.txt"
COMPOSE_FILE="$OLOSTEP_DIR/docker-compose.yml"

# Start with the base docker-compose content
cat > "$COMPOSE_FILE" <<'COMPOSE_BASE'
services:
  olostep-node:
    image: olostep/olostep-fx-land:latest
    container_name: olostep-node
    restart: unless-stopped
    working_dir: /data
    command: ["node", "/app/index.js"]
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    mem_limit: 2g
    cpus: 2
    pids_limit: 200
    dns:
      - 8.8.8.8
    volumes:
      - /home/pi/.internal/plugins/olostep-node/storage:/data
    networks:
      - olostep-isolated
COMPOSE_BASE

# Append extra_hosts from blocked domains list
if [ -f "$BLOCKLIST_FILE" ]; then
    DOMAIN_COUNT=0
    echo "    extra_hosts:" >> "$COMPOSE_FILE"
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        if [ -n "$line" ]; then
            echo "      - \"${line}:0.0.0.0\"" >> "$COMPOSE_FILE"
            DOMAIN_COUNT=$((DOMAIN_COUNT + 1))
        fi
    done < "$BLOCKLIST_FILE"
    echo "Blocked $DOMAIN_COUNT sensitive domains in container DNS"
else
    echo "Warning: blocked-domains.txt not found, no domain filtering applied"
fi

# Append the network definition
cat >> "$COMPOSE_FILE" <<'COMPOSE_NETWORK'

networks:
  olostep-isolated:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: "br-olostep"
COMPOSE_NETWORK

echo "Generated docker-compose.yml with domain blacklist"

# Copy service file
cp "${PLUGIN_EXEC_DIR}/olostep-node.service" "/etc/systemd/system/"
sync
sleep 1

# Reload systemd
systemctl daemon-reload
sync
sleep 1

# Enable the service
systemctl enable olostep-node.service

echo "Olostep node installed successfully."

exit 0
