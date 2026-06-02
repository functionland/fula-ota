#!/usr/bin/env bash
#
# Phase 1 (cluster write-federation) — provision a 2nd trusted cluster WRITER on a
# FRESH, plain Ubuntu/Debian cloud box (no Fula /uniondrive layout, no kubo, no cluster).
#
# It installs kubo (ipfs_host) + ipfs-cluster (ipfs_cluster) as systemd units under
# self-contained paths (/opt/fula-writer), mirroring the master's cluster env exactly
# (same CLUSTER_SECRET=sha256(CLUSTERNAME), CLUSTERNAME, allocator, replication, and
# FOLLOWERMODE=false so it is a WRITER), joins the existing CRDT cluster by directly
# bootstrapping to the master (public->public, no relay tunnel needed), and prints the
# new writer's cluster + kubo peer ids.
#
# It does NOT touch the master. After it runs, on the MASTER:
#   NEW_WRITER_PEERID=<printed cluster id> ./phase-1-master-trust.sh
# and add that id to IPFS_CLUSTER_TRUSTED_PEERS on the pool-server (join-server) so
# followers trust it too (join-server#2).
#
# The new writer stores ~nothing: it mirrors the master's allocator (tag:group,...),
# which keeps non-storage writers from being allocated pins — so kubo runs with the
# default datastore (no need to mirror the master's custom flatfs+pebble 900GB spec).
#
# REQUIRED env (HALTS if missing — never guesses):
#   PUBLIC_HOST   this box's PUBLIC ip or dns (kubo announce + cluster reachability)
# Optional env:
#   CLUSTERNAME            (default "1")  -> CLUSTER_SECRET = sha256(CLUSTERNAME)
#   POOL_API               (default https://pools.fx.land/pools/<CLUSTERNAME>)
#   MASTER_CLUSTER_PEERID / MASTER_CLUSTER_BOOTSTRAP / MASTER_KUBO_PEERID
#                          (auto-read from POOL_API if unset)
#   REPL_MIN / REPL_MAX    (default 2 / 6)
#   BASE_DIR               (default /opt/fula-writer)
#   KUBO_IMAGE             (default ipfs/kubo:release)
#   CLUSTER_IMAGE          (default ipfs/ipfs-cluster:stable)
#   DRY_RUN=1              print the plan; change nothing
#
set -euo pipefail

CLUSTERNAME="${CLUSTERNAME:-1}"
POOL_API="${POOL_API:-https://pools.fx.land/pools/${CLUSTERNAME}}"
BASE_DIR="${BASE_DIR:-/opt/fula-writer}"
KUBO_IMAGE="${KUBO_IMAGE:-ipfs/kubo:release}"
CLUSTER_IMAGE="${CLUSTER_IMAGE:-ipfs/ipfs-cluster:stable}"
REPL_MIN="${REPL_MIN:-2}"
REPL_MAX="${REPL_MAX:-6}"
DRY_RUN="${DRY_RUN:-0}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
MASTER_CLUSTER_PEERID="${MASTER_CLUSTER_PEERID:-}"
MASTER_CLUSTER_BOOTSTRAP="${MASTER_CLUSTER_BOOTSTRAP:-}"
MASTER_KUBO_PEERID="${MASTER_KUBO_PEERID:-}"

KUBO_DIR="$BASE_DIR/kubo"
CLUSTER_DIR="$BASE_DIR/ipfs-cluster"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[phase-1-setup-writer] $*"; }

# ---- preconditions -------------------------------------------------------------
[ -n "$PUBLIC_HOST" ] || die "PUBLIC_HOST is required (this box's public IP or DNS). Refusing to guess."
if [ "$DRY_RUN" != "1" ]; then
  [ "$(id -u)" = "0" ] || die "Must run as root (installs packages, writes systemd units)."
fi

