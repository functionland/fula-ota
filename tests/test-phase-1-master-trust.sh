#!/usr/bin/env bash
# Test update-scripts/phase-1-master-trust.sh against a fixture systemd unit
# (no systemctl/docker — uses NO_RESTART=1). Verifies additive append to BOTH the
# Environment= line and the ExecStart -e flag, idempotency, and halt-without-input.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../update-scripts/phase-1-master-trust.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
UNIT="$TMP/ipfscluster.service"
MASTER="12D3KooWS79EhkPU7ESUwgG4vyHHzW9FDNZLoWVth9b5N5NSrvaj"
NEW="12D3KooWNEWwriter00000000000000000000000000000000000001"

cat > "$UNIT" <<EOF
[Service]
Environment="CLUSTER_CRDT_TRUSTEDPEERS=$MASTER"
ExecStart=/usr/bin/docker run --rm --name ipfs_cluster -e CLUSTER_CRDT_TRUSTEDPEERS=$MASTER -e CLUSTER_PEERNAME=foo ipfs/ipfs-cluster:stable
EOF

fail=0
pass() { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; fail=1; }

# 1) apply
NEW_WRITER_PEERID="$NEW" NO_RESTART=1 UNIT_PATH="$UNIT" bash "$SCRIPT" >/dev/null
grep -q "Environment=\"CLUSTER_CRDT_TRUSTEDPEERS=$MASTER,$NEW\"" "$UNIT" && pass "Environment= line appended" || bad "Environment= line appended"
grep -q -- "-e CLUSTER_CRDT_TRUSTEDPEERS=$MASTER,$NEW " "$UNIT" && pass "ExecStart -e appended" || bad "ExecStart -e appended"
ls "$UNIT".bak.* >/dev/null 2>&1 && pass "backup created" || bad "backup created"

# 2) idempotent: second run is a no-op, value still exactly MASTER,NEW (2 occurrences)
NEW_WRITER_PEERID="$NEW" NO_RESTART=1 UNIT_PATH="$UNIT" bash "$SCRIPT" >/dev/null
occ="$(grep -c "CLUSTER_CRDT_TRUSTEDPEERS=$MASTER,$NEW" "$UNIT" || true)"
[ "$occ" = "2" ] && pass "idempotent (no double append)" || bad "idempotent (got $occ occurrences, want 2)"

# 3) halts when NEW_WRITER_PEERID is missing
if NO_RESTART=1 UNIT_PATH="$UNIT" bash "$SCRIPT" >/dev/null 2>&1; then bad "halts without NEW_WRITER_PEERID"; else pass "halts without NEW_WRITER_PEERID"; fi

# 4) rejects a non-peer-id value
if NEW_WRITER_PEERID="not-a-peer" NO_RESTART=1 UNIT_PATH="$UNIT" bash "$SCRIPT" >/dev/null 2>&1; then bad "rejects bad peer id"; else pass "rejects bad peer id"; fi

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
