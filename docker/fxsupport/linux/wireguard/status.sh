#!/bin/bash
# WireGuard support tunnel — JSON status output

STATE_FILE="/home/pi/.internal/wireguard/registration.state"

installed=false
registered=false
active=false
endpoint=""
assigned_ip=""
peer_id_registered=""

# Check installed
if command -v wg >/dev/null 2>&1 && \
   [ -f /etc/wireguard/support_private.key ] && \
   [ -f /etc/wireguard/support_public.key ]; then
  installed=true
fi

# Check registered
if [ -f "$STATE_FILE" ]; then
  registered=true
  endpoint=$(grep "^endpoint=" "$STATE_FILE" 2>/dev/null | cut -d= -f2) || true
  assigned_ip=$(grep "^assigned_ip=" "$STATE_FILE" 2>/dev/null | cut -d= -f2) || true
  peer_id_registered=$(grep "^peer_id=" "$STATE_FILE" 2>/dev/null | cut -d= -f2) || true
fi

# Check active
if ip link show support >/dev/null 2>&1; then
  active=true
fi

python3 -c "
import json
print(json.dumps({
    'installed': $installed,
    'registered': $registered,
    'active': $active,
    'endpoint': '$endpoint',
    'assigned_ip': '$assigned_ip',
    'peer_id_registered': '$peer_id_registered'
}, cls=None))
" 2>/dev/null || echo '{"installed":'$installed',"registered":'$registered',"active":'$active',"endpoint":"'$endpoint'","assigned_ip":"'$assigned_ip'","peer_id_registered":"'$peer_id_registered'"}'
