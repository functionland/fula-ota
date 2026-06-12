#!/usr/bin/env bash
#
# Phase 2 e2e drills — verified byte ingress (TEST SERVER ONLY).
# Requires: Stage-A master stack up (join-as-master), fxe2e writer kubo on
# :5001, /root/fula-ota on phase-2-ingest, /root/fula-api on
# phase-2-client-ingest. Run as root from anywhere.
#
#   I1  build + run fula-ingest (strict quota, auth ON)
#   I2  health
#   I3  valid block accepted + stored in kubo
#   I4  tampered body -> 422 AND not stored
#   I5  suspended user -> 402 AND not stored (S1, strict)
#   I6  missing token -> 401
#   I7  gateway container STOPPED -> ingest still ingests bytes
#   I8  rebuild gateway from phase-2 branch; /fula/capabilities flips false->true
#   I9  live remote-cid mapping PUT: empty body + header -> 200, ETag=cid,
#       GET returns the ingested bytes end-to-end
#   I10 mapping PUT for an ABSENT cid -> 409 (client-fallback contract)
#
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }
. /opt/fula-master/.env
psqlc() { docker exec -i postgres-pinning psql -U "${POSTGRES_USER:-pinning_user}" -d "${POSTGRES_DB:-pinning_service}" -tA -c "$1"; }

U="e2e-drill-user"; EMAIL="e2e-drill@fxe2e.local"; APIKEY="fxe2e-ingest-drill-key-001"
ING=http://127.0.0.1:3601

# blake3 raw-leaf CID of a file, computed by kubo itself (no store).
cid_of() { docker exec -i ipfs_host ipfs add --only-hash --raw-leaves --hash=blake3 -q < "$1"; }

echo "== I1 build + run fula-ingest =="
cd /root/fula-ota && git fetch origin phase-2-ingest -q && git checkout -q phase-2-ingest && git pull -q
docker build -q -f docker/fula-ingest/Dockerfile -t functionland/fula-ingest:e2e docker/fula-ingest >/dev/null \
  && ok "I1 image built" || { bad "I1 image build failed"; exit 1; }
docker stop fula-ingest-e2e >/dev/null 2>&1; docker rm fula-ingest-e2e >/dev/null 2>&1
docker run -d --name fula-ingest-e2e --network host \
  -e INGEST_BIND=127.0.0.1 -e INGEST_PORT=3601 \
  -e KUBO_API=http://127.0.0.1:5001 \
  -e STORAGE_API_URL=http://127.0.0.1:3001 \
  -e INGEST_QUOTA_MODE=strict \
  functionland/fula-ingest:e2e >/dev/null
sleep 3

echo "== seed drill identity (webui_users + legacy api_key + healthy credits) =="
# api_keys.user_id has an FK to webui_users.user_id — seed both columns.
psqlc "INSERT INTO webui_users (email, user_id) VALUES ('$EMAIL', '$U') ON CONFLICT DO NOTHING" >/dev/null 2>&1 || true
psqlc "INSERT INTO api_keys (key_id, user_email, user_id) VALUES ('$APIKEY', '$EMAIL', '$U') ON CONFLICT (key_id) DO UPDATE SET is_deleted=0, user_id='$U'" >/dev/null \
  && ok "seeded api key" || bad "could not seed api key"
psqlc "UPDATE user_credits SET is_suspended=0, balance_fula=50 WHERE user_id='$U'" >/dev/null

echo "== I2 health =="
curl -s -m 5 "$ING/health" | grep -q '"kubo":true' && ok "I2 ingest healthy (kubo reachable)" || bad "I2 health failed"

echo "== I3 valid block accepted + stored =="
F1=/tmp/p2-valid.bin; head -c 2048 /dev/urandom > "$F1"
C1="$(cid_of "$F1")"
code=$(curl -s -m 15 -o /tmp/p2-r1.json -w "%{http_code}" -X PUT "$ING/v0/block?cid=$C1" -H "Authorization: Bearer $APIKEY" --data-binary @"$F1")
[ "$code" = 200 ] && ok "I3 valid block -> 200" || bad "I3 got $code: $(cat /tmp/p2-r1.json)"
docker exec ipfs_host ipfs block stat "$C1" >/dev/null 2>&1 && ok "I3 block present in kubo" || bad "I3 block missing from kubo"