ensure_pkg() {
  command -v "$1" >/dev/null 2>&1 && return 0
  [ "$DRY_RUN" = "1" ] && { info "(dry-run) would install $1"; return 0; }
  command -v apt-get >/dev/null 2>&1 || die "$1 missing and apt-get not found — install $1 manually (this script targets Debian/Ubuntu)."
  info "Installing $1 ..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y "$1" >/dev/null 2>&1 || die "failed to install $1"
}
ensure_pkg curl
ensure_pkg jq
if ! command -v docker >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then info "(dry-run) would install Docker via get.docker.com"; else
    info "Installing Docker ..."
    curl -fsSL https://get.docker.com | sh || die "Docker install failed"
    systemctl enable --now docker || die "could not start docker"
  fi
fi

# ---- derive secret + resolve master info --------------------------------------
SECRET="$(printf '%s' "$CLUSTERNAME" | sha256sum | cut -d' ' -f1)"

resolve_master() {
  [ -n "$MASTER_CLUSTER_PEERID" ] && [ -n "$MASTER_CLUSTER_BOOTSTRAP" ] && return 0
  info "Reading master identity from $POOL_API ..."
  local resp; resp="$(curl -s --max-time 20 "$POOL_API" || true)"
  echo "$resp" | jq -e . >/dev/null 2>&1 || die "could not fetch/parse $POOL_API (set MASTER_CLUSTER_PEERID + MASTER_CLUSTER_BOOTSTRAP manually)."
  [ -n "$MASTER_CLUSTER_PEERID" ]   || MASTER_CLUSTER_PEERID="$(echo "$resp" | jq -r '."ipfs-cluster-peerid" // empty')"
  [ -n "$MASTER_KUBO_PEERID" ]      || MASTER_KUBO_PEERID="$(echo "$resp" | jq -r '."kubo-peerid" // empty')"
  [ -n "$MASTER_CLUSTER_BOOTSTRAP" ] || MASTER_CLUSTER_BOOTSTRAP="$(echo "$resp" | jq -r '(.ipfs_cluster.addresses // [])[] | select(test("/tcp/"))' | head -1)"
  [ -n "$MASTER_CLUSTER_BOOTSTRAP" ] || MASTER_CLUSTER_BOOTSTRAP="$(echo "$resp" | jq -r '(.ipfs_cluster.addresses // [])[0] // empty')"
}
resolve_master
[ -n "$MASTER_CLUSTER_PEERID" ]    || die "could not resolve MASTER_CLUSTER_PEERID."
[ -n "$MASTER_CLUSTER_BOOTSTRAP" ] || die "could not resolve MASTER_CLUSTER_BOOTSTRAP (master cluster multiaddr)."

# announce protocol: /ip4 for an IPv4 literal, else /dns4
if printf '%s' "$PUBLIC_HOST" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then PROTO=ip4; else PROTO=dns4; fi

cat <<EOF
[phase-1-setup-writer] plan:
  CLUSTERNAME           = $CLUSTERNAME   (CLUSTER_SECRET = sha256 -> ${SECRET:0:12}...)
  PUBLIC_HOST           = $PUBLIC_HOST   (announce as /$PROTO/$PUBLIC_HOST)
  master cluster peer   = $MASTER_CLUSTER_PEERID
  master bootstrap addr = $MASTER_CLUSTER_BOOTSTRAP
  master kubo peer      = ${MASTER_KUBO_PEERID:-<none>}
  base dir              = $BASE_DIR   (kubo: $KUBO_DIR, cluster: $CLUSTER_DIR)
  replication           = $REPL_MIN..$REPL_MAX ; FOLLOWERMODE=false (writer)
EOF
[ "$DRY_RUN" = "1" ] && { info "DRY_RUN=1 — no changes made."; exit 0; }

mkdir -p "$KUBO_DIR" "$CLUSTER_DIR"

# ---- kubo: init (default datastore, server profile) + announce -----------------
kubo_oneshot() { docker run --rm -e IPFS_PATH=/data/ipfs -v "$KUBO_DIR":/data/ipfs "$KUBO_IMAGE" "$@"; }
if [ ! -f "$KUBO_DIR/config" ]; then
  info "Initializing kubo repo (server profile) ..."
  kubo_oneshot init --profile=server >/dev/null
fi
kubo_oneshot config --json Addresses.Announce "[\"/$PROTO/$PUBLIC_HOST/tcp/4001\",\"/$PROTO/$PUBLIC_HOST/udp/4001/quic-v1\"]" >/dev/null
kubo_oneshot config Routing.Type dhtserver >/dev/null
kubo_oneshot config --json Routing.AcceleratedDHTClient true >/dev/null
NEW_KUBO_PEERID="$(kubo_oneshot config Identity.PeerID)"
[ -n "$NEW_KUBO_PEERID" ] || die "could not read new kubo peer id."

cat > /etc/systemd/system/ipfs.service <<EOF
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

info "Starting kubo ..."
systemctl daemon-reload
systemctl enable --now ipfs.service
for i in $(seq 1 30); do
  curl -s -X POST http://127.0.0.1:5001/api/v0/id >/dev/null 2>&1 && break
  [ "$i" = 30 ] && die "kubo did not become healthy on :5001"
  sleep 3
done
info "kubo healthy (peer $NEW_KUBO_PEERID)"

# ---- ipfs-cluster: init (read identity) + systemd unit + join -----------------
cl_oneshot() { docker run --rm -e IPFS_CLUSTER_PATH=/data/ipfs-cluster -e CLUSTER_SECRET="$SECRET" -v "$CLUSTER_DIR":/data/ipfs-cluster --entrypoint ipfs-cluster-service "$CLUSTER_IMAGE" "$@"; }
if [ ! -f "$CLUSTER_DIR/identity.json" ]; then
  info "Initializing ipfs-cluster ..."
  cl_oneshot init >/dev/null 2>&1 || cl_oneshot init >/dev/null
fi
NEW_CLUSTER_PEERID="$(jq -r '.id' "$CLUSTER_DIR/identity.json")"
[ -n "$NEW_CLUSTER_PEERID" ] && [ "$NEW_CLUSTER_PEERID" != "null" ] || die "could not read new cluster peer id."
# persistent connectivity to the master
echo "$MASTER_CLUSTER_BOOTSTRAP" > "$CLUSTER_DIR/peerstore"

TRUSTED="$MASTER_CLUSTER_PEERID,$NEW_CLUSTER_PEERID"
cat > /etc/systemd/system/ipfscluster.service <<EOF
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

info "Starting ipfs-cluster (joining master) ..."
systemctl daemon-reload
systemctl enable --now ipfscluster.service
sleep 8
docker exec ipfs_cluster ipfs-cluster-ctl id >/dev/null 2>&1 && info "cluster API up" || info "NOTE: cluster API not responding yet; check: docker logs ipfs_cluster"

cat <<EOF

[phase-1-setup-writer] DONE — new WRITER provisioned.
  NEW cluster peer id : $NEW_CLUSTER_PEERID
  NEW kubo peer id    : $NEW_KUBO_PEERID
  announcing on       : /$PROTO/$PUBLIC_HOST

Verify it joined + is replicating the pinset:
  docker exec ipfs_cluster ipfs-cluster-ctl peers ls   # should list the master + others
  docker exec ipfs_cluster ipfs-cluster-ctl status --filter pinned | wc -l   # grows toward master's count

Next (so the rest of the network trusts this writer):
  1) On the MASTER:   NEW_WRITER_PEERID=$NEW_CLUSTER_PEERID ./phase-1-master-trust.sh
  2) On the pool-server (join-server): add $NEW_CLUSTER_PEERID to IPFS_CLUSTER_TRUSTED_PEERS and restart.
EOF
