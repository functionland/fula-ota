#!/bin/sh

exit 1 # Not implemented yet
fula_file_path="/internal/config.yaml"

poolName=""

# Wait for CLUSTER_SECRET to be set
while [ -z "${poolName}" ]; do
    echo "Waiting for CLUSTER_CLUSTERNAME to be set..."
    if [ -f "$fula_file_path" ];then
        poolName=$(grep 'poolName:' "${fula_file_path}" | cut -d':' -f2 | tr -d ' "')
    fi
    sleep 60
done

export CLUSTER_CLUSTERNAME="${poolName}"

# URL to check
cluster_url="https://pools.functionyard.fula.network/${CLUSTER_CLUSTERNAME}" #This can be changed to blockchain api if we add metadata to each pool with 'creator_clusterpeerid' for example

echo "CLUSTER_CLUSTERNAME is set."
secret=$(printf "%s" "${CLUSTER_CLUSTERNAME}" | sha256sum | cut -d' ' -f1)
export CLUSTER_SECRET=${secret}
export CLUSTER_PEERNAME=$(get the account id of blox stored in a file somewhere i cannot remember now)
export CLUSTER_ID=$(probabely should be geberated by calling go-fula deterministically like ipfs peerid)
export CLUSTER_PRIVATEKEY=$(probabely should be geberated by calling go-fula deterministically like ipfs identity)

# Perform a HEAD request to check the response code
response=$(wget --spider -S "$cluster_url" 2>&1)

# Check if the response includes "200 OK"
if echo "$response" | grep -q 'HTTP/.* 200 OK'; then
    echo "Response is 200 OK, proceeding to download..."
    
    mkdir -p /uniondrive/.tmp
    wget -O "/uniondrive/.tmp/pool_creator.json" "${cluster_url}"
    creator_clusterpeerid=$(grep 'creator_clusterpeerid:' "/uniondrive/.tmp/pool_creator.json" | cut -d':' -f2 | tr -d ' "')
    export CLUSTER_CRDT_TRUSTEDPEERS="${creator_clusterpeerid}"
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
        exec ipfs-cluster-service daemon --upgrade --bootstrap "${CLUSTER_CRDT_TRUSTEDPEERS}" --leave
    else
        exec ipfs-cluster-service daemon --upgrade
    fi
else
    echo "Response is not 200 OK, not downloading."
fi
rm /uniondrive/.tmp/pool_creator.json