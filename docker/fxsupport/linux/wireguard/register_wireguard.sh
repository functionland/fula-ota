#!/bin/bash
# WireGuard support tunnel — server registration + config generation
# Registers device with support server, receives config, writes support.conf
set -e

FULA_LOG_PATH="/home/pi/fula.sh.log"
WG_DIR="/etc/wireguard"
STATE_DIR="/home/pi/.internal/wireguard"
STATE_FILE="${STATE_DIR}/registration.state"
REGISTER_URL="https://support.fx.land/api/v1/wireguard/register"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wireguard-register] $*" | tee -a "$FULA_LOG_PATH"
}

# Read device_id from machine-id
if [ ! -f /etc/machine-id ]; then
  log "ERROR: /etc/machine-id not found"
  exit 1
fi
device_id=$(cat /etc/machine-id)

# Try to get PeerID: kubo API first, then config file
peer_id=""
peer_id=$(curl -s -X POST --max-time 5 http://127.0.0.1:5001/api/v0/id 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('ID',''))" 2>/dev/null) || true

if [ -z "$peer_id" ]; then
  config_file="/home/pi/.internal/ipfs_data/config"
  if [ -f "$config_file" ]; then
    peer_id=$(python3 -c "
import json, sys
with open('$config_file') as f:
    print(json.load(f).get('Identity',{}).get('PeerID',''))
" 2>/dev/null) || true
  fi
fi

# Read WireGuard public key
if [ ! -f "${WG_DIR}/support_public.key" ]; then
  log "ERROR: WireGuard public key not found"
  exit 1
fi
public_key=$(cat "${WG_DIR}/support_public.key")

# Check if already registered with same PeerID
if [ -f "$STATE_FILE" ]; then
  registered_peer_id=$(grep "^peer_id=" "$STATE_FILE" 2>/dev/null | cut -d= -f2) || true
  # If already registered and PeerID unchanged (or both empty), skip
  if [ "$registered_peer_id" = "$peer_id" ]; then
    log "Already registered with same PeerID, skipping"
    exit 0
  fi
  log "PeerID changed (was: ${registered_peer_id:-empty}, now: ${peer_id:-empty}), re-registering"
fi

# Build registration payload
payload=$(python3 -c "
import json
print(json.dumps({
    'device_id': '$device_id',
    'peer_id': '$peer_id',
    'public_key': '$public_key'
}))
")

log "Registering with support server (device_id=${device_id}, peer_id=${peer_id:-none})..."

# POST to registration endpoint
response=$(curl -s -f --max-time 30 \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$REGISTER_URL" 2>&1) || {
  log "ERROR: Registration failed — server unreachable or returned error"
  exit 1
}

# Parse server response
server_public_key=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['server_public_key'])" 2>/dev/null) || {
  log "ERROR: Invalid server response — missing server_public_key"
  exit 1
}
endpoint=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['endpoint'])" 2>/dev/null) || {
  log "ERROR: Invalid server response — missing endpoint"
  exit 1
}
assigned_ip=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['assigned_ip'])" 2>/dev/null) || {
  log "ERROR: Invalid server response — missing assigned_ip"
  exit 1
}
allowed_ips=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['allowed_ips'])" 2>/dev/null) || {
  log "ERROR: Invalid server response — missing allowed_ips"
  exit 1
}

# Read private key
private_key=$(cat "${WG_DIR}/support_private.key")

# Write WireGuard config
cat > "${WG_DIR}/support.conf" <<EOF
[Interface]
PrivateKey = ${private_key}
Address = ${assigned_ip}

[Peer]
PublicKey = ${server_public_key}
Endpoint = ${endpoint}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

chmod 600 "${WG_DIR}/support.conf"

# Save registration state
mkdir -p "$STATE_DIR"
cat > "$STATE_FILE" <<EOF
device_id=${device_id}
peer_id=${peer_id}
registered_at=$(date -Iseconds)
endpoint=${endpoint}
assigned_ip=${assigned_ip}
EOF

log "Registration complete (assigned_ip=${assigned_ip}, endpoint=${endpoint})"
