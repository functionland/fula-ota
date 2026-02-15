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

MASTER_KUBO_PEERID=""
CLUSTER_BOOTSTRAP_ADDRS=""
MASTER_KUBO_ADDRS=""
MASTER_KUBO_VERSION=""

get_poolcreator_peerid() {
  local max_attempts=10
  local attempt=1
  local endpoint="https://pools.fx.land/pools/${poolName}"

  log "Fetching master peer IDs from ${endpoint}..."

  while [ $attempt -le $max_attempts ]; do
    response=$(curl -s --connect-timeout 10 --max-time 15 "${endpoint}" 2>/dev/null)
    cluster_peer_id=$(echo "$response" | jq -r '."ipfs-cluster-peerid" // empty' 2>/dev/null)
    kubo_peer_id=$(echo "$response" | jq -r '."kubo-peerid" // empty' 2>/dev/null)

    if [ -n "$cluster_peer_id" ] && [ "$cluster_peer_id" != "null" ]; then
      log "Fetched master cluster peer ID: $cluster_peer_id (attempt $attempt)"
      export CLUSTER_CRDT_TRUSTEDPEERS="$cluster_peer_id"
      if [ -n "$kubo_peer_id" ] && [ "$kubo_peer_id" != "null" ]; then
        MASTER_KUBO_PEERID="$kubo_peer_id"
        log "Fetched master kubo peer ID: $kubo_peer_id"
      fi

      # Extract ipfs-cluster direct addresses for bootstrap/peerstore
      CLUSTER_BOOTSTRAP_ADDRS=$(echo "$response" | jq -r '.ipfs_cluster.addresses[]?' 2>/dev/null)
      if [ -n "$CLUSTER_BOOTSTRAP_ADDRS" ]; then
        addr_count=$(printf '%s\n' "$CLUSTER_BOOTSTRAP_ADDRS" | wc -l)
        log "Fetched $addr_count cluster bootstrap addresses from API"
      fi

      # Extract master kubo direct addresses for peering
      # Filter out: localhost (127.0.0.1, ::1) and relay circuits (p2p-circuit)
      MASTER_KUBO_ADDRS=$(echo "$response" | jq -r '.kubo.Addresses[]?' 2>/dev/null | \
        grep -v '127\.0\.0\.1' | grep -v '/::1/' | grep -v 'p2p-circuit' || true)
      if [ -n "$MASTER_KUBO_ADDRS" ]; then
        addr_count=$(printf '%s\n' "$MASTER_KUBO_ADDRS" | wc -l)
        log "Fetched $addr_count direct kubo peering addresses from API"
      else
        log "No direct kubo addresses from API (master may be behind NAT)"
      fi

      # Extract master kubo version for compatibility logging
      MASTER_KUBO_VERSION=$(echo "$response" | jq -r '.kubo.AgentVersion // empty' 2>/dev/null)
      if [ -n "$MASTER_KUBO_VERSION" ]; then
        log "Master kubo version: $MASTER_KUBO_VERSION"
      fi

      # Note: cluster_peers and cluster_peers_addresses are NOT used for peerstore.
      # These are dynamic (peers join/leave freely) and stale entries cause unnecessary
      # connection attempts. The master peer address alone is sufficient for bootstrap;
      # CRDT gossip handles ongoing peer discovery after initial connection.

      return 0
    fi
    log "Attempt $attempt/$max_attempts: Could not fetch master peer IDs, retrying in 30s..."
    sleep 30
    attempt=$((attempt + 1))
  done

  # Fallback to hardcoded value (pre-separation master identity)
  log "Warning: Could not fetch master peer IDs after $max_attempts attempts, using hardcoded fallback"
  export CLUSTER_CRDT_TRUSTEDPEERS="12D3KooWS79EhkPU7ESUwgG4vyHHzW9FDNZLoWVth9b5N5NSrvaj"
}


export CLUSTER_CLUSTERNAME="${poolName}"
append_or_replace "/.env.cluster" "CLUSTER_CLUSTERNAME" "${CLUSTER_CLUSTERNAME}"


echo "CLUSTER_CLUSTERNAME is set."
secret=$(printf "%s" "${CLUSTER_CLUSTERNAME}" | sha256sum | cut -d' ' -f1)
export CLUSTER_SECRET="${secret}"
append_or_replace "/.env.cluster" "CLUSTER_SECRET" "${CLUSTER_SECRET}"

