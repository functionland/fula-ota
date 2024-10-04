#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if streamr service is already installed
if systemctl is-active --quiet streamr-node.service; then
  echo "Streamr node service is already installed and running."
  exit 0
fi

NETWORK=$1
USER="pi"
HOME_DIR="/home/$USER"
STREAMR_DIR="$HOME_DIR/streamr-node"
CONFIG_DIR="$STREAMR_DIR/streamr/.streamr/config"
CONFIG_FILE="$CONFIG_DIR/default.json"

# Create necessary directories
mkdir -p "$STREAMR_DIR"
mkdir -p "$CONFIG_DIR"
chown "$USER":"$USER" -R "$HOME_DIR/streamr-node/streamr/.streamr"


# Check for required files
if [ ! -f "$HOME_DIR/.internal/.secrets/secret_seed.txt" ]; then
  echo "Error: secret_seed.txt not found."
  exit 1
fi

if [ ! -f "$STREAMR_DIR/operator-contract-address.txt" ]; then
  echo "Error: operator-contract-address.txt not found."
  exit 1
fi

# Check for network parameter
if [ "$1" != "testnet" ] && [ "$1" != "mainnet" ]; then
  echo "Usage: $0 [testnet|mainnet]"
  exit 1
fi

# Generate API key
API_KEY=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)

# Read private key and operator contract address
PRIVATE_KEY=$(cat "$HOME_DIR/.internal/.secrets/secret_seed.txt" | tr -d '[:space:]')
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
cp streamr-node.service /etc/systemd/system/

# Copy docker-compose file
cp docker-compose.yml "$STREAMR_DIR/"

# Reload systemd
systemctl daemon-reload

# Enable the service
systemctl enable streamr-node.service

echo "Streamr node installed successfully."