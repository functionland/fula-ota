#!/bin/sh

# This scripts runs before ipfs container
set -ex

fula_file_path="/internal/config.yaml"
temp_file="/internal/.env.cluster.tmp"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_files_and_folders() {
  if [ -d "/internal" ] && [ -d "/uniondrive" ] && [ -f "/internal/config.yaml" ] && [ -f "/internal/.ipfscluster_setup" ] && [ -f "/uniondrive/ipfs-cluster/identity.json" ]; then
    return 0 # Explicitly return success
  else
    return 1 # Explicitly return failure
  fi
}

check_writable() {
  # Try to create a temporary file
  touch "/uniondrive/.tmp3_write_check"
  
  # Check if the file exists after attempting to create it
  if [ -f "/uniondrive/.tmp3_write_check" ]; then
    # Attempt to remove the file regardless of the outcome
    rm -f "/uniondrive/.tmp3_write_check"
    # Return success even if 'rm' fails
    return 0
  else
    # Return failure if the file could not be created
    return 1
  fi
}

append_or_replace() {
    return 0
}

while ! check_files_and_folders || ! check_writable; do
  log "Waiting for /internal and /uniondrive to become available and writable..."
  sleep 5
done

poolName=""

# Wait for CLUSTER_SECRET to be set
poolName=$(grep 'poolName:' "${fula_file_path}" | cut -d':' -f2 | tr -d ' "')
while [ -z "$poolName" ] || [ "$poolName" = "0" ]; do
    echo "Waiting for CLUSTER_CLUSTERNAME to be set..."
    if [ -f "$fula_file_path" ];then
        poolName=$(grep 'poolName:' "${fula_file_path}" | cut -d':' -f2 | tr -d ' "')
    fi
    sleep 60
done

get_poolcreator_peerid() {
  # Step 5: Set CLUSTER_CRDT_TRUSTEDPEERS
  export CLUSTER_CRDT_TRUSTEDPEERS="12D3KooWS79EhkPU7ESUwgG4vyHHzW9FDNZLoWVth9b5N5NSrvaj"
}


export CLUSTER_CLUSTERNAME="${poolName}"
append_or_replace "/.env.cluster" "CLUSTER_CLUSTERNAME" "${CLUSTER_CLUSTERNAME}"


echo "CLUSTER_CLUSTERNAME is set."
secret=$(printf "%s" "${CLUSTER_CLUSTERNAME}" | sha256sum | cut -d' ' -f1)
export CLUSTER_SECRET="${secret}"
append_or_replace "/.env.cluster" "CLUSTER_SECRET" "${CLUSTER_SECRET}"

# Function to get IPFS peer ID with fallback mechanisms
get_ipfs_peer_id() {
    peer_id=""

    # Method 1: Try to get peer ID from IPFS identity file
    if [ -f "/uniondrive/ipfs-cluster/identity.json" ]; then
        peer_id=$(jq -r '.id // empty' "/uniondrive/ipfs-cluster/identity.json" 2>/dev/null)
        if [ -n "$peer_id" ] && [ "$peer_id" != "null" ]; then
            echo "Found peer ID from identity.json: $peer_id" >&2
            echo "$peer_id"
            return 0
        fi
    fi

    # Method 2: Try to get peer ID from IPFS API
    echo "Attempting to get peer ID from IPFS API..." >&2
    max_attempts=10
    attempt=1

    while [ $attempt -le $max_attempts ]; do
        if nc -z 127.0.0.1 5001 2>/dev/null; then
            peer_id=$(curl -s -X POST "http://127.0.0.1:5001/api/v0/id" 2>/dev/null | jq -r '.ID // empty' 2>/dev/null)
            if [ -n "$peer_id" ] && [ "$peer_id" != "null" ] && [ "$peer_id" != "empty" ]; then
                echo "Successfully retrieved peer ID from IPFS API: $peer_id" >&2
                echo "$peer_id"
                return 0
            fi
        fi
        echo "Attempt $attempt/$max_attempts: IPFS API not ready, waiting 5 seconds..." >&2
        sleep 5
        attempt=$((attempt + 1))
    done

    # Method 3: Fallback to hostname-based ID
    echo "Warning: Could not retrieve IPFS peer ID, using hostname-based fallback" >&2
    peer_id="fula-peer-$(hostname)-$(date +%s)"
    echo "$peer_id"
    return 1
}

