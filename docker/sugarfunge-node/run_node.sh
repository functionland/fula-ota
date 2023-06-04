#!/bin/sh

export NODE_PORT=9945
# Start the node process
/sugarfunge-node --chain=local --enable-offchain-indexing true --bob --base-path=.tmp/b --port=30335 --ws-port $NODE_PORT --ws-external --rpc-cors=all --rpc-methods=Unsafe --rpc-external --bootnodes /ip4/127.0.0.1/tcp/30334/p2p/12D3KooWNxmYfzomt7EXfMSLuoaK68JzXnZkNjXyAYAwNrQTDx7Y &
  
# Start the node api process
/sugarfunge-api -s wss://localhost:$NODE_PORT &
  
# Wait for any process to exit
wait -n
  
# Exit with status of process that exited first
exit $?
