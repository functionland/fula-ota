#!/bin/sh

export NODE_PORT=9945
# Start the node process
/sugarfunge-node --chain /customSpecRaw.json --enable-offchain-indexing true --base-path=/uniondrive/chain --keystore-path=/internal/keys --port=30335 --rpc-port $NODE_PORT --rpc-external --rpc-cors=all --rpc-methods=Unsafe --name FulaNode --password-filename="/internal/.secrets/password.txt" --bootnodes /dns4/node.functionyard.fula.network/tcp/30334/p2p/12D3KooWBeXV65svCyknCvG1yLxXVFwRxzBLqvBJnUF6W84BLugv &
NODE_PID=$!

# Wait until the node is up and running (checks every second for up to 60 seconds)
counter=0
while ! nc -z 127.0.0.1 $NODE_PORT; do
  sleep 1
  counter=$((counter + 1))
  if [ $counter -ge 60 ]; then
    echo "Node service didn't start within 60 seconds. Exiting."
    exit 1
  fi
done

# Start the node api process
/sugarfunge-api --db-uri=/data --node-server ws://127.0.0.1:$NODE_PORT &
API_PID=$!

Operator_seed=$(cat /internal/.secrets/seed.txt)

/proof-engine -- $Operator_seed &
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
