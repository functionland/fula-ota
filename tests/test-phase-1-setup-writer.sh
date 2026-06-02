#!/usr/bin/env bash
# Dry-run tests for update-scripts/phase-1-setup-writer.sh — no docker/root/network
# (DRY_RUN=1 + master info supplied so it never curls). Verifies input validation,
# announce-protocol detection (ip4 vs dns4), secret derivation, and zero side effects.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../update-scripts/phase-1-setup-writer.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: not found $SCRIPT"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
M="12D3KooWMasterAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
BS="/dns4/1.pools.functionyard.fula.network/tcp/9096/p2p/$M"
fail=0; pass(){ echo "ok   - $1"; }; bad(){ echo "FAIL - $1"; fail=1; }

# 1) dry-run, IPv4 host -> exit 0, ip4 announce, no side effects
out="$(DRY_RUN=1 PUBLIC_HOST=1.2.3.4 MASTER_CLUSTER_PEERID="$M" MASTER_CLUSTER_BOOTSTRAP="$BS" BASE_DIR="$TMP/w" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "dry-run exits 0" || bad "dry-run exits 0 (rc=$rc)"
printf '%s' "$out" | grep -q "/ip4/1.2.3.4" && pass "ipv4 announce" || bad "ipv4 announce"
printf '%s' "$out" | grep -q "no changes made" && pass "declares no changes" || bad "declares no changes"
printf '%s' "$out" | grep -q "sha256" && pass "derives secret" || bad "derives secret"
[ ! -d "$TMP/w" ] && pass "no dirs created in dry-run" || bad "no dirs created in dry-run"

# 2) dry-run, DNS host -> dns4 announce
out2="$(DRY_RUN=1 PUBLIC_HOST=writer.example.com MASTER_CLUSTER_PEERID="$M" MASTER_CLUSTER_BOOTSTRAP="$BS" BASE_DIR="$TMP/w2" bash "$SCRIPT" 2>&1)"
printf '%s' "$out2" | grep -q "/dns4/writer.example.com" && pass "dns4 announce" || bad "dns4 announce"

# 3) halts without PUBLIC_HOST
if DRY_RUN=1 MASTER_CLUSTER_PEERID="$M" MASTER_CLUSTER_BOOTSTRAP="$BS" bash "$SCRIPT" >/dev/null 2>&1; then bad "halts without PUBLIC_HOST"; else pass "halts without PUBLIC_HOST"; fi

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
