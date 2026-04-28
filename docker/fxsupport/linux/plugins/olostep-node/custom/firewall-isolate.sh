#!/bin/bash
# Olostep plugin network isolation — idempotent, safe to run multiple times.
#
# Uses a SEPARATE iptables chain (OLOSTEP_FW) so the main firewall.sh
# can flush/recreate FULA_FIREWALL without affecting these rules.
#
# Layer 1 (INPUT):  Blocks container→host traffic to private networks.
# Layer 2 (DOCKER-USER): Blocks container→LAN forwarded traffic.
#
# Only affects the named br-olostep bridge interface.
# All other Docker bridges and services are completely unaffected.

CHAIN="OLOSTEP_FW"
BRIDGE="br-olostep"

# Skip if the bridge doesn't exist yet (container not started)
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  echo "[olostep-fw] Bridge $BRIDGE not found, skipping firewall isolation"
  exit 0
fi

echo "[olostep-fw] Applying network isolation for $BRIDGE..."

# --- Layer 1: INPUT chain (container → host services) ---

# Remove old jump from INPUT (if exists)
while iptables -D INPUT -j "$CHAIN" 2>/dev/null; do :; done

# Flush and delete the chain (if exists)
iptables -F "$CHAIN" 2>/dev/null
iptables -X "$CHAIN" 2>/dev/null

# Create fresh chain
iptables -N "$CHAIN"

# Block traffic from olostep bridge to all private networks
iptables -A "$CHAIN" -i "$BRIDGE" -d 192.168.0.0/16 -j DROP
iptables -A "$CHAIN" -i "$BRIDGE" -d 10.0.0.0/8     -j DROP
iptables -A "$CHAIN" -i "$BRIDGE" -d 172.16.0.0/12   -j DROP

# Return for non-matching traffic (public IPs fall through to FULA_FIREWALL)
iptables -A "$CHAIN" -j RETURN

# Insert jump at position 1 in INPUT (before FULA_FIREWALL)
# This ensures our DROP rules are checked before the br-+ blanket ACCEPT
iptables -I INPUT 1 -j "$CHAIN"

# --- Layer 2: DOCKER-USER chain (container → LAN via forwarding) ---
# DOCKER-USER is Docker's recommended chain for custom FORWARD rules.
# Unlike FULA_FIREWALL, firewall.sh does NOT touch DOCKER-USER,
# so these rules survive firewall.sh re-runs.

# Idempotent: remove old rules before adding new ones
while iptables -D DOCKER-USER -i "$BRIDGE" -d 192.168.0.0/16 -j DROP 2>/dev/null; do :; done
while iptables -D DOCKER-USER -i "$BRIDGE" -d 10.0.0.0/8     -j DROP 2>/dev/null; do :; done
while iptables -D DOCKER-USER -i "$BRIDGE" -d 172.16.0.0/12   -j DROP 2>/dev/null; do :; done

iptables -I DOCKER-USER -i "$BRIDGE" -d 172.16.0.0/12   -j DROP
iptables -I DOCKER-USER -i "$BRIDGE" -d 10.0.0.0/8      -j DROP
iptables -I DOCKER-USER -i "$BRIDGE" -d 192.168.0.0/16   -j DROP

echo "[olostep-fw] Network isolation applied: $BRIDGE blocked from RFC1918"
