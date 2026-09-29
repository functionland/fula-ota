#!/usr/bin/env bash
#
# fxe2e Phase-1 e2e — role: TWO FOLLOWERS on the test server (TEST ONLY).
#
#   follower A ("updated edge")  : trusts MASTER + WRITER   (kubo 24001/25001, cluster 29094/29096)
#   follower B ("old edge")      : trusts MASTER only       (kubo 34001/35001, cluster 39094/39096)
#
# B models a storage provider that has NOT updated — the mixed-fleet/no-forced-upgrade
# invariant says it must keep operating (serve + accept master-issued pins) and simply
# not see writer-issued pins. Run AFTER 10-master.sh and phase-1-setup-writer.sh
# (reads NEW_CLUSTER_PEERID from /opt/fula-writer/.env). Idempotent.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../../update-scripts/lib/phase-common.sh"
PC_TAG="fxe2e-followers"

CLUSTERNAME="${FXE2E_CLUSTERNAME:-fxe2e-vt9q4z}"
SECRET="$(printf '%s' "$CLUSTERNAME" | sha256sum | cut -d' ' -f1)"
KUBO_IMAGE="${KUBO_IMAGE:-ipfs/kubo:release}"
CLUSTER_IMAGE="${CLUSTER_IMAGE:-ipfs/ipfs-cluster:stable}"
[ "$(id -u)" = 0 ] || die "run as root"

MASTER_CL_DIR=/opt/fxe2e/master/cluster
[ -f "$MASTER_CL_DIR/identity.json" ] || die "master not provisioned — run 10-master.sh first"
MASTER_ID="$(jq -r '.id' "$MASTER_CL_DIR/identity.json")"
[ -f /opt/fula-writer/.env ] || die "writer not provisioned — run phase-1-setup-writer.sh first"
# shellcheck disable=SC1091
WRITER_ID="$(. /opt/fula-writer/.env; printf '%s' "${NEW_CLUSTER_PEERID:-}")"
WRITER_KUBO_ID="$(. /opt/fula-writer/.env; printf '%s' "${NEW_KUBO_PEERID:-}")"
[ -n "$WRITER_ID" ] || die "NEW_CLUSTER_PEERID missing from /opt/fula-writer/.env"
MASTER_KUBO_ID="$(jq -r '.Identity.PeerID // empty' /opt/fxe2e/master/kubo/config)"

