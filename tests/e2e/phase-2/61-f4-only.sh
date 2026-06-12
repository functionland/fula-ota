#!/usr/bin/env bash
# Targeted F4 rerun (1 GiB via ingest) with a 12h token — F1-F3 already green.
set -uo pipefail
. /opt/fula-master/.env
JWT=$(python3 - "$JWT_SECRET" <<'PYEOF'
import sys, hmac, hashlib, base64, json, time
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
secret = sys.argv[1].encode()
h = b64u(json.dumps({"alg":"HS256","typ":"JWT"}).encode())
p = b64u(json.dumps({"sub":"e2e-drill@fxe2e.local","scope":"storage:*","iat":int(time.time()),"exp":int(time.time())+43200}).encode())
sig = b64u(hmac.new(secret, h+b"."+p, hashlib.sha256).digest())
print((h+b"."+p+b"."+sig).decode())
PYEOF
)
JWT_HASH=$(printf '%s' "$JWT" | sha256sum | cut -d' ' -f1)
docker exec -i postgres-pinning psql -U "${POSTGRES_USER:-pinning_user}" -d "${POSTGRES_DB:-pinning_service}" -tA -c \
  "INSERT INTO sessions (username, session_token, token_hash, expires_at) VALUES ('e2e-drill-user', '$JWT_HASH', '$JWT_HASH', NOW() + interval '12 hours') ON CONFLICT DO NOTHING" >/dev/null
curl -s -m 15 -o /dev/null -X PUT "http://127.0.0.1:9000/p2-live-big" -H "Authorization: Bearer $JWT"

cd /root/fula-api && git pull -q
docker run --rm --network host -v /root/fula-api:/src \
  -v fula-cargo-cache:/usr/local/cargo/registry -v fula-cargo-cache-target:/src/target \
  -w /src -e CARGO_TERM_COLOR=never \
  -e FULA_S3=http://127.0.0.1:9000 -e FULA_JWT="$JWT" \
  -e FULA_INGEST=http://127.0.0.1:3601 -e FULA_BIG=1 \
  rust:1-bookworm bash -c "cargo test -p fula-client --release --test live_ingest_e2e live_1gib_chunked_via_ingest -- --ignored --nocapture 2>&1 | tail -20"
rc=$?
[ $rc -eq 0 ] && echo "RESULT: pass=1 fail=0" || echo "RESULT: pass=0 fail=1"
