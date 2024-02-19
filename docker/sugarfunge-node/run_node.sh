#!/bin/sh

export NODE_PORT=9945
export IPFS_PORT=5001
export NODEAPI_PORT=4000

check_writable() {
  # Check if /internal exists and is writable
  if [ -d "/internal" ]; then
    if ! touch /internal/.tmp_write || ! rm /internal/.tmp_write; then
      echo "/internal is not writable."
      return 1
    fi
  else
    echo "/internal does not exist."
    return 1
  fi

  # Check if /uniondrive exists and is writable
  if [ -d "/uniondrive" ]; then
    if ! touch /uniondrive/.tmp_write || ! rm /uniondrive/.tmp_write; then
      echo "/uniondrive is not writable."
      return 1
    fi
  else
    echo "/uniondrive does not exist."
    return 1
  fi

  echo "Both /internal and /uniondrive exist and are writable."
  return 0
}


# Loop until /internal and /uniondrive are verified to exist and be writable
while ! check_writable; do
  echo "Waiting for /internal and /uniondrive to become writable..."
  sleep 5
done

# Wait indefinitely until the password file and /uniondrive folder are available from go-fule docker
while [ ! -f "/internal/box_props.json" ] || [ ! -d "/uniondrive" ] || [ ! -f "/internal/.secrets/node_key.txt" ] || [ ! -f "/internal/.secrets/secret_phrase.txt" ]; do
  [ ! -f "/internal/box_props.json" ] && echo "Waiting for /internal/box_props.json to become available..."
  [ ! -d "/uniondrive" ] && echo "Waiting for /uniondrive to become available..."
  [ ! -f "/internal/.secrets/node_key.txt" ] && echo "Waiting for /internal/.secrets/node_key.txt to become available..."
  [ ! -f "/internal/.secrets/secret_phrase.txt" ] && echo "Waiting for /internal/.secrets/secret_phrase.txt to become available..."
  sleep 3
done

# Read blox_seed from JSON file
blox_seed=$(jq -r '.blox_seed' /internal/box_props.json)

# Create /internal/.secrets directory if it doesn't exist
mkdir -p /internal/.secrets
blox_seed_changed=0
secret_phrase_changed=0

# Save blox_seed into password.txt
# Check if /internal/.secrets/password.txt exists and has the same content as $blox_seed
if [ ! -f "/internal/.secrets/password.txt" ] || [ "$blox_seed" != "$(xargs < '/internal/.secrets/password.txt')" ]; then
  printf "%s" "$blox_seed" > /internal/.secrets/password.txt
  blox_seed_changed=1
fi

