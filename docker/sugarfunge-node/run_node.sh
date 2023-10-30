#!/bin/sh

export NODE_PORT=9945
export IPFS_PORT=5001

# Wait indefinitely until the password file and /uniondrive folder are available
while [ ! -f "/internal/box_props.json" ] || [ ! -d "/uniondrive" ]; do
  sleep 3
  [ ! -f "/internal/box_props.json" ] && echo "Waiting for /internal/box_props.json to become available..."
  [ ! -d "/uniondrive" ] && echo "Waiting for /uniondrive to become available..."
done

# Read blox_seed from JSON file
blox_seed=$(jq -r '.blox_seed' /internal/box_props.json)

# Create /internal/.secrets directory if it doesn't exist
mkdir -p /internal/.secrets

# Save blox_seed into password.txt
echo "$blox_seed" > /internal/.secrets/password.txt

#save the node key
# Generate the key and save the output to a variable
output=$(/sugarfunge-node key generate-node-key)

# Extract the 'key' field from the output
node_key=$(echo "$output" | grep "key:" | awk '{print $2}')

#echo can be removed
echo "$node_key"

# create Aura and Grandpa keys
# Generate the key and save the output to a variable
output=$(/sugarfunge-node key generate --scheme Sr25519 --password-filename="/internal/.secrets/password.txt")

# Extract the 'Secret phrase' field from the output
secret_phrase=$(echo "$output" | grep "Secret phrase:" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')

# echo can be removed
echo "$secret_phrase"  # You can save this to a file or use it as needed

# create grandpa account
/sugarfunge-node key inspect --password-filename="/internal/.secrets/password.txt" --scheme Ed25519 "$secret_phrase"

#Add Aura key to keystore
/sugarfunge-node key insert --base-path=/uniondrive/chain --keystore-path=/internal/keys --chain /customSpecRaw.json --scheme Sr25519 --suri "$secret_phrase" --password-filename="/internal/.secrets/password.txt" --key-type aura

#Add Grandpa key to keystore
./sugarfunge-node key insert --base-path=/uniondrive/chain --keystore-path=/internal/keys --chain /customSpecRaw.json --scheme Ed25519 --suri "$secret_phrase" --password-filename="/internal/.secrets/password.txt" --key-type gran

# Start the node process
/sugarfunge-node --chain /customSpecRaw.json --enable-offchain-indexing true --base-path=/uniondrive/chain --keystore-path=/internal/keys --port=30335 --rpc-port $NODE_PORT --rpc-external --rpc-cors=all --rpc-methods=Unsafe --name FulaNode --password-filename="/internal/.secrets/password.txt" --bootnodes /dns4/node.functionyard.fula.network/tcp/30334/p2p/12D3KooWBeXV65svCyknCvG1yLxXVFwRxzBLqvBJnUF6W84BLugv --node-key=$node_key --offchain-worker always &
NODE_PID=$!

# Wait until the node is up and running (checks every second for up to 120 seconds)
counter=0
while ! nc -z 127.0.0.1 $NODE_PORT; do
  sleep 2
  counter=$((counter + 1))
  if [ $counter -ge 60 ]; then
    echo "Node service didn't start within 60 seconds. Exiting."
    exit 1
  fi
done

# Start the node api process
/sugarfunge-api --db-uri=/data --node-server ws://127.0.0.1:$NODE_PORT &
API_PID=$!

# Wait indefinitely until port 5001 is up and running
while ! nc -z 127.0.0.1 $IPFS_PORT; do
  sleep 2
  echo "Waiting for port 5001 to be available..."
done

/proof-engine -- $node_key &
PROOF_ENGINE_PID=$!

# Wait for any process to exit
while :; do
    if ! kill -0 $NODE_PID 2>/dev/null; then
        exit_code=$?
        break
    fi
    if ! kill -0 $API_PID 2>/dev/null; then
        exit_code=$?
        break
    fi
    if ! kill -0 $PROOF_ENGINE_PID 2>/dev/null; then
        exit_code=$?
        break
    fi
    sleep 1
done

# Exit with status of process that exited first
exit $exit_code
