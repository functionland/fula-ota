#!/bin/bash
# WireGuard support tunnel — JSON status output
# Extended in Phase 4 to expose handshake age + transfer counters so the
# readiness-check daemon can detect silent UDP blackholes that systemd's
# `is-active` doesn't see (Type=oneshot + RemainAfterExit=yes lies after
# the protocol drops).

STATE_FILE="/home/pi/.internal/wireguard/registration.state"

installed=false
registered=false
active=false
endpoint=""
assigned_ip=""
peer_id_registered=""
last_handshake_age_sec="null"
rx_bytes="null"
tx_bytes="null"
persistent_keepalive_sec="null"

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

# Phase 4 additions: handshake age, transfer counters, keepalive.
# Defensive multi-peer parsing even though the support tunnel is single-peer
# today (per advisor recommendation) — sum transfer across peers, use newest
# non-zero handshake epoch, smallest non-off keepalive. Clamp negative age
# (clock-skew defense). Anything that fails leaves the field as "null".
if [ "$active" = "true" ]; then
  # Newest non-zero handshake epoch across all peers
  newest_epoch=$(wg show support latest-handshakes 2>/dev/null \
    | awk '$2>max{max=$2} END{if(max+0>0) print max+0}')
  if [ -n "$newest_epoch" ]; then
    now=$(date +%s)
    age=$((now - newest_epoch))
    # NOTE: do NOT clamp negative age here. Python's check_wireguard_handshake_age()
    # detects (age < 0) as clock skew and uses it to suppress bounce remediation
    # (NTP fix may be in flight). Clamping here would make that defense dead code.
    # Per Codex post-implementation review.
    last_handshake_age_sec=$age
  fi

  # Sum transfer counters across all peers (defensive — single-peer today)
  transfer_line=$(wg show support transfer 2>/dev/null \
    | awk '{rx+=$2; tx+=$3} END{if(NR>0) printf "%d %d", rx, tx}')
  if [ -n "$transfer_line" ]; then
    rx_bytes=$(echo "$transfer_line" | awk '{print $1}')
    tx_bytes=$(echo "$transfer_line" | awk '{print $2}')
  fi

  # Smallest non-off keepalive (single-peer today; "off" is the only non-numeric
  # value wg emits — skip it then min across the rest).
  ka=$(wg show support persistent-keepalive 2>/dev/null \
    | awk '$2!="off" && $2!="" && ($2+0<min+0 || min==""){min=$2+0} END{if(min!="") print min}')
  if [ -n "$ka" ]; then
    persistent_keepalive_sec="$ka"
  fi
fi

python3 -c "
import json
print(json.dumps({
    'installed': $installed,
    'registered': $registered,
    'active': $active,
    'endpoint': '$endpoint',
    'assigned_ip': '$assigned_ip',
    'peer_id_registered': '$peer_id_registered',
    'last_handshake_age_sec': $last_handshake_age_sec,
    'rx_bytes': $rx_bytes,
    'tx_bytes': $tx_bytes,
    'persistent_keepalive_sec': $persistent_keepalive_sec,
}, cls=None))
" 2>/dev/null || echo '{"installed":'$installed',"registered":'$registered',"active":'$active',"endpoint":"'$endpoint'","assigned_ip":"'$assigned_ip'","peer_id_registered":"'$peer_id_registered'","last_handshake_age_sec":'$last_handshake_age_sec',"rx_bytes":'$rx_bytes',"tx_bytes":'$tx_bytes',"persistent_keepalive_sec":'$persistent_keepalive_sec'}'
