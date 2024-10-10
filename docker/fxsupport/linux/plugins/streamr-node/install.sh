#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if streamr service is already installed
if systemctl list-unit-files | grep -q streamr-node.service; then
  echo "Streamr node service is already installed."
  exit 0
fi

USER="pi"
PLUGIN_NAME="streamr-node"
INTERNAL_DIR="/home/$USER/.internal"
STREAMR_DIR="$INTERNAL_DIR/$PLUGIN_NAME"
CONFIG_DIR="$STREAMR_DIR/streamr/.streamr/config"
CONFIG_FILE="$CONFIG_DIR/default.json"
PRIVATE_KEY_FILE="$STREAMR_DIR/private_key.txt"
STREAMR_NODE_FILE="$STREAMR_DIR/node_addr.txt"
PLUGIN_EXEC_DIR="/usr/bin/fula/plugins/${PLUGIN_NAME}"

# Create necessary directories
mkdir -p "$STREAMR_DIR"
mkdir -p "$CONFIG_DIR"
chown "$USER":"$USER" -R "$STREAMR_DIR/streamr/.streamr"

if pip list | grep -F eth-account > /dev/null; then
    echo "eth-account is already installed"
else
    echo "eth-account is not installed. Installing now..."
    pip install eth-account
    
    # Check if installation was successful
    if [ $? -eq 0 ]; then
        echo "eth-account has been successfully installed"
    else
        echo "Failed to install eth-account"
        exit 1
    fi
fi

# Check for required files
if [ ! -f "$INTERNAL_DIR/.secrets/secret_seed.txt" ]; then
  echo "Error: secret_seed.txt not found."
  exit 1
fi

# Check for required files
if [ ! -f "$INTERNAL_DIR/.secrets/password.txt" ]; then
  echo "Error: password.txt not found."
  exit 1
fi

SECRET_SEED=$(cat "$INTERNAL_DIR/.secrets/secret_seed.txt" | tr -d '[:space:]')

if [ -z "$SECRET_SEED" ]; then
    echo "Error: SECRET_SEED is empty or file is missing."
    exit 1
fi

# Generate a salt (you can store this salt alongside your secret seed if you want)
SALT=$(cat "$INTERNAL_DIR/.secrets/password.txt" | tr -d '[:space:]')
if [ -z "$SALT" ]; then
    echo "Error: SALT is empty or file is missing."
    exit 1
fi

# Use PBKDF2 to derive a private key
PRIVATE_KEY=$(echo -n "${SECRET_SEED}${PLUGIN_NAME}" | 
  openssl dgst -binary -sha256 -mac HMAC -macopt "key:${SALT}${PLUGIN_NAME}" | 
  od -An -tx1 -v | 
  tr -d ' \n' | 
  sed 's/^/0x/')

if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY is empty or file is missing."
    exit 1
fi

# Store the private key in a file
echo "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"

NODE_ADDR=$(python "${PLUGIN_EXEC_DIR}/custom/generate_evm_address.py" "$PRIVATE_KEY" | tr -d '[:space:]')

echo "$NODE_ADDR" > "$STREAMR_NODE_FILE"

# Check for network parameter
if [ -z "$NODE_ADDR" ]; then
  echo "Error: Node Address is empty."
  exit 1
fi

if [ ! -f "$STREAMR_DIR/operator-contract-address.txt" ]; then
  echo "Error: operator-contract-address.txt not found."
  exit 1
fi

if [ ! -f "$PRIVATE_KEY_FILE" ]; then
  echo "Error: private file not created."
  exit 1
fi

if [ ! -f "$STREAMR_NODE_FILE" ]; then
  echo "Error: node address not found."
  exit 1
fi

NETWORK=$(cat "$STREAMR_DIR/network.txt" | tr -d '[:space:]')
# Check for network parameter
if [ "$NETWORK" != "testnet" ] && [ "$NETWORK" != "mainnet" ]; then
  echo "Usage: $0 [testnet|mainnet]"
  exit 1
fi

HASH=$(echo -n "$PRIVATE_KEY" | openssl dgst -sha256 -binary)

# Encode the hash in base64 and make it URL-safe
API_KEY=$(echo -n "$HASH" | base64 | tr '/+' '_-' | tr -d '=' | cut -c1-32)

OPERATOR_ADDRESS=$(cat "$STREAMR_DIR/operator-contract-address.txt" | tr -d '[:space:]')

# Set environment based on input
if [ "$NETWORK" == "testnet" ]; then
  ENVIRONMENT="polygonAmoy"
else
  ENVIRONMENT="polygon"
fi

# Create config file
cat > "$CONFIG_FILE" <<EOL
{
    "\$schema": "https://schema.streamr.network/config-v3.schema.json",
    "client": {
        "auth": {
            "privateKey": "$PRIVATE_KEY"
        },
        "environment": "$ENVIRONMENT"
    },
    "plugins": {
        "operator": {
            "operatorContractAddress": "$OPERATOR_ADDRESS"
        }
    },
    "apiAuthentication": {
        "keys": [
            "$API_KEY"
        ]
    }
}
EOL

# Copy service file
cp "${PLUGIN_EXEC_DIR}/streamr-node.service" "/etc/systemd/system/"

# Copy docker-compose file
cp "${PLUGIN_EXEC_DIR}/docker-compose.yml" "$STREAMR_DIR/"

# Reload systemd
systemctl daemon-reload

# Enable the service
systemctl enable streamr-node.service

echo "Streamr node installed successfully."

exit 0