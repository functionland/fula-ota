#!/bin/bash
# Remove olostep plugin firewall isolation rules.
# Called during uninstallation.

CHAIN="OLOSTEP_FW"
BRIDGE="br-olostep"

echo "[olostep-fw] Removing network isolation rules..."

# Remove jump from INPUT
while iptables -D INPUT -j "$CHAIN" 2>/dev/null; do :; done

# Flush and delete the chain
iptables -F "$CHAIN" 2>/dev/null
iptables -X "$CHAIN" 2>/dev/null

# Remove DOCKER-USER rules
while iptables -D DOCKER-USER -i "$BRIDGE" -d 192.168.0.0/16 -j DROP 2>/dev/null; do :; done
while iptables -D DOCKER-USER -i "$BRIDGE" -d 10.0.0.0/8     -j DROP 2>/dev/null; do :; done
while iptables -D DOCKER-USER -i "$BRIDGE" -d 172.16.0.0/12   -j DROP 2>/dev/null; do :; done

echo "[olostep-fw] Network isolation rules removed"
