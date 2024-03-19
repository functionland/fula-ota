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
  if touch "/uniondrive/.tmp3_write_check" && rm "/uniondrive/.tmp3_write_check"; then
    return 0 # Success
  else
    return 1 # Failure
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
# URL to check
cluster_url="https://api.node3.functionyard.fula.network" #This can be changed to blockchain api if we add metadata to each pool with 'creator_clusterpeerid' for example


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
  # Step 1: Call the URL to fetch pool data and save it to a temporary file
  if ! curl -s -X POST -H 'Content-Type: application/json' -d "{\"pool_id\": $CLUSTER_CLUSTERNAME}" "$cluster_url/fula/pool" -o "/uniondrive/.tmp/pool_data.json"; then
      echo "Failed to fetch pool data"
      exit 1
  fi

  # Step 2: Parse the creator_clusterpeerid from the JSON response
  creator_clusterpeerid=$(jq -r --arg CLUSTER_CLUSTERNAME "$CLUSTER_CLUSTERNAME" '.pools[] | select(.pool_id == ($CLUSTER_CLUSTERNAME | tonumber)) | .creator' "/uniondrive/.tmp/pool_data.json")

  # Check if creator_clusterpeerid is empty or not found
  if [ -z "$creator_clusterpeerid" ]; then
      echo "Creator cluster peer ID not found."
      exit 1
  fi

  # Step 3: Call the URL to fetch user data and save it to a temporary file
  curl -s -X POST -H 'Content-Type: application/json' -d "{\"pool_id\": $CLUSTER_CLUSTERNAME}" "$cluster_url/fula/pool/users" -o "/uniondrive/.tmp/pool_users.json"

  # Step 4: Find the peer_id corresponding to the creator account from the response
  peer_id=$(jq -r --arg creator_clusterpeerid "$creator_clusterpeerid" '.users[] | select(.account == $creator_clusterpeerid) | .peer_id' "/uniondrive/.tmp/pool_users.json")

  # Check if peer_id is empty or not found
  if [ -z "$peer_id" ]; then
      echo "Peer ID for the creator not found."
      exit 1
  fi

  # Step 5: Set CLUSTER_CRDT_TRUSTEDPEERS
  export CLUSTER_CRDT_TRUSTEDPEERS="$peer_id"
}


export CLUSTER_CLUSTERNAME="${poolName}"
append_or_replace "/.env.cluster" "CLUSTER_CLUSTERNAME" "${CLUSTER_CLUSTERNAME}"


echo "CLUSTER_CLUSTERNAME is set."
secret=$(printf "%s" "${CLUSTER_CLUSTERNAME}" | sha256sum | cut -d' ' -f1)
export CLUSTER_SECRET="${secret}"
append_or_replace "/.env.cluster" "CLUSTER_SECRET" "${CLUSTER_SECRET}"

node_account=$(cat "/internal/.secrets/account.txt")
export CLUSTER_PEERNAME="${node_account}" #This is the node Aura account id
append_or_replace "/.env.cluster" "CLUSTER_PEERNAME" "${CLUSTER_PEERNAME}"

# Perform a HEAD request to check the response code
success=0
while [ $success -eq 0 ]; do
    echo "Request failed, retrying in 60 seconds..."
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"pool_id": 1}' "$cluster_url/fula/pool")
    case $status_code in
    2*)
        echo "Success (This indicates a 2xx response)"
        success=1
        ;;
    *)
        echo "Failure (This could indicate a non-2xx response, network error, etc.)"
        sleep 60
        ;;
    esac
done
echo "Request to pool succeeded with response 200"
    
    mkdir -p /uniondrive/.tmp
    get_poolcreator_peerid
    append_or_replace "/.env.cluster" "CLUSTER_CRDT_TRUSTEDPEERS" "${CLUSTER_CRDT_TRUSTEDPEERS}"
    # Initialize ipfs-cluster-service if the configuration does not exist
    if [ ! -f "${IPFS_CLUSTER_PATH}/service.json" ]; then
        echo "Initializing ipfs-cluster-service..."
        /usr/local/bin/ipfs-cluster-service init
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