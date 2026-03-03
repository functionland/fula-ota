#!/bin/sh

# This script runs before kubo-local container starts.
# It initializes a second lightweight kubo instance dedicated to
# fula-pinning and fula-gateway user CIDs, isolated from ipfs-cluster.
set -ex

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [kubo-local] $1"
}

# Wait for main kubo to be initialized (go-fula writes .ipfs_setup after initipfs)
while [ ! -f "/internal/.ipfs_setup" ] || [ ! -f "/internal/ipfs_data/config" ]; do
    log "Waiting for main kubo initialization..."
    sleep 5
done

# Wait for uniondrive to be writable
while ! touch /uniondrive/.tmp_local_check 2>/dev/null; do
    log "Waiting for /uniondrive to become writable..."
    sleep 5
done
rm -f /uniondrive/.tmp_local_check

log "Prerequisites ready. Initializing kubo-local..."

IPFS_PATH=/internal/ipfs_data_local

# Create directories
mkdir -p "$IPFS_PATH"
mkdir -p /uniondrive/ipfs_datastore_local/blocks
mkdir -p /uniondrive/ipfs_datastore_local/datastore

# Initialize repo if needed (auto-generates identity)
if [ ! -f "$IPFS_PATH/version" ]; then
    log "Initializing new IPFS repo..."
    ipfs init --profile=flatfs
fi

# Overwrite config with our template, preserving identity
IDENTITY=$(jq '.Identity' "$IPFS_PATH/config")
cp /container-init.d/config-local "$IPFS_PATH/config"
jq --argjson id "$IDENTITY" '.Identity = $id' "$IPFS_PATH/config" > "$IPFS_PATH/config.tmp"
mv "$IPFS_PATH/config.tmp" "$IPFS_PATH/config"

# Add main kubo as peering peer (persistent connection for bitswap)
MAIN_PID=$(jq -r '.Identity.PeerID' /internal/ipfs_data/config)
if [ -n "$MAIN_PID" ] && [ "$MAIN_PID" != "null" ]; then
    log "Adding main kubo ($MAIN_PID) as peering peer..."
    jq --arg pid "$MAIN_PID" \
       '.Peering.Peers = [{"ID": $pid, "Addrs": ["/dns4/ipfs_host/tcp/4001"]}]' \
       "$IPFS_PATH/config" > "$IPFS_PATH/config.tmp"
    mv "$IPFS_PATH/config.tmp" "$IPFS_PATH/config"
fi

# Remove stale lock files from a previous crashed instance.
# Note: this script runs as the ipfs user (kubo's entrypoint does
# exec gosu ipfs before running container-init.d scripts).
rm -f /uniondrive/ipfs_datastore_local/datastore/LOCK 2>/dev/null || true
rm -f /internal/ipfs_data_local/repo.lock 2>/dev/null || true

log "Initialization complete."
