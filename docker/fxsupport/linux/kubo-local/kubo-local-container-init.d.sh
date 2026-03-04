#!/bin/sh

# This script runs before kubo-local container starts.
# It initializes a second lightweight kubo instance dedicated to
# fula-pinning and fula-gateway user CIDs, isolated from ipfs-cluster.
#
# NOTE: Neither jq nor `ipfs config Identity.PrivKey` work in this
# container (jq not installed; ipfs refuses to expose PrivKey via CLI).
# All JSON manipulation uses grep/sed on the raw config file.
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

# Extract PeerID and PrivKey from the existing config file using grep/sed.
# ipfs config CLI refuses to show PrivKey, so we must read the file directly.
PEER_ID=$(grep -o '"PeerID"[[:space:]]*:[[:space:]]*"[^"]*"' "$IPFS_PATH/config" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
PRIV_KEY=$(grep -o '"PrivKey"[[:space:]]*:[[:space:]]*"[^"]*"' "$IPFS_PATH/config" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
log "Preserving identity: $PEER_ID"

# Overwrite config with our template
cp /container-init.d/config-local "$IPFS_PATH/config"

# Re-inject preserved identity using sed
sed -i "s|\"PeerID\": \"\"|\"PeerID\": \"${PEER_ID}\"|" "$IPFS_PATH/config"
sed -i "s|\"PrivKey\": \"\"|\"PrivKey\": \"${PRIV_KEY}\"|" "$IPFS_PATH/config"

# Overwrite datastore_spec to match our config-local.
# ipfs init writes a default spec (relative paths, levelds) that doesn't match
# our custom paths and pebbleds. Kubo refuses to start on mismatch.
cat > "$IPFS_PATH/datastore_spec" << 'DSEOF'
{"mounts":[{"mountpoint":"/blocks","path":"/uniondrive/ipfs_datastore_local/blocks","shardFunc":"/repo/flatfs/shard/v1/next-to-last/2","type":"flatfs"},{"mountpoint":"/","path":"/uniondrive/ipfs_datastore_local/datastore","type":"pebbleds"}],"type":"mount"}
DSEOF

# Add main kubo as peering peer (persistent connection for bitswap)
MAIN_PID=$(grep -o '"PeerID"[[:space:]]*:[[:space:]]*"[^"]*"' /internal/ipfs_data/config 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
if [ -n "$MAIN_PID" ]; then
    log "Adding main kubo ($MAIN_PID) as peering peer..."
    # Replace the empty Peers array with the main kubo peer entry
    sed -i "s|\"Peers\": \[\]|\"Peers\": [{\"ID\": \"${MAIN_PID}\", \"Addrs\": [\"/dns4/ipfs_host/tcp/4001\"]}]|" "$IPFS_PATH/config"
fi

# Remove stale lock files from a previous crashed instance.
# Note: this script runs as the ipfs user (kubo's entrypoint does
# exec gosu ipfs before running container-init.d scripts).
rm -f /uniondrive/ipfs_datastore_local/datastore/LOCK 2>/dev/null || true
rm -f /internal/ipfs_data_local/repo.lock 2>/dev/null || true

log "Initialization complete."