# Function to get kubo peer ID for use as CLUSTER_PEERNAME
get_ipfs_peer_id() {
    peer_id=""

    # Method 1: Read kubo peer ID from kubo's deployed config
    # Available via volume mount /home/pi/.internal:/internal (docker-compose)
    # Written by initipfs BEFORE initipfscluster, so always exists at this point
    kubo_config="/internal/ipfs_data/config"
    if [ -f "$kubo_config" ]; then
        peer_id=$(jq -r '.Identity.PeerID // empty' "$kubo_config" 2>/dev/null)
        if [ -n "$peer_id" ] && [ "$peer_id" != "null" ]; then
            echo "Found kubo peer ID from kubo config: $peer_id" >&2
            echo "$peer_id"
            return 0
        fi
    fi

    # Method 2: Try to get peer ID from kubo API (fallback, requires kubo running)
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

    # Add master's kubo peer to follower's kubo Peering for faster content discovery
    if [ -n "${MASTER_KUBO_PEERID}" ] && [ "${MASTER_KUBO_PEERID}" != "${ipfs_peer_id}" ]; then
      # Add direct kubo addresses from API (non-localhost, non-relay)
      if [ -n "${MASTER_KUBO_ADDRS}" ]; then
        printf '%s\n' "${MASTER_KUBO_ADDRS}" | while IFS= read -r addr; do
          [ -z "$addr" ] && continue
          log "Adding kubo peering address from API: ${addr}"
          curl -s -X POST "http://127.0.0.1:5001/api/v0/swarm/peering/add?arg=${addr}" 2>/dev/null || true
        done
      fi

      # Always add the constructed DNS address as reliable fallback
      peering_addr="/dns4/${poolName}.pools.functionyard.fula.network/tcp/4001/p2p/${MASTER_KUBO_PEERID}"
      log "Adding master kubo peer to peering (DNS): ${peering_addr}"
      curl -s -X POST "http://127.0.0.1:5001/api/v0/swarm/peering/add?arg=${peering_addr}" 2>/dev/null
      if [ $? -eq 0 ]; then
        log "Successfully added master kubo DNS peering address"
      else
        log "Warning: Could not add master kubo peer to peering via API"
      fi

      # Kubo version compatibility check
      if [ -n "${MASTER_KUBO_VERSION}" ]; then
        local_version_json=$(curl -s -X POST "http://127.0.0.1:5001/api/v0/version" 2>/dev/null)
        local_kubo_version=$(echo "$local_version_json" | jq -r '.Version // empty' 2>/dev/null)
        if [ -n "$local_kubo_version" ]; then
          log "Local kubo version: kubo/$local_kubo_version"
          master_major=$(echo "$MASTER_KUBO_VERSION" | sed 's|kubo/||' | cut -d'/' -f1 | cut -d'.' -f1)
          master_minor=$(echo "$MASTER_KUBO_VERSION" | sed 's|kubo/||' | cut -d'/' -f1 | cut -d'.' -f2)
          local_major=$(echo "$local_kubo_version" | cut -d'.' -f1)
          local_minor=$(echo "$local_kubo_version" | cut -d'.' -f2)
          if [ "$master_major" != "$local_major" ]; then
            log "WARNING: Kubo MAJOR version mismatch! Master: ${MASTER_KUBO_VERSION}, Local: kubo/${local_kubo_version}. This will likely cause protocol incompatibility."
          elif [ "$master_minor" != "$local_minor" ]; then
            log "NOTICE: Kubo minor version difference. Master: ${MASTER_KUBO_VERSION}, Local: kubo/${local_kubo_version}. Should be compatible but consider updating."
          else
            log "Kubo version compatible: Master=${MASTER_KUBO_VERSION}, Local=kubo/${local_kubo_version}"
          fi
        fi
      fi
    else
      if [ -n "${MASTER_KUBO_PEERID}" ]; then
        log "This node is the pool master — skipping kubo peering add"
      fi
    fi

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

        # Construct the DNS fallback address (always reliable)
        constructed_addr="/dns4/${poolName}.pools.functionyard.fula.network/tcp/9096/p2p/${CLUSTER_CRDT_TRUSTEDPEERS}"

        # Populate peerstore and select bootstrap address
        if [ -n "${CLUSTER_BOOTSTRAP_ADDRS}" ]; then
          # Use actual addresses from API for peerstore
          printf '%s\n' "${CLUSTER_BOOTSTRAP_ADDRS}" > "${IPFS_CLUSTER_PATH}/peerstore"
          # Append constructed DNS address as fallback entry
          echo "${constructed_addr}" >> "${IPFS_CLUSTER_PATH}/peerstore"
          # Use the first API address (typically TCP) for --bootstrap flag
          bootstrap_addr=$(printf '%s\n' "${CLUSTER_BOOTSTRAP_ADDRS}" | head -1)
          log "Using API-provided bootstrap address: ${bootstrap_addr}"
          log "Peerstore populated with API addresses + DNS fallback"
        else
          # Fallback to constructed DNS address only
          bootstrap_addr="${constructed_addr}"
          echo "${bootstrap_addr}" > "${IPFS_CLUSTER_PATH}/peerstore"
          log "Using constructed DNS bootstrap address: ${bootstrap_addr}"
        fi

        /usr/local/bin/ipfs-cluster-service daemon --upgrade --bootstrap "${bootstrap_addr}" --leave
    else
        /usr/local/bin/ipfs-cluster-service daemon --upgrade
    fi
rm /uniondrive/.tmp/pool_creator.json || true
rm /uniondrive/.tmp/pool_users.json || true
rm /uniondrive/.tmp/pool_data.json || true