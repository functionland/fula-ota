#!/bin/bash
# lan_smoke_from_peer.sh — verify blox-ai HTTP API is reachable on the LAN.
#
# IMPORTANT: run this from a PEER LAN HOST (your workstation/laptop on
# the same Wi-Fi/Ethernet as the blox), NOT from the blox itself. Running
# `curl http://<blox-ip>:8083/health` on the blox only proves localhost
# reachability — it tells you nothing about whether the firewall has
# actually opened the port to the LAN.
#
# Usage:
#   ./lan_smoke_from_peer.sh <blox-ip>             # uses default port 8083
#   ./lan_smoke_from_peer.sh <blox-ip> <port>      # custom port
#
# Exits 0 on success, non-zero on failure.

set -e

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <blox-ip> [port]" >&2
    echo "       run from a peer host on the same LAN, NOT from the blox" >&2
    exit 2
fi

BLOX_IP="$1"
PORT="${2:-8083}"
URL="http://${BLOX_IP}:${PORT}/health"

# Refuse to run if we appear to be ON the blox itself. The whole point of
# this script is firewall reachability from a peer; running on-device
# gives a false-positive.
if [ -f /etc/fula/version ] || [ -d /home/pi/.internal/plugins/blox-ai ]; then
    echo "ERROR: this script is meant to run from a PEER host, not the blox itself." >&2
    echo "       Localhost-to-localhost curl doesn't prove LAN firewall reachability." >&2
    echo "       Run this from your workstation/laptop instead." >&2
    exit 3
fi

echo "Probing blox-ai at ${URL} from $(hostname)..."
START_NS=$(date +%s%N)
BODY=$(curl --silent --show-error --max-time 5 --fail "$URL" 2>&1) || {
    echo "FAIL — curl exited non-zero:" >&2
    echo "$BODY" >&2
    cat <<'EOF' >&2

Possible causes:
  - Wrong blox IP (check mDNS or `ip route` on the blox)
  - Blox firewall blocking port (check /etc/fula/plugins/blox-ai/.env BLOX_AI_PORT;
    run firewall.sh again on the blox to reapply rules)
  - Container not running (ssh to blox: systemctl status blox-ai.service)
  - Wrong subnet (peer + blox must be on the same RFC1918 LAN — RFC1918
    is what firewall.sh allows; cellular tether / hotel split-LAN can break this)

EOF
    exit 1
}

END_NS=$(date +%s%N)
LATENCY_MS=$(( (END_NS - START_NS) / 1000000 ))

if printf '%s' "$BODY" | grep -q '"ok":[[:space:]]*true'; then
    echo "OK — /health 200, body=${BODY}, latency=${LATENCY_MS}ms"
    exit 0
else
    echo "FAIL — /health returned non-OK body: ${BODY}" >&2
    exit 1
fi