echo "== I4 tampered body -> 422, not stored =="
F2=/tmp/p2-orig.bin; head -c 2048 /dev/urandom > "$F2"
C2="$(cid_of "$F2")"
F2T=/tmp/p2-tampered.bin; cp "$F2" "$F2T"; printf 'X' | dd of="$F2T" bs=1 seek=10 count=1 conv=notrunc 2>/dev/null
C2T="$(cid_of "$F2T")"   # true cid of the tampered bytes — must NOT appear in kubo
code=$(curl -s -m 15 -o /tmp/p2-r2.json -w "%{http_code}" -X PUT "$ING/v0/block?cid=$C2" -H "Authorization: Bearer $APIKEY" --data-binary @"$F2T")
[ "$code" = 422 ] && ok "I4 tampered -> 422" || bad "I4 got $code: $(cat /tmp/p2-r2.json)"
docker exec ipfs_host ipfs block stat --offline "$C2T" >/dev/null 2>&1 && bad "I4 tampered bytes WERE stored" || ok "I4 tampered bytes not stored"

echo "== I5 suspended user -> 402, not stored (strict S1) =="
psqlc "UPDATE user_credits SET is_suspended=1 WHERE user_id='$U'" >/dev/null
sleep 31   # outlive the ingest quota cache TTL (30s)
F3=/tmp/p2-quota.bin; head -c 2048 /dev/urandom > "$F3"
C3="$(cid_of "$F3")"
code=$(curl -s -m 15 -o /tmp/p2-r3.json -w "%{http_code}" -X PUT "$ING/v0/block?cid=$C3" -H "Authorization: Bearer $APIKEY" --data-binary @"$F3")
[ "$code" = 402 ] && ok "I5 suspended -> 402" || bad "I5 got $code: $(cat /tmp/p2-r3.json)"
docker exec ipfs_host ipfs block stat --offline "$C3" >/dev/null 2>&1 && bad "I5 quota-denied bytes WERE stored" || ok "I5 quota-denied bytes not stored"
psqlc "UPDATE user_credits SET is_suspended=0 WHERE user_id='$U'" >/dev/null

echo "== I6 missing token -> 401 =="
code=$(curl -s -m 5 -o /tmp/p2-r4.json -w "%{http_code}" -X PUT "$ING/v0/block?cid=$C3" --data-binary @"$F3")
[ "$code" = 401 ] && ok "I6 no token -> 401" || bad "I6 got $code"

echo "== I7 gateway DOWN -> ingest still ingests =="
docker stop fula-gateway-1 >/dev/null 2>&1
sleep 31   # fresh quota window so the check runs while gateway is down (webui still up — quota is webui's)
F4=/tmp/p2-gwdown.bin; head -c 2048 /dev/urandom > "$F4"
C4="$(cid_of "$F4")"
code=$(curl -s -m 15 -o /tmp/p2-r5.json -w "%{http_code}" -X PUT "$ING/v0/block?cid=$C4" -H "Authorization: Bearer $APIKEY" --data-binary @"$F4")
[ "$code" = 200 ] && ok "I7 bytes ingested with the gateway STOPPED" || bad "I7 got $code: $(cat /tmp/p2-r5.json)"
docker start fula-gateway-1 >/dev/null 2>&1

