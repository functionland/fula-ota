#!/usr/bin/env bash
# Test the Phase 1 federation parse logic used by ipfs-cluster-container-init.d.sh:
#   - prefer the ipfs-cluster-trustedpeers ARRAY (join as CSV), filtering empty/null
#   - fall back to the single ipfs-cluster-peerid when the array is absent
#   - PRIMARY = first element of the CSV (bootstrap/tunnel target)
#   - jq split(",") rebuilds the array and split(",")[0] = primary (mirrors the
#     service.json jq: trusted_peers = ($trust_peer|split(",")), peer_addresses uses [0])
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (runs on edge/CI where jq is present)"; exit 0; }

A="12D3KooWMASTERaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="12D3KooWWRITERbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
ARR_JQ='(."ipfs-cluster-trustedpeers" // []) | map(select(. != null and . != "")) | join(",")'
fail=0
pass() { echo "ok   - $1"; }
bad()  { echo "FAIL - $1: expected [$3] got [$2]"; fail=1; }
eq()   { [ "$2" = "$3" ] && pass "$1" || bad "$1" "$2" "$3"; }

# array present -> CSV
csv="$(echo "{\"ipfs-cluster-peerid\":\"$A\",\"ipfs-cluster-trustedpeers\":[\"$A\",\"$B\"]}" | jq -r "$ARR_JQ")"
eq "array -> csv" "$csv" "$A,$B"

# array absent -> fall back to single peerid
resp2="{\"ipfs-cluster-peerid\":\"$A\"}"
csv2="$(echo "$resp2" | jq -r "$ARR_JQ")"
resolved="$csv2"
if [ -z "$resolved" ] || [ "$resolved" = "null" ]; then resolved="$(echo "$resp2" | jq -r '."ipfs-cluster-peerid" // empty')"; fi
eq "fallback to single" "$resolved" "$A"

# array filters empty/null entries
csv3="$(echo "{\"ipfs-cluster-trustedpeers\":[\"$A\",\"\",null,\"$B\"]}" | jq -r "$ARR_JQ")"
eq "filter empty/null" "$csv3" "$A,$B"

# PRIMARY = first of CSV
eq "primary = first" "$(printf '%s' "$A,$B" | cut -d',' -f1)" "$A"

# service.json jq behaviour: split rebuilds array, [0] is primary
eq "split -> array" "$(printf '%s' "$A,$B" | jq -Rc 'split(",")')" "[\"$A\",\"$B\"]"
eq "split[0] = primary" "$(printf '%s' "$A,$B" | jq -rR 'split(",")[0]')" "$A"

# single value stays a 1-element array (backward-compat)
eq "single -> 1-elem array" "$(printf '%s' "$A" | jq -Rc 'split(",")')" "[\"$A\"]"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
