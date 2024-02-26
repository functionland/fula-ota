#!/bin/sh

# This scripts runs before ipfs container
set -ex

fula_file_path="/internal/config.yaml"
temp_file="/internal/.env.cluster.tmp"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_files_and_folders() {
  if [ -d "/internal" ] && [ -d "/uniondrive" ] && [ -f "/internal/config.yaml" ] && [ -f "/internal/.ipfscluster_setup" ] && [ -f "/internal/ipfs-cluster/identity.json" ]; then
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
while [ -z "$poolName" ] || [ "$poolName" = "0" ]; do
    echo "Waiting for CLUSTER_CLUSTERNAME to be set..."
    if [ -f "$fula_file_path" ];then
        poolName=$(grep 'poolName:' "${fula_file_path}" | cut -d':' -f2 | tr -d ' "')
    fi
    sleep 60
done

get_poolcreator_peerid() {
  # Step 1: Call the URL to fetch pool data and save it to a temporary file
  wget -qO "/uniondrive/.tmp/pool_data.json" --post-data '{"pool_id": '"$CLUSTER_CLUSTERNAME"'}' "$cluster_url/fula/pool/all"

  # Step 2: Check if the request was successful (200 OK)
  response_code=$(head -n 1 "/uniondrive/.tmp/pool_data.json" | cut -d$' ' -f2)
  if [ "$response_code" = "200" ]; then
      # Step 3: Parse the creator_clusterpeerid from the JSON response
      creator_clusterpeerid=$(grep -o '"creator": "[^"]*"' "/uniondrive/.tmp/pool_data.json" | cut -d'"' -f4)

      # Step 4: Call the URL to fetch user data and save it to a temporary file
      wget -qO "/uniondrive/.tmp/pool_users.json" --post-data '{"pool_id": '"$CLUSTER_CLUSTERNAME"'}' "$cluster_url/fula/pool/users"

      # Step 5: Find the peer_id corresponding to the creator account from the response
      peer_id=$(grep -o '"account": "'"$creator_clusterpeerid"'"[^}]*"peer_id": "[^"]*"' "/uniondrive/.tmp/pool_users.json" | grep -o '"peer_id": "[^"]*"' | cut -d'"' -f4)

      # Step 6: Set CLUSTER_CRDT_TRUSTEDPEERS
      export CLUSTER_CRDT_TRUSTEDPEERS="$peer_id"
  else
      echo "Failed to fetch pool data. Response code: $response_code"
      exit 1
  fi
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
response=$(wget --spider -S "$cluster_url" 2>&1)

# Check if the response includes "200 OK"
if echo "$response" | grep -q 'HTTP/.* 200 OK'; then
    echo "Response is 200 OK, proceeding to download..."
    
    mkdir -p /uniondrive/.tmp
    wget -O "/uniondrive/.tmp/pool_creator.json" "${cluster_url}"
    creator_clusterpeerid=$(grep 'creator_clusterpeerid:' "/uniondrive/.tmp/pool_creator.json" | cut -d':' -f2 | tr -d ' "')
    export CLUSTER_CRDT_TRUSTEDPEERS="${creator_clusterpeerid}"
    append_or_replace "/.env.cluster" "CLUSTER_CRDT_TRUSTEDPEERS" "${CLUSTER_CRDT_TRUSTEDPEERS}"
    # Initialize ipfs-cluster-service if the configuration does not exist
    if [ ! -f /uniondrive/ipfs-cluster/service.json ]; then
        echo "Initializing ipfs-cluster-service..."
        ipfs-cluster-service init
    fi

    # Check if CLUSTER_CRDT_TRUSTEDPEERS is not empty
    if [ -n "${CLUSTER_CRDT_TRUSTEDPEERS}" ]; then
        echo "CLUSTER_CRDT_TRUSTEDPEERS is set to ${CLUSTER_CRDT_TRUSTEDPEERS}. Bootstrapping..."
        # Execute the command to bootstrap using the provided CLUSTER_CRDT_TRUSTEDPEERS
        export CLUSTER_FOLLOWERMODE=true
        append_or_replace "/.env.cluster" "CLUSTER_FOLLOWERMODE" "${CLUSTER_FOLLOWERMODE}"

        exec ipfs-cluster-service daemon --upgrade --bootstrap "/dnsaddr/cluster.${CLUSTER_CRDT_TRUSTEDPEERS}.functionyard.fula.network/p2p/${CLUSTER_CRDT_TRUSTEDPEERS}" --leave
    else
        exec ipfs-cluster-service daemon --upgrade
    fi
else
    echo "Response is not 200 OK, not downloading."
    exit 1
fi
rm /uniondrive/.tmp/pool_creator.json
rm /uniondrive/.tmp/pool_users.json
rm /uniondrive/.tmp/pool_data.json