#!/usr/bin/env bash
# Tests phase-1-master-trust.sh against a fixture systemd unit (NO_RESTART=1, no docker).
# Verifies additive append to both lines, backup, idempotency, halt/validation, and
# re-run-reuses-saved-peer-id. ENV_FILE points at temp files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../update-scripts/phase-1-master-trust.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: not found $SCRIPT"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
UNIT="$TMP/ipfscluster.service"
MASTER="12D3KooWS79EhkPU7ESUwgG4vyHHzW9FDNZLoWVth9b5N5NSrvaj"
NEW="12D3KooWNEWwriter00000000000000000000000000000000000001"
fresh_unit() { cat > "$UNIT" <<EOF
[Service]
Environment="CLUSTER_CRDT_TRUSTEDPEERS=$MASTER"
ExecStart=/usr/bin/docker run --rm --name ipfs_cluster -e CLUSTER_CRDT_TRUSTEDPEERS=$MASTER -e CLUSTER_PEERNAME=foo ipfs/ipfs-cluster:stable
EOF
}
fail=0; pass(){ echo "ok   - $1"; }; bad(){ echo "FAIL - $1"; fail=1; }

fresh_unit
NEW_WRITER_PEERID="$NEW" NO_RESTART=1 UNIT_PATH="$UNIT" ENV_FILE="$TMP/a.env" bash "$SCRIPT" >/dev/null
grep -q "Environment=\"CLUSTER_CRDT_TRUSTEDPEERS=$MASTER,$NEW\"" "$UNIT" && pass "Environment= appended" || bad "Environment= appended"
grep -q -- "-e CLUSTER_CRDT_TRUSTEDPEERS=$MASTER,$NEW " "$UNIT" && pass "ExecStart -e appended" || bad "ExecStart -e appended"
ls "$UNIT".bak.* >/dev/null 2>&1 && pass "backup created" || bad "backup created"

NEW_WRITER_PEERID="$NEW" NO_RESTART=1 UNIT_PATH="$UNIT" ENV_FILE="$TMP/a.env" bash "$SCRIPT" >/dev/null
occ="$(grep -c "CLUSTER_CRDT_TRUSTEDPEERS=$MASTER,$NEW" "$UNIT" || true)"
[ "$occ" = 2 ] && pass "idempotent (no double append)" || bad "idempotent (got $occ, want 2)"

if NO_RESTART=1 UNIT_PATH="$UNIT" ENV_FILE="$TMP/halt.env" bash "$SCRIPT" >/dev/null 2>&1; then bad "halts without peer id"; else pass "halts without peer id"; fi
if NEW_WRITER_PEERID="not-a-peer" NO_RESTART=1 UNIT_PATH="$UNIT" ENV_FILE="$TMP/bad.env" bash "$SCRIPT" >/dev/null 2>&1; then bad "rejects bad peer id"; else pass "rejects bad peer id"; fi

# re-run with NO peer id supplied -> reuses the saved one from .env (else it would halt)
fresh_unit
NEW_WRITER_PEERID="$NEW" NO_RESTART=1 UNIT_PATH="$UNIT" ENV_FILE="$TMP/s.env" bash "$SCRIPT" >/dev/null
if NO_RESTART=1 UNIT_PATH="$UNIT" ENV_FILE="$TMP/s.env" bash "$SCRIPT" >/dev/null 2>&1 && grep -q "CLUSTER_CRDT_TRUSTEDPEERS=$MASTER,$NEW" "$UNIT"; then pass "re-run reuses saved peer id"; else bad "re-run reuses saved peer id"; fi

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
