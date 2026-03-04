#!/bin/sh

# This script runs before kubo-local container starts.
# It initializes a second lightweight kubo instance dedicated to
# fula-pinning and fula-gateway user CIDs, isolated from ipfs-cluster.
#
# NOTE: jq is NOT available in ipfs/kubo:release. Use ipfs config
# commands (work offline) and grep/sed for JSON extraction.
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

export IPFS_PATH=/internal/ipfs_data_local

# Create directories
mkdir -p "$IPFS_PATH"
mkdir -p /uniondrive/ipfs_datastore_local/blocks
mkdir -p /uniondrive/ipfs_datastore_local/datastore

# Initialize repo if needed (auto-generates identity)
if [ ! -f "$IPFS_PATH/version" ]; then
    log "Initializing new IPFS repo..."
    ipfs init --profile=flatfs
fi

# Save identity before overwriting config (ipfs config works offline)
PEER_ID=$(ipfs config Identity.PeerID)
PRIV_KEY=$(ipfs config Identity.PrivKey)
log "Preserving identity: $PEER_ID"

# Overwrite config with our template
cp /container-init.d/config-local "$IPFS_PATH/config"

# Re-inject preserved identity
ipfs config Identity.PeerID "$PEER_ID"
ipfs config Identity.PrivKey "$PRIV_KEY"

# Add main kubo as peering peer (persistent connection for bitswap)
# Extract PeerID using grep/sed (same technique as main kubo init script)
MAIN_PID=$(grep -o '"PeerID"[[:space:]]*:[[:space:]]*"[^"]*"' /internal/ipfs_data/config 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
if [ -n "$MAIN_PID" ]; then
    log "Adding main kubo ($MAIN_PID) as peering peer..."
    ipfs config --json Peering.Peers "[{\"ID\": \"$MAIN_PID\", \"Addrs\": [\"/dns4/ipfs_host/tcp/4001\"]}]"
fi

# Remove stale lock files from a previous crashed instance.
# Note: this script runs as the ipfs user (kubo's entrypoint does
# exec gosu ipfs before running container-init.d scripts).
rm -f /uniondrive/ipfs_datastore_local/datastore/LOCK 2>/dev/null || true
rm -f /internal/ipfs_data_local/repo.lock 2>/dev/null || true

log "Initialization complete."
