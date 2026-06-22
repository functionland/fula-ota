#!/usr/bin/env bash
# Dry-run tests for phase-1-setup-writer.sh (no docker/root/network: DRY_RUN=1 + master
# info supplied). Verifies validation, ip4/dns4 detection, secret, zero side effects,
# .env persistence, and re-run-reuses-saved-value. ENV_FILE points at temp files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../update-scripts/phase-1-setup-writer.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: not found $SCRIPT"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
M="12D3KooWMasterAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
BS="/dns4/1.pools.functionyard.fula.network/tcp/9096/p2p/$M"
fail=0; pass(){ echo "ok   - $1"; }; bad(){ echo "FAIL - $1"; fail=1; }

run() { DRY_RUN=1 ENV_FILE="$1" PUBLIC_HOST="$2" BASE_DIR="$3" MASTER_CLUSTER_PEERID="$M" MASTER_CLUSTER_BOOTSTRAP="$BS" bash "$SCRIPT" 2>&1; }

out="$(run "$TMP/a.env" 1.2.3.4 "$TMP/w")"; rc=$?
[ "$rc" = 0 ] && pass "dry-run exits 0" || bad "dry-run exits 0 (rc=$rc)"
echo "$out" | grep -q "/ip4" && pass "ipv4 announce" || bad "ipv4 announce"
echo "$out" | grep -q "no system changes" && pass "declares no changes" || bad "declares no changes"
echo "$out" | grep -q "secret=" && pass "derives secret" || bad "derives secret"
[ ! -d "$TMP/w" ] && pass "no base dir created in dry-run" || bad "no base dir created in dry-run"
[ -f "$TMP/a.env" ] && pass "saves params to .env" || bad "saves params to .env"

out2="$(run "$TMP/b.env" writer.example.com "$TMP/w2")"
echo "$out2" | grep -q "/dns4" && pass "dns4 announce" || bad "dns4 announce"

# re-run with NO PUBLIC_HOST supplied -> reuses the saved value from a.env
out3="$(DRY_RUN=1 ENV_FILE="$TMP/a.env" MASTER_CLUSTER_PEERID="$M" MASTER_CLUSTER_BOOTSTRAP="$BS" bash "$SCRIPT" 2>&1)"; rc3=$?
{ [ "$rc3" = 0 ] && echo "$out3" | grep -q "1.2.3.4"; } && pass "re-run reuses saved PUBLIC_HOST" || bad "re-run reuses saved PUBLIC_HOST"

# halts without PUBLIC_HOST (fresh env, nothing supplied)
if DRY_RUN=1 ENV_FILE="$TMP/halt.env" MASTER_CLUSTER_PEERID="$M" MASTER_CLUSTER_BOOTSTRAP="$BS" bash "$SCRIPT" >/dev/null 2>&1; then bad "halts without PUBLIC_HOST"; else pass "halts without PUBLIC_HOST"; fi

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