echo "== I8 rebuild gateway from phase-2 branch; capabilities flips =="
code=$(curl -s -m 5 -o /tmp/p2-cap0.json -w "%{http_code}" http://127.0.0.1:9000/fula/capabilities)
grep -q '"remoteCidPut":true' /tmp/p2-cap0.json 2>/dev/null && bad "I8 pre-rebuild gateway already advertises (unexpected)" || ok "I8 old gateway does not advertise remoteCidPut (code=$code)"
cd /root/fula-api && git fetch origin phase-2-client-ingest -q && git checkout -q phase-2-client-ingest && git pull -q
docker build -q -f docker/Dockerfile.gateway -t fula-gateway:latest . >/dev/null && ok "I8 gateway image rebuilt from phase-2 branch" || { bad "I8 gateway rebuild failed"; exit 1; }
cat > /opt/fula-master/fula-gateway.env <<EOF
JWT_SECRET=$JWT_SECRET
STORAGE_API_URL=http://127.0.0.1:3001
CLUSTER_API_URL=http://127.0.0.1:9094
IPFS_API_URL=http://127.0.0.1:5001
FULA_HOST=127.0.0.1
FULA_PORT=9000
FULA_REMOTE_CID_PUT=true
EOF
cd /root/pinning-service
COMPOSE_PROFILES=gateway docker compose --env-file /opt/fula-master/.env -f docker/master/docker-compose.master.yml up -d fula-gateway >/dev/null 2>&1
for i in $(seq 1 20); do curl -s -m 3 http://127.0.0.1:9000/fula/capabilities | grep -q remoteCidPut && break; sleep 3; done
curl -s -m 5 http://127.0.0.1:9000/fula/capabilities | grep -q '"remoteCidPut":true' \
  && ok "I8 new gateway advertises remoteCidPut:true" || bad "I8 capabilities did not flip"

echo "== I9 live remote-cid mapping PUT (empty body) -> 200 + GET round-trip =="
JWT=$(python3 - "$JWT_SECRET" <<'PYEOF'
import sys, hmac, hashlib, base64, json, time
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
secret = sys.argv[1].encode()
h = b64u(json.dumps({"alg":"HS256","typ":"JWT"}).encode())
p = b64u(json.dumps({"sub":"e2e-drill@fxe2e.local","scope":"storage:*","iat":int(time.time()),"exp":int(time.time())+3600}).encode())
sig = b64u(hmac.new(secret, h+b"."+p, hashlib.sha256).digest())
print((h+b"."+p+b"."+sig).decode())
PYEOF
)
[ -n "$JWT" ] && ok "I9 minted gateway JWT" || bad "I9 JWT mint failed"
code=$(curl -s -m 20 -o /tmp/p2-map.txt -D /tmp/p2-map-h.txt -w "%{http_code}" -X PUT \
  "http://127.0.0.1:9000/p2-drill-bucket/chunk-0001" \
  -H "Authorization: Bearer $JWT" \
  -H "x-amz-meta-fula-remote-cid: $C1" \
  -H "x-amz-meta-fula-remote-size: 2048" \
  -H "Content-Length: 0")
[ "$code" = 200 ] && ok "I9 mapping PUT -> 200" || bad "I9 mapping PUT got $code: $(head -c200 /tmp/p2-map.txt)"
grep -qi "etag.*$C1" /tmp/p2-map-h.txt && ok "I9 ETag echoes the declared cid" || bad "I9 ETag mismatch: $(grep -i etag /tmp/p2-map-h.txt)"
body=$(curl -s -m 20 -H "Authorization: Bearer $JWT" "http://127.0.0.1:9000/p2-drill-bucket/chunk-0001" -o /tmp/p2-get.bin -w "%{http_code}")
if [ "$body" = 200 ] && cmp -s /tmp/p2-get.bin "$F1"; then ok "I9 GET returns the exact ingested bytes (end-to-end)"; else bad "I9 GET round-trip failed (code=$body)"; fi

echo "== I10 mapping PUT for ABSENT cid -> 409 =="
FA=/tmp/p2-absent.bin; head -c 1024 /dev/urandom > "$FA"
CA="$(cid_of "$FA")"   # never uploaded anywhere
code=$(curl -s -m 30 -o /tmp/p2-abs.txt -w "%{http_code}" -X PUT \
  "http://127.0.0.1:9000/p2-drill-bucket/chunk-absent" \
  -H "Authorization: Bearer $JWT" \
  -H "x-amz-meta-fula-remote-cid: $CA" \
  -H "x-amz-meta-fula-remote-size: 1024" \
  -H "Content-Length: 0")
case "$code" in 409|4*) ok "I10 absent cid rejected (code=$code — client falls back to full bytes)";; *) bad "I10 got $code: $(head -c200 /tmp/p2-abs.txt)";; esac

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ] || exit 1