# create Aura and Grandpa keys
# Generate the secret phrase only under specific conditions
if { [ -f "/internal/.secrets/secret_phrase.txt" ] && [ ! -f "/internal/.secrets/secret_seed.txt" ]; } || [ "$blox_seed_changed" -ne 0 ]; then
  #output=$(/sugarfunge-node key generate --scheme Sr25519 --password="$(cat '/internal/.secrets/password.txt')" 2>&1)
  output=$(/sugarfunge-node key inspect "$(xargs < '/internal/.secrets/secret_phrase.txt')" --scheme Sr25519 --password="$(xargs < '/internal/.secrets/password.txt')" 2>&1)
  echo "$output"
  secret_phrase=$(xargs < '/internal/.secrets/secret_phrase.txt')

  # Extract the Secret seed using awk and trim any extra spaces
  secret_seed=$(printf "%s" "$output" | grep "Secret seed:" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
  if [ ! -f "/internal/.secrets/secret_seed.txt" ] || [ "$secret_seed" != "$(xargs < '/internal/.secrets/secret_seed.txt')" ]; then
    printf "%s" "$secret_seed" > /internal/.secrets/secret_seed.txt
  fi

  # Extract the SS58 Address using awk and trim any extra spaces
  account=$(echo "$output" | grep "SS58 Address:" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
  if [ ! -f "/internal/.secrets/account.txt" ] || [ "$account" != "$(xargs < '/internal/.secrets/account.txt')" ]; then
    printf "%s" "$account" > /internal/.secrets/account.txt
  fi
fi

# create grandpa account
output_grandpa=$(/sugarfunge-node key inspect --password="$(xargs < '/internal/.secrets/password.txt')" --scheme Ed25519 "$(xargs < '/internal/.secrets/secret_phrase.txt')" 2>&1)

echo "$output_grandpa"
# Extract the SS58 Address using awk and trim any extra spaces
account_grandpa=$(printf "%s" "$output_grandpa" | grep "SS58 Address:" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
echo "$account_grandpa"
if [ ! -f "/internal/.secrets/account_grandpa.txt" ] || [ "$account_grandpa" != "$(cat /internal/.secrets/account_grandpa.txt)" ]; then
  printf "%s" "$account_grandpa" > /internal/.secrets/account_grandpa.txt
fi

node_key=$(xargs < '/internal/.secrets/node_key.txt')
if [ "$secret_phrase_changed" -ne 0 ] || [ "$blox_seed_changed" -ne 0 ] || [ ! -d "/internal/keys/" ] || [ -z "$(ls -A /internal/keys/)" ]; then

    #Remove saved keys
    rm -rf /internal/keys/*

    #Add Aura key to keystore
    /sugarfunge-node key insert --base-path=/uniondrive/chain --keystore-path=/internal/keys --chain /customSpecRaw.json --scheme Sr25519 --suri "$secret_phrase" --password="$(xargs < '/internal/.secrets/password.txt')" --key-type aura

    #Add Grandpa key to keystore
    ./sugarfunge-node key insert --base-path=/uniondrive/chain --keystore-path=/internal/keys --chain /customSpecRaw.json --scheme Ed25519 --suri "$secret_phrase" --password="$(xargs < '/internal/.secrets/password.txt')" --key-type gran
fi

# Wait for network availability
until ping -c 1 node.functionyard.fula.network; do
    echo "Waiting for network..."
    sleep 2
done
until ping -c 1 contract-api.functionyard.fula.network; do
    echo "Waiting for network..."
    sleep 2
done

# Start the node process
/sugarfunge-node --chain /customSpecRaw.json --enable-offchain-indexing true --base-path=/uniondrive/chain --keystore-path=/internal/keys --validator --port=30335 --rpc-port $NODE_PORT --rpc-external --rpc-cors=all --rpc-methods=Unsafe --name FulaNode --password="$(cat '/internal/.secrets/password.txt')" --bootnodes /dns4/node.functionyard.fula.network/tcp/30334/p2p/12D3KooWBeXV65svCyknCvG1yLxXVFwRxzBLqvBJnUF6W84BLugv --node-key=$node_key --offchain-worker always &
NODE_PID=$!

# Wait until the node is up and running (checks every second for up to 120 seconds)
counter=0
while ! nc -z 127.0.0.1 $NODE_PORT; do
  sleep 2
  counter=$((counter + 1))
  if [ $counter -ge 60 ]; then
    echo "Node service didn't start within 120 seconds. Exiting."
    exit 1
  fi
done

# Start the node api process
/sugarfunge-api --db-uri=/data --node-server ws://127.0.0.1:$NODE_PORT &
API_PID=$!

# Wait until the node is up and running (checks every second for up to 120 seconds)
counter=0
while ! nc -z 127.0.0.1 $NODEAPI_PORT; do
  sleep 1
  counter=$((counter + 1))
  if [ $counter -ge 60 ]; then
    echo "Node API service didn't start within 60 seconds. Exiting."
    exit 1
  fi
done

# Wait indefinitely until port 5001 is up and running
while ! nc -z 127.0.0.1 $IPFS_PORT; do
  sleep 2
  echo "Waiting for port $IPFS_PORT to be available..."
done

# Add a check for the Node API health response
while :; do
  response=$(curl -s -X POST "http://127.0.0.1:$NODEAPI_PORT/health")
  peers=$(echo $response | jq -r '.peers')
  if [ "$peers" -ge 3 ]; then
    echo "Node API is healthy with peers >= 3."
    break
  else
    echo "Waiting for Node API to have at least 3 peers..."
    sleep 5
  fi
done

sleep 120

# Read account from file
account=$(cat /internal/.secrets/account.txt)

# Check if the account exists by querying the API and checking the response code
while :; do
    response_code=$(curl -X POST "http://127.0.0.1:$NODEAPI_PORT/account/exists" \
        -H "Content-Type: application/json" \
        -d "{\"account\":\"${account}\"}" \
        -o /dev/null -s -w "%{http_code}\n")
    
    if [ "$response_code" -eq 200 ]; then
        echo "Account exists. Response code is 200."
        break
    else
        echo "Waiting for account to exist. Current response code: $response_code"
        sleep 10
    fi
done

secret_seed=$(xargs < '/internal/.secrets/secret_seed.txt')
aura_account=$(xargs < '/internal/.secrets/account.txt')
grandpa_account=$(xargs < '/internal/.secrets/account_grandpa.txt')
echo "secret_seed=$secret_seed and aura_account=$aura_account and grandpa_account=$grandpa_account"
if [ -n "$secret_seed" ] && [ -n "$aura_account" ] && [ -n "$grandpa_account" ]; then
  /proof-engine -- "$secret_seed" "$aura_account" "$grandpa_account" &
  PROOF_ENGINE_PID=$!
else
    echo "One or more required variables are empty."
    # Handle the error case here
fi

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
    if ! kill -0 "$PROOF_ENGINE_PID" 2>/dev/null; then
        exit_code=$?
        break
    fi
    sleep 5
done

# Exit with status of process that exited first
exit "$exit_code"