# Get the peer ID using the function above
ipfs_peer_id=$(get_ipfs_peer_id)
export CLUSTER_PEERNAME="${ipfs_peer_id}"
append_or_replace "/.env.cluster" "CLUSTER_PEERNAME" "${CLUSTER_PEERNAME}"
    
    mkdir -p /uniondrive/.tmp
    get_poolcreator_peerid
    append_or_replace "/.env.cluster" "CLUSTER_CRDT_TRUSTEDPEERS" "${CLUSTER_CRDT_TRUSTEDPEERS}"
    # Initialize ipfs-cluster-service if the configuration does not exist
    if [ ! -f "${IPFS_CLUSTER_PATH}/service.json" ]; then
        echo "Initializing ipfs-cluster-service..."
        /usr/local/bin/ipfs-cluster-service init
    fi

    if [ -f "${IPFS_CLUSTER_PATH}/service.json" ]; then
        echo "Modifying service.json to replace allocator and informer sections..."

        # Use jq to update the JSON file
        jq '
            .cluster.connection_manager = {
                "high_water": 400,
                "low_water": 100,
                "grace_period": "2m0s"
            } |
            .cluster.pubsub = {
                "seen_messages_ttl": "30m0s",
                "heartbeat_interval": "10s",
                "d_factor": 8,
                "history_gossip": 2,
                "history_length": 6,
                "flood_publish": false
            } |
            .cluster.dial_peer_timeout = "30s" |
            .cluster.monitor_ping_interval = "60s" |
            .cluster.peer_watch_interval = "60s" |
            .cluster.pin_recover_interval = "8m0s" |
            .cluster.state_sync_interval = "5m0s" |
            .consensus.crdt.batching = {
                "max_batch_size": 100,
                "max_batch_age": "1m"
            } |
            .pin_tracker.stateless.concurrent_pins = 5 |
            .ipfs_connector.ipfshttp.pin_timeout = "15m0s" |
            .monitor.pubsubmon.check_interval = "1m" |
            .allocator = {
                "balanced": {
                    "allocate_by": [
                        "tag:group",
                        "pinqueue",
                        "reposize"
                    ]
                }
            } |
            .informer = {
                "disk": {
                    "metric_ttl": "10m",
                    "metric_type": "reposize"
                },
                "pinqueue": {
                    "metric_ttl": "10m",
                    "weight_bucket_size": 100000
                },
                "tags": {
                    "metric_ttl": "10m",
                    "tags": {
                        "group": "default"
                    }
                }
            }
        ' "${IPFS_CLUSTER_PATH}/service.json" > "${IPFS_CLUSTER_PATH}/service_temp.json"

        mv "${IPFS_CLUSTER_PATH}/service_temp.json" "${IPFS_CLUSTER_PATH}/service.json"

        echo "Modification completed."
    fi

    # Check if CLUSTER_CRDT_TRUSTEDPEERS is not empty
    if [ -n "${CLUSTER_CRDT_TRUSTEDPEERS}" ]; then
        echo "CLUSTER_CRDT_TRUSTEDPEERS is set to ${CLUSTER_CRDT_TRUSTEDPEERS}. Bootstrapping..."
        export CLUSTER_FOLLOWERMODE=true
        append_or_replace "/.env.cluster" "CLUSTER_FOLLOWERMODE" "${CLUSTER_FOLLOWERMODE}"
        
        echo "/dns4/${poolName}.pools.functionyard.fula.network/tcp/9096/p2p/${CLUSTER_CRDT_TRUSTEDPEERS}" > "${IPFS_CLUSTER_PATH}/peerstore"
        /usr/local/bin/ipfs-cluster-service daemon --upgrade --bootstrap "/dns4/${poolName}.pools.functionyard.fula.network/tcp/9096/p2p/${CLUSTER_CRDT_TRUSTEDPEERS}" --leave
    else
        /usr/local/bin/ipfs-cluster-service daemon --upgrade
    fi
rm /uniondrive/.tmp/pool_creator.json || true
rm /uniondrive/.tmp/pool_users.json || true
rm /uniondrive/.tmp/pool_data.json || true