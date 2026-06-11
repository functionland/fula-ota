#!/usr/bin/env bash
#
# Phase 1 — provision/maintain a 2nd ipfs-cluster WRITER on a plain Ubuntu/Debian cloud box.
#
# Idempotent + re-runnable: detects what is already installed and skips/reuses it
# (Docker, kubo repo, cluster identity), rewrites a systemd unit (and restarts) ONLY when
# it actually changed, and remembers your inputs in $ENV_FILE — so a re-run just updates
# what is needed. Run interactively and it asks for the parameters (pressing Enter keeps
# the saved value); run non-interactively (CI/cron) and it uses env/.env or halts.
#
# Run on the NEW box (as root). Re-running is safe. See lib/phase-common.sh for prompt/env behaviour.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/phase-common.sh
. "$SCRIPT_DIR/lib/phase-common.sh"
PC_TAG="phase-1-setup-writer"

ENV_FILE="${ENV_FILE:-/opt/fula-writer/.env}"
pc_load_env "$ENV_FILE"

: "${CLUSTERNAME:=1}"
: "${BASE_DIR:=/opt/fula-writer}"
: "${KUBO_IMAGE:=ipfs/kubo:release}"
: "${CLUSTER_IMAGE:=ipfs/ipfs-cluster:stable}"
: "${REPL_MIN:=2}"; : "${REPL_MAX:=6}"
: "${POOL_API:=}"
: "${MASTER_CLUSTER_PEERID:=}"; : "${MASTER_CLUSTER_BOOTSTRAP:=}"; : "${MASTER_KUBO_PEERID:=}"
DRY_RUN="${DRY_RUN:-0}"

ensure_pkg() {
  pc_have "$1" && { info "$1 present — skip"; return 0; }
  [ "$DRY_RUN" = 1 ] && { info "(dry-run) would install $1"; return 0; }
  pc_have apt-get || die "$1 missing and apt-get not found (Debian/Ubuntu only) — install $1 manually."
  info "installing $1 ..."; apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y "$1" >/dev/null 2>&1 || die "failed to install $1"
}

# ---- gather params (interactive prompts with saved defaults; else env/.env or halt) ----
pc_prompt PUBLIC_HOST "Public IP or DNS of THIS writer box"
pc_prompt CLUSTERNAME "Cluster/pool name" '^[0-9A-Za-z._-]+$'
[ -n "$POOL_API" ] || POOL_API="https://pools.fx.land/pools/${CLUSTERNAME}"

if [ "$DRY_RUN" != 1 ]; then [ "$(id -u)" = 0 ] || die "run as root (installs packages + writes systemd units)."; fi

ensure_pkg curl
ensure_pkg jq
if pc_have docker; then info "docker present — skip"
elif [ "$DRY_RUN" = 1 ]; then info "(dry-run) would install Docker"
else info "installing Docker ..."; curl -fsSL https://get.docker.com | sh || die "Docker install failed"; systemctl enable --now docker || die "could not start docker"; fi

SECRET="$(printf '%s' "$CLUSTERNAME" | sha256sum | cut -d' ' -f1)"

# resolve master identity from the pool endpoint unless already provided/saved
if [ -z "$MASTER_CLUSTER_PEERID" ] || [ -z "$MASTER_CLUSTER_BOOTSTRAP" ]; then
  if [ "$DRY_RUN" = 1 ] && ! pc_have curl; then info "(dry-run) would read $POOL_API"
  else
    info "reading master identity from $POOL_API ..."
    resp="$(curl -s --max-time 20 "$POOL_API" 2>/dev/null || true)"
    if printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
      [ -n "$MASTER_CLUSTER_PEERID" ]   || MASTER_CLUSTER_PEERID="$(printf '%s' "$resp" | jq -r '."ipfs-cluster-peerid" // empty')"
      [ -n "$MASTER_KUBO_PEERID" ]      || MASTER_KUBO_PEERID="$(printf '%s' "$resp" | jq -r '."kubo-peerid" // empty')"
      [ -n "$MASTER_CLUSTER_BOOTSTRAP" ] || MASTER_CLUSTER_BOOTSTRAP="$(printf '%s' "$resp" | jq -r '(.ipfs_cluster.addresses // [])[] | select(test("/tcp/"))' | head -1)"
      [ -n "$MASTER_CLUSTER_BOOTSTRAP" ] || MASTER_CLUSTER_BOOTSTRAP="$(printf '%s' "$resp" | jq -r '(.ipfs_cluster.addresses // [])[0] // empty')"
    fi
  fi
