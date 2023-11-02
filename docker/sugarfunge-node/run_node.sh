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
blox_seed_changed=0
secret_phrase_changed=0

# Save blox_seed into password.txt
# Check if /internal/.secrets/password.txt exists and has the same content as $blox_seed
if [ ! -f "/internal/.secrets/password.txt" ] || [ "$blox_seed" != "$(cat /internal/.secrets/password.txt)" ]; then
  echo "$blox_seed" > /internal/.secrets/password.txt
  blox_seed_changed=1
fi

#save the node key
# Generate the node key only under specific conditions
if [ ! -f "/internal/.secrets/node_key.txt" ] || [ "$blox_seed_changed" -ne 0 ]; then
  output=$(/sugarfunge-node key generate-node-key 2>&1)
  echo "$output"
  node_key=$(echo "$output" | tr ' ' '\n' | tail -n 1)
  echo "$node_key" > /internal/.secrets/node_key.txt

  # Extract the first line from node_peerid.txt
  node_peerid=$(echo "$output" | head -n 1)
  echo "$node_peerid" > /internal/.secrets/node_peerid.txt
fi

# create Aura and Grandpa keys
# Generate the secret phrase only under specific conditions
if [ ! -f "/internal/.secrets/secret_phrase.txt" ] || [ ! -f "/internal/.secrets/secret_seed.txt" ] || [ "$blox_seed_changed" -ne 0 ]; then
  output=$(/sugarfunge-node key generate --scheme Sr25519 --password-filename="/internal/.secrets/password.txt" 2>&1)
  echo "$output"
  secret_phrase=$(echo "$output" | grep "Secret phrase:" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
  if [ ! -f "/internal/.secrets/secret_phrase.txt" ] || [ "$secret_phrase" != "$(cat /internal/.secrets/secret_phrase.txt)" ]; then
    echo "$secret_phrase" > /internal/.secrets/secret_phrase.txt
    secret_phrase_changed=1
  fi

  # Extract the Secret seed using awk and trim any extra spaces
  secret_seed=$(echo "$output" | grep "Secret seed:" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
  if [ ! -f "/internal/.secrets/secret_seed.txt" ] || [ "$secret_seed" != "$(cat /internal/.secrets/secret_seed.txt)" ]; then
    echo "$secret_seed" > /internal/.secrets/secret_seed.txt
  fi

  # Extract the SS58 Address using awk and trim any extra spaces
  account=$(echo "$output" | grep "SS58 Address:" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
  if [ ! -f "/internal/.secrets/account.txt" ] || [ "$account" != "$(cat /internal/.secrets/account.txt)" ]; then
    echo "$account" > /internal/.secrets/account.txt
  fi
fi

# create grandpa account
secret_phrase=$(cat /internal/.secrets/secret_phrase.txt)
node_key=$(cat /internal/.secrets/node_key.txt)
if [ "$secret_phrase_changed" -ne 0 ] || [ "$blox_seed_changed" -ne 0 ] || [ ! -d "/internal/keys/" ] || [ -z "$(ls -A /internal/keys/)" ]; then

    #Remove saved keys
    rm -rf /internal/keys/*

    #Add Aura key to keystore
    /sugarfunge-node key insert --base-path=/uniondrive/chain --keystore-path=/internal/keys --chain /customSpecRaw.json --scheme Sr25519 --suri "$secret_phrase" --password-filename="/internal/.secrets/password.txt" --key-type aura

    #Add Grandpa key to keystore
    ./sugarfunge-node key insert --base-path=/uniondrive/chain --keystore-path=/internal/keys --chain /customSpecRaw.json --scheme Ed25519 --suri "$secret_phrase" --password-filename="/internal/.secrets/password.txt" --key-type gran
fi

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
