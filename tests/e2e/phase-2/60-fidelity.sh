#!/usr/bin/env bash
#
# Phase 2 fidelity suite (TEST SERVER ONLY). Runs AFTER 40-ingest-drills.sh
# (gateway rebuilt with FULA_REMOTE_CID_PUT=true; fula-ingest-e2e running).
#
#   F1 live ingest round-trip (client CID ON, bytes via ingest) + server-side
#      proof: the ingest container's kubo-stored block count INCREASES
#   F2 v8-OFF legacy round-trip (client CID off matrix leg)
#   F3 FxFiles-faithful suite: offline_e2e single + chunked upload/download
#      (the byte-for-byte FxFiles flow, legacy path)
#   F4 ≥1 GiB chunked via ingest (FULA_BIG=1; scale invariant)
#
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }
. /opt/fula-master/.env

JWT=$(python3 - "$JWT_SECRET" <<'PYEOF'
import sys, hmac, hashlib, base64, json, time
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
secret = sys.argv[1].encode()
h = b64u(json.dumps({"alg":"HS256","typ":"JWT"}).encode())
p = b64u(json.dumps({"sub":"e2e-drill@fxe2e.local","scope":"storage:*","iat":int(time.time()),"exp":int(time.time())+7200}).encode())
sig = b64u(hmac.new(secret, h+b"."+p, hashlib.sha256).digest())
print((h+b"."+p+b"."+sig).decode())
PYEOF
)
[ -n "$JWT" ] && ok "minted 2h gateway JWT" || { bad "JWT mint failed"; exit 1; }

cd /root/fula-api && git pull -q

run_tests() { # $1=extra-env  $2=test-filter
  docker run --rm --network host -v /root/fula-api:/src \
    -v fula-cargo-cache:/usr/local/cargo/registry -v fula-cargo-cache-target:/src/target \
    -w /src -e CARGO_TERM_COLOR=never \
    -e FULA_S3=http://127.0.0.1:9000 -e FULA_JWT="$JWT" $1 \
    rust:1-bookworm bash -c "set -o pipefail; cargo test -p fula-client --release --test $2 -- --ignored --nocapture 2>&1 | tail -8"
}

echo "== F1 live ingest round-trip + server-side block-count proof =="
BLOCKS_BEFORE=$(docker exec ipfs_host ipfs repo stat 2>/dev/null | awk '/NumObjects/{print $2}')
if run_tests "-e FULA_INGEST=http://127.0.0.1:3601" "live_ingest_e2e live_chunked_via_ingest_round_trip"; then
  ok "F1 client round-trip via ingest"
else
  bad "F1 client round-trip failed"
fi
BLOCKS_AFTER=$(docker exec ipfs_host ipfs repo stat 2>/dev/null | awk '/NumObjects/{print $2}')
[ "${BLOCKS_AFTER:-0}" -gt "${BLOCKS_BEFORE:-0}" ] \
  && ok "F1 kubo block count grew ($BLOCKS_BEFORE -> $BLOCKS_AFTER)" \
  || bad "F1 no new blocks landed"

echo "== F2 v8-off legacy round-trip (CID-off matrix leg) =="
if run_tests "" "live_ingest_e2e live_chunked_v8_off_legacy_round_trip"; then
  ok "F2 legacy round-trip (v8 off)"
else
  bad "F2 legacy round-trip failed"
fi

echo "== F3 FxFiles-faithful offline_e2e (single + chunked) =="
if run_tests "" "offline_e2e offline_upload_download_single_object_e2e"; then
  ok "F3 FxFiles single-object flow"
else
  bad "F3 single-object flow failed"
fi
if run_tests "" "offline_e2e offline_upload_download_chunked_e2e"; then
  ok "F3 FxFiles chunked flow"
else
  bad "F3 chunked flow failed"
fi

echo "== F4 1 GiB chunked via ingest (scale invariant) =="
if run_tests "-e FULA_INGEST=http://127.0.0.1:3601 -e FULA_BIG=1" "live_ingest_e2e live_1gib_chunked_via_ingest"; then
  ok "F4 1 GiB via ingest round-trip"
else
  bad "F4 1 GiB failed"
fi

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ] || exit 1
