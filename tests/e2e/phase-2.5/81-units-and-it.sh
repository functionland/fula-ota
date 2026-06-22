#!/usr/bin/env bash
# Phase 2.5 combined gate on the latest commit: FM-1 unit (root_pointer) +
# FM-4 unit (auth_eip712) + FM-1 PG integration (real bucket_roots).
set -uo pipefail
. /opt/fula-master/.env

docker exec -i postgres-pinning psql -U "${POSTGRES_USER:-pinning_user}" -d "${POSTGRES_DB:-pinning_service}" \
  -c "CREATE TABLE IF NOT EXISTS bucket_roots (owner_id TEXT NOT NULL, bucket TEXT NOT NULL, root_cid TEXT NOT NULL, version BIGINT NOT NULL DEFAULT 1, updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (owner_id, bucket));" >/dev/null && echo "bucket_roots ready"

cd /root/fula-api
git fetch origin phase-2.5-multimaster -q && git checkout -q phase-2.5-multimaster && git pull -q
git log --oneline -1

docker run --rm --network host -v /root/fula-api:/src \
  -v fula-cargo-cache:/usr/local/cargo/registry -v fula-cargo-cache-target:/src/target \
  -w /src -e CARGO_TERM_COLOR=never \
  -e POSTGRES_HOST=127.0.0.1 -e POSTGRES_PORT=5432 \
  -e POSTGRES_DB="${POSTGRES_DB:-pinning_service}" -e POSTGRES_USER="${POSTGRES_USER:-pinning_user}" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  rust:1-bookworm bash -c '
    set -o pipefail
    echo "===== FM-1 unit (root_pointer) ====="
    cargo test -p fula-core root_pointer 2>&1 | tail -10
    echo "===== FM-4 unit (auth_eip712) ====="
    cargo test -p fula-cli auth_eip712 2>&1 | tail -12
    echo "===== FM-1 integration (PgRootStore vs real Postgres) ====="
    cargo test -p fula-cli --test root_store_pg_it -- --ignored --nocapture 2>&1 | tail -14
  '
echo "P25-ALL-RC=$?"