mk_follower() { # $1=name(fA|fB) $2=trusted_csv $3=kubo_swarm $4=kubo_api $5=cl_swarm $6=cl_rest $7=peername
  local name="$1" trusted="$2" kswarm="$3" kapi="$4" clswarm="$5" clrest="$6" peername="$7"
  local base="/opt/fxe2e/$name" kdir cdir gw proxy pinsvc
  gw=$((kapi+1)); proxy=$((clrest+1)); pinsvc=$((clrest+3))   # all <65536, role-unique
  kdir="$base/kubo"; cdir="$base/cluster"; mkdir -p "$kdir" "$cdir"

  # --entrypoint ipfs bypasses auto-init entrypoint; config applied on fresh init only
  # (one-shot `ipfs config` needs the repo lock — daemon-up re-runs would fail).
  if [ ! -f "$kdir/config" ]; then
    info "[$name] init kubo"
    docker run --rm --entrypoint ipfs -e IPFS_PATH=/data/ipfs -v "$kdir":/data/ipfs "$KUBO_IMAGE" init --profile=server >/dev/null
    docker run --rm --entrypoint ipfs -e IPFS_PATH=/data/ipfs -v "$kdir":/data/ipfs "$KUBO_IMAGE" config Addresses.API "/ip4/127.0.0.1/tcp/$kapi" >/dev/null
    docker run --rm --entrypoint ipfs -e IPFS_PATH=/data/ipfs -v "$kdir":/data/ipfs "$KUBO_IMAGE" config Addresses.Gateway "/ip4/127.0.0.1/tcp/$gw" >/dev/null
    docker run --rm --entrypoint ipfs -e IPFS_PATH=/data/ipfs -v "$kdir":/data/ipfs "$KUBO_IMAGE" config --json Addresses.Swarm "[\"/ip4/0.0.0.0/tcp/$kswarm\"]" >/dev/null
  fi

  if [ ! -f "$cdir/identity.json" ]; then
    info "[$name] init cluster"
    docker run --rm -e IPFS_CLUSTER_PATH=/data/ipfs-cluster -e CLUSTER_SECRET="$SECRET" -v "$cdir":/data/ipfs-cluster --entrypoint ipfs-cluster-service "$CLUSTER_IMAGE" init >/dev/null 2>&1 || true
  fi
  printf '/ip4/127.0.0.1/tcp/19096/p2p/%s\n' "$MASTER_ID" > "$cdir/peerstore"
  case ",$trusted," in *",$WRITER_ID,"*) printf '/ip4/127.0.0.1/tcp/9096/p2p/%s\n' "$WRITER_ID" >> "$cdir/peerstore";; esac

  docker rm -f "fxe2e_${name}_ipfs" "fxe2e_${name}_cluster" >/dev/null 2>&1 || true
  docker run -d --restart unless-stopped --name "fxe2e_${name}_ipfs" --network host -e IPFS_PATH=/data/ipfs -v "$kdir":/data/ipfs "$KUBO_IMAGE" >/dev/null
  for i in $(seq 1 30); do curl -s -X POST "http://127.0.0.1:$kapi/api/v0/id" >/dev/null 2>&1 && break; [ "$i" = 30 ] && die "[$name] kubo not healthy on :$kapi"; sleep 3; done

  docker run -d --restart unless-stopped --name "fxe2e_${name}_cluster" --network host \
    -e IPFS_CLUSTER_PATH=/data/ipfs-cluster \
    -e CLUSTER_SECRET="$SECRET" \
    -e CLUSTER_CLUSTERNAME="$CLUSTERNAME" \
    -e CLUSTER_FOLLOWERMODE=true \
    -e CLUSTER_CRDT_TRUSTEDPEERS="$trusted" \
    -e CLUSTER_LISTENMULTIADDRESS="/ip4/0.0.0.0/tcp/$clswarm" \
    -e CLUSTER_RESTAPI_HTTPLISTENMULTIADDRESS="/ip4/127.0.0.1/tcp/$clrest" \
    -e CLUSTER_IPFSPROXY_LISTENMULTIADDRESS="/ip4/127.0.0.1/tcp/$proxy" \
    -e CLUSTER_PINSVCAPI_HTTPLISTENMULTIADDRESS="/ip4/127.0.0.1/tcp/$pinsvc" \
    -e CLUSTER_IPFSHTTP_NODEMULTIADDRESS="/ip4/127.0.0.1/tcp/$kapi" \
    -e CLUSTER_REPLICATIONFACTORMIN=2 -e CLUSTER_REPLICATIONFACTORMAX=4 \
    -e CLUSTER_DISABLEREPINNING=false \
    -e CLUSTER_PEERNAME="$peername" \
    -e CLUSTER_MONITORPINGINTERVAL=15s \
    -v "$cdir":/data/ipfs-cluster \
    "$CLUSTER_IMAGE" daemon --upgrade --bootstrap "/ip4/127.0.0.1/tcp/19096/p2p/$MASTER_ID" >/dev/null
  for i in $(seq 1 30); do docker exec "fxe2e_${name}_cluster" ipfs-cluster-ctl --host "/ip4/127.0.0.1/tcp/$clrest" id >/dev/null 2>&1 && break; [ "$i" = 30 ] && die "[$name] cluster API not healthy on :$clrest"; sleep 3; done
  info "[$name] healthy (trusts: $trusted)"

  # Deterministic bitswap on one box: connect this follower's kubo to master + writer kubo.
  docker exec "fxe2e_${name}_ipfs" ipfs swarm connect "/ip4/127.0.0.1/tcp/14001/p2p/$MASTER_KUBO_ID" >/dev/null 2>&1 || true
  [ -n "$WRITER_KUBO_ID" ] && docker exec "fxe2e_${name}_ipfs" ipfs swarm connect "/ip4/127.0.0.1/tcp/4001/p2p/$WRITER_KUBO_ID" >/dev/null 2>&1 || true
}

mk_follower fA "$MASTER_ID,$WRITER_ID" 24001 25001 29096 29094 fxe2e-follower-new
mk_follower fB "$MASTER_ID"            34001 35001 39096 39094 fxe2e-follower-old

cat <<EOF
[fxe2e-followers] DONE.
  follower A (updated): trusts master+writer   REST :29094
  follower B (old)    : trusts master only     REST :39094
Next: bash 30-drills.sh
EOF