fi
pc_prompt MASTER_CLUSTER_PEERID "Master cluster peer id" '^(12D3KooW|Qm)'
pc_prompt MASTER_CLUSTER_BOOTSTRAP "Master cluster bootstrap multiaddr" '^/'

if [[ "$PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then PROTO=ip4; else PROTO=dns4; fi

pc_save_env "$ENV_FILE" PUBLIC_HOST CLUSTERNAME POOL_API BASE_DIR KUBO_IMAGE CLUSTER_IMAGE REPL_MIN REPL_MAX MASTER_CLUSTER_PEERID MASTER_CLUSTER_BOOTSTRAP MASTER_KUBO_PEERID

cat <<EOF
[phase-1-setup-writer] plan:
  PUBLIC_HOST=$PUBLIC_HOST (announce /$PROTO)   CLUSTERNAME=$CLUSTERNAME   secret=${SECRET:0:12}...
  master peer=$MASTER_CLUSTER_PEERID
  master bootstrap=$MASTER_CLUSTER_BOOTSTRAP
  base=$BASE_DIR   repl=$REPL_MIN..$REPL_MAX   FOLLOWERMODE=false (writer)   env=$ENV_FILE
EOF
[ "$DRY_RUN" = 1 ] && { info "DRY_RUN=1 — params saved; no system changes made."; exit 0; }

KUBO_DIR="$BASE_DIR/kubo"; CLUSTER_DIR="$BASE_DIR/ipfs-cluster"
mkdir -p "$KUBO_DIR" "$CLUSTER_DIR"

# ---- kubo (idempotent init + config) ----
# --entrypoint ipfs: the official kubo image's entrypoint auto-inits an empty repo before
# running the CMD, so a plain `docker run ... init` double-inits and fails ("configuration
# file already exists"). Bypassing the entrypoint makes init/config single, explicit ops.
kubo_oneshot() { docker run --rm --entrypoint ipfs -e IPFS_PATH=/data/ipfs -v "$KUBO_DIR":/data/ipfs "$KUBO_IMAGE" "$@"; }
# kubo_cfg: on RE-RUNS the ipfs_host daemon holds the repo lock, so a one-shot `ipfs config`
# would fail. Route through the running daemon (RPC, no lock) when up, one-shot otherwise.
# Note: config set via a running daemon takes effect on its next restart (restart
# ipfs.service manually if you changed PUBLIC_HOST on a re-run).
kubo_cfg() { if [ -n "$(docker ps -q -f name='^ipfs_host$')" ]; then docker exec ipfs_host ipfs "$@"; else kubo_oneshot "$@"; fi; }
if [ -f "$KUBO_DIR/config" ]; then info "kubo repo exists — skip init"; else info "init kubo repo (server profile)"; kubo_oneshot init --profile=server >/dev/null; fi
kubo_cfg config --json Addresses.Announce "[\"/$PROTO/$PUBLIC_HOST/tcp/4001\",\"/$PROTO/$PUBLIC_HOST/udp/4001/quic-v1\"]" >/dev/null
kubo_cfg config Routing.Type dhtserver >/dev/null
kubo_cfg config --json Routing.AcceleratedDHTClient true >/dev/null
# read identity from the repo file directly — lock-free, daemon-state-independent
NEW_KUBO_PEERID="$(jq -r '.Identity.PeerID // empty' "$KUBO_DIR/config")"; [ -n "$NEW_KUBO_PEERID" ] || die "could not read new kubo peer id."

kubo_ch="$(cat <<EOF | pc_write_if_changed /etc/systemd/system/ipfs.service
[Unit]
Description=IPFS (fula writer)
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
Environment=IPFS_PROFILE=server
Environment=IPFS_PATH=/data/ipfs
ExecStartPre=-/usr/bin/docker rm -f ipfs_host
ExecStart=/usr/bin/docker run -u root --rm --name ipfs_host --network host -e IPFS_PROFILE=server -e IPFS_PATH=/data/ipfs -v $KUBO_DIR:/data/ipfs $KUBO_IMAGE
ExecStop=/usr/bin/docker stop -t 30 ipfs_host
Restart=always
RestartSec=10s
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
)"
systemctl daemon-reload; systemctl enable --now ipfs.service
[ "$kubo_ch" = changed ] && { info "ipfs.service changed — restarting"; systemctl restart ipfs.service; } || info "ipfs.service unchanged"
for i in $(seq 1 30); do curl -s -X POST http://127.0.0.1:5001/api/v0/id >/dev/null 2>&1 && break; [ "$i" = 30 ] && die "kubo not healthy on :5001"; sleep 3; done
info "kubo healthy ($NEW_KUBO_PEERID)"

# ---- ipfs-cluster (idempotent init + join) ----
cl_oneshot() { docker run --rm -e IPFS_CLUSTER_PATH=/data/ipfs-cluster -e CLUSTER_SECRET="$SECRET" -v "$CLUSTER_DIR":/data/ipfs-cluster --entrypoint ipfs-cluster-service "$CLUSTER_IMAGE" "$@"; }
if [ -f "$CLUSTER_DIR/identity.json" ]; then info "cluster identity exists — skip init"; else info "init ipfs-cluster"; cl_oneshot init >/dev/null 2>&1 || cl_oneshot init >/dev/null; fi
NEW_CLUSTER_PEERID="$(jq -r '.id' "$CLUSTER_DIR/identity.json")"; { [ -n "$NEW_CLUSTER_PEERID" ] && [ "$NEW_CLUSTER_PEERID" != null ]; } || die "could not read new cluster peer id."
printf '%s\n' "$MASTER_CLUSTER_BOOTSTRAP" > "$CLUSTER_DIR/peerstore"
TRUSTED="$MASTER_CLUSTER_PEERID,$NEW_CLUSTER_PEERID"

cl_ch="$(cat <<EOF | pc_write_if_changed /etc/systemd/system/ipfscluster.service
[Unit]
Description=IPFSCLUSTER (fula writer)
After=ipfs.service
Requires=ipfs.service

[Service]
Type=simple
User=root
Environment=IPFS_CLUSTER_PATH=/data/ipfs-cluster
ExecStartPre=-/usr/bin/docker rm -f ipfs_cluster
ExecStart=/usr/bin/docker run -u root --rm --name ipfs_cluster --network host -e IPFS_CLUSTER_PATH=/data/ipfs-cluster -e CLUSTER_ALLOCATOR_ALLOCATEBY="tag:group,pinqueue,reposize" -e CLUSTER_REPLICATIONFACTORMIN=$REPL_MIN -e CLUSTER_REPLICATIONFACTORMAX=$REPL_MAX -e CLUSTER_DISABLEREPINNING=false -e CLUSTER_CLUSTERNAME=$CLUSTERNAME -e CLUSTER_SECRET=$SECRET -e CLUSTER_FOLLOWERMODE=false -e CLUSTER_CRDT_TRUSTEDPEERS=$TRUSTED -e CLUSTER_PEERNAME=$NEW_KUBO_PEERID -e CLUSTER_MONITORPINGINTERVAL=12h -v $CLUSTER_DIR:/data/ipfs-cluster $CLUSTER_IMAGE daemon --upgrade --bootstrap $MASTER_CLUSTER_BOOTSTRAP
ExecStop=/usr/bin/docker stop -t 30 ipfs_cluster
Restart=always
RestartSec=10s
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
)"
systemctl daemon-reload; systemctl enable --now ipfscluster.service
[ "$cl_ch" = changed ] && { info "ipfscluster.service changed — restarting"; systemctl restart ipfscluster.service; } || info "ipfscluster.service unchanged"
sleep 8
docker exec ipfs_cluster ipfs-cluster-ctl id >/dev/null 2>&1 && info "cluster API up" || info "NOTE: cluster API not up yet — check: docker logs ipfs_cluster"

pc_save_env "$ENV_FILE" PUBLIC_HOST CLUSTERNAME POOL_API BASE_DIR KUBO_IMAGE CLUSTER_IMAGE REPL_MIN REPL_MAX MASTER_CLUSTER_PEERID MASTER_CLUSTER_BOOTSTRAP MASTER_KUBO_PEERID NEW_CLUSTER_PEERID NEW_KUBO_PEERID

cat <<EOF
[phase-1-setup-writer] DONE.
  NEW cluster peer id : $NEW_CLUSTER_PEERID
  NEW kubo peer id    : $NEW_KUBO_PEERID
Verify it joined:  docker exec ipfs_cluster ipfs-cluster-ctl peers ls
Next (trust it network-wide):
  1) on the MASTER:   NEW_WRITER_PEERID=$NEW_CLUSTER_PEERID ./phase-1-master-trust.sh
  2) on the pool-server (join-server): add $NEW_CLUSTER_PEERID to IPFS_CLUSTER_TRUSTED_PEERS and restart.
EOF
