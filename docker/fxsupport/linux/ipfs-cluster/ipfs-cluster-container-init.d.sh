#!/bin/sh

# This scripts runs before ipfs container
set -ex

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_files_and_folders() {
  if [ -d "/internal" ] && [ -d "/uniondrive" ] && [ -f "/internal/config.yaml" ] && [ -f "/internal/.ipfscluster_setup" ]; then
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

while ! check_files_and_folders || ! check_writable; do
  log "Waiting for /internal and /uniondrive to become available and writable..."
  sleep 5
done

fula_file_path="/internal/config.yaml"

poolName=""

# Wait for CLUSTER_SECRET to be set
while [ -z "$poolName" ] || [ "$poolName" = "0" ]; do
    echo "Waiting for CLUSTER_CLUSTERNAME to be set..."
    if [ -f "$fula_file_path" ];then
        poolName=$(grep 'poolName:' "${fula_file_path}" | cut -d':' -f2 | tr -d ' "')
    fi
    sleep 60
done

export CLUSTER_CLUSTERNAME="${poolName}"
echo "CLUSTER_CLUSTERNAME=${CLUSTER_CLUSTERNAME}" >> /.env.cluster

# URL to check
cluster_url="https://pools.functionyard.fula.network/${CLUSTER_CLUSTERNAME}" #This can be changed to blockchain api if we add metadata to each pool with 'creator_clusterpeerid' for example

echo "CLUSTER_CLUSTERNAME is set."
secret=$(printf "%s" "${CLUSTER_CLUSTERNAME}" | sha256sum | cut -d' ' -f1)
export CLUSTER_SECRET="${secret}"
echo "CLUSTER_SECRET=${CLUSTER_SECRET}" >> /.env.cluster

node_account=$(cat "/internal/.secrets/account.txt")
export CLUSTER_PEERNAME="${node_account}" #This is the node Aura account id
echo "CLUSTER_PEERNAME=${CLUSTER_PEERNAME}" >> /.env.cluster

# Perform a HEAD request to check the response code
response=$(wget --spider -S "$cluster_url" 2>&1)

# Check if the response includes "200 OK"
if echo "$response" | grep -q 'HTTP/.* 200 OK'; then
    echo "Response is 200 OK, proceeding to download..."
    
    mkdir -p /uniondrive/.tmp
    wget -O "/uniondrive/.tmp/pool_creator.json" "${cluster_url}"
    creator_clusterpeerid=$(grep 'creator_clusterpeerid:' "/uniondrive/.tmp/pool_creator.json" | cut -d':' -f2 | tr -d ' "')
    export CLUSTER_CRDT_TRUSTEDPEERS="${creator_clusterpeerid}"
    echo "CLUSTER_CRDT_TRUSTEDPEERS=${CLUSTER_CRDT_TRUSTEDPEERS}" >> /.env.cluster
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
        echo "CLUSTER_FOLLOWERMODE=${CLUSTER_FOLLOWERMODE}" >> /.env.cluster
        exec ipfs-cluster-service daemon --upgrade --bootstrap "${CLUSTER_CRDT_TRUSTEDPEERS}" --leave
    else
        exec ipfs-cluster-service daemon --upgrade
    fi
else
    echo "Response is not 200 OK, not downloading."
    exit 1
fi
rm /uniondrive/.tmp/pool_creator.json