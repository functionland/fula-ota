#!/bin/bash
# Fula device firewall — iptables rules using a custom chain (FULA_FIREWALL)
# Idempotent: safe to run multiple times. Chain is flushed and recreated each run.
# Does NOT touch FORWARD or OUTPUT chains (Docker manages FORWARD).

FULA_LOG_PATH="/home/pi/fula.sh.log"
CHAIN="FULA_FIREWALL"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [firewall] $*" | tee -a "$FULA_LOG_PATH"
}

# Check iptables is available
if ! command -v iptables >/dev/null 2>&1; then
  log "ERROR: iptables not found, skipping firewall setup"
  exit 1
fi

log "Applying firewall rules..."

# --- IPv4 ---

# Remove old jump from INPUT (if exists)
while iptables -D INPUT -j "$CHAIN" 2>/dev/null; do :; done

# Flush and delete the chain (if exists)
iptables -F "$CHAIN" 2>/dev/null
iptables -X "$CHAIN" 2>/dev/null

# Create fresh chain
iptables -N "$CHAIN"

# 1. Accept established/related connections
iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 2. Accept loopback
iptables -A "$CHAIN" -i lo -j ACCEPT

# 3. Accept ICMP (rate-limited)
iptables -A "$CHAIN" -p icmp -m limit --limit 10/s --limit-burst 20 -j ACCEPT
iptables -A "$CHAIN" -p icmp -j DROP

# 4. Accept all traffic from Docker bridges (container-to-host)
#    docker0  = default bridge
#    br-+     = Docker Compose project bridges (e.g. br-c5a389b718ee)
iptables -A "$CHAIN" -i docker0 -j ACCEPT
iptables -A "$CHAIN" -i br-+ -j ACCEPT

# 5. Accept hotspot AP subnet (for WAP setup)
iptables -A "$CHAIN" -s 10.42.0.0/24 -j ACCEPT

# --- Ports open to ALL (P2P / cluster) ---

# 6. IPFS Swarm
iptables -A "$CHAIN" -p tcp --dport 4001 -j ACCEPT
iptables -A "$CHAIN" -p udp --dport 4001 -j ACCEPT

# 7. go-fula libp2p
iptables -A "$CHAIN" -p tcp --dport 40001 -j ACCEPT

# 8. IPFS cluster (REST API, proxy, swarm)
iptables -A "$CHAIN" -p tcp --dport 9094 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 9095 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 9096 -j ACCEPT

# 9. streamr-node plugin
iptables -A "$CHAIN" -p tcp --dport 32200 -j ACCEPT

# --- Ports open to LOCAL NETWORK only (RFC1918) ---

# 10. SSH
iptables -A "$CHAIN" -p tcp --dport 22 -s 192.168.0.0/16 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 22 -s 10.0.0.0/8 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 22 -s 172.16.0.0/12 -j ACCEPT

# 11. Samba
for port in 139 445; do
  iptables -A "$CHAIN" -p tcp --dport "$port" -s 192.168.0.0/16 -j ACCEPT
  iptables -A "$CHAIN" -p tcp --dport "$port" -s 10.0.0.0/8 -j ACCEPT
  iptables -A "$CHAIN" -p tcp --dport "$port" -s 172.16.0.0/12 -j ACCEPT
done

# 12. WAP setup server
iptables -A "$CHAIN" -p tcp --dport 3500 -s 192.168.0.0/16 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 3500 -s 10.0.0.0/8 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 3500 -s 172.16.0.0/12 -j ACCEPT

# 13. loyal-agent plugin
iptables -A "$CHAIN" -p tcp --dport 8083 -s 192.168.0.0/16 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 8083 -s 10.0.0.0/8 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 8083 -s 172.16.0.0/12 -j ACCEPT

# 14. Log dropped packets (rate-limited)
iptables -A "$CHAIN" -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "FULA_FW_DROP: " --log-level 4

# 15. Drop everything else
iptables -A "$CHAIN" -j DROP

# Insert jump at position 1 in INPUT
iptables -I INPUT 1 -j "$CHAIN"

# --- IPv6 basic lockdown ---
if command -v ip6tables >/dev/null 2>&1; then
  # Use a matching chain for IPv6
  while ip6tables -D INPUT -j "${CHAIN}_V6" 2>/dev/null; do :; done
  ip6tables -F "${CHAIN}_V6" 2>/dev/null
  ip6tables -X "${CHAIN}_V6" 2>/dev/null
  ip6tables -N "${CHAIN}_V6"

  ip6tables -A "${CHAIN}_V6" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A "${CHAIN}_V6" -i lo -j ACCEPT
  ip6tables -A "${CHAIN}_V6" -i docker0 -j ACCEPT
  ip6tables -A "${CHAIN}_V6" -i br-+ -j ACCEPT
  ip6tables -A "${CHAIN}_V6" -p ipv6-icmp -j ACCEPT
  ip6tables -A "${CHAIN}_V6" -j DROP

  ip6tables -I INPUT 1 -j "${CHAIN}_V6"
  log "IPv6 lockdown applied"
fi

log "Firewall rules applied successfully"
# Show summary
iptables -L "$CHAIN" -n --line-numbers 2>&1 | while IFS= read -r line; do
  log "  $line"
done
