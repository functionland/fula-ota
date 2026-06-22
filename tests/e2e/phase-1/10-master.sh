#!/usr/bin/env bash
#
# fxe2e Phase-1 e2e — role: SIMULATED MASTER (test server only, NEVER production).
#
# Provisions an isolated test cluster master that mirrors the production master's
# SHAPE (systemd unit -> docker run, env-driven, CLUSTER_CRDT_TRUSTEDPEERS on both the
# Environment= line and the ExecStart -e flag) but with prefixed names + shifted ports
# so the REAL phase-1-setup-writer.sh can run with its defaults on the same box.
# Idempotent: re-run safe. Cluster name carries a random-but-fixed suffix so the
# derived secret is not guessable on a public test box.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../../update-scripts/lib/phase-common.sh"
PC_TAG="fxe2e-master"

CLUSTERNAME="${FXE2E_CLUSTERNAME:-fxe2e-vt9q4z}"
SECRET="$(printf '%s' "$CLUSTERNAME" | sha256sum | cut -d' ' -f1)"
BASE=/opt/fxe2e/master; KUBO_DIR="$BASE/kubo"; CL_DIR="$BASE/cluster"
KUBO_IMAGE="${KUBO_IMAGE:-ipfs/kubo:release}"
CLUSTER_IMAGE="${CLUSTER_IMAGE:-ipfs/ipfs-cluster:stable}"
[ "$(id -u)" = 0 ] || die "run as root"
pc_have docker || die "docker required (run phase-1-setup-writer.sh first or install docker)"
mkdir -p "$KUBO_DIR" "$CL_DIR"

# ---- kubo (shifted ports: swarm 14001, API 127.0.0.1:15001, gw 127.0.0.1:18080) ----
# --entrypoint ipfs bypasses the image's auto-init entrypoint (double-init bug); config is
# applied only on FRESH init (one-shot `ipfs config` needs the repo lock — re-runs with the
# daemon up would fail; port changes require stopping the unit + wiping is fine: TEST ONLY).
k() { docker run --rm --entrypoint ipfs -e IPFS_PATH=/data/ipfs -v "$KUBO_DIR":/data/ipfs "$KUBO_IMAGE" "$@"; }
if [ -f "$KUBO_DIR/config" ]; then info "master kubo repo exists — skip init+config"
else
  info "init master kubo"
  k init --profile=server >/dev/null
  k config Addresses.API /ip4/127.0.0.1/tcp/15001 >/dev/null
  k config Addresses.Gateway /ip4/127.0.0.1/tcp/18080 >/dev/null
  k config --json Addresses.Swarm '["/ip4/0.0.0.0/tcp/14001"]' >/dev/null
fi
MASTER_KUBO_PEERID="$(jq -r '.Identity.PeerID // empty' "$KUBO_DIR/config")"; [ -n "$MASTER_KUBO_PEERID" ] || die "no master kubo peer id"

ku_ch="$(cat <<EOF | pc_write_if_changed /etc/systemd/system/fxe2e-master-ipfs.service
[Unit]
Description=fxe2e master IPFS (TEST ONLY)
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker rm -f fxe2e_m_ipfs
ExecStart=/usr/bin/docker run -u root --rm --name fxe2e_m_ipfs --network host -e IPFS_PATH=/data/ipfs -v $KUBO_DIR:/data/ipfs $KUBO_IMAGE
ExecStop=/usr/bin/docker stop -t 30 fxe2e_m_ipfs
Restart=always
RestartSec=10s
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
)"
systemctl daemon-reload; systemctl enable --now fxe2e-master-ipfs.service
[ "$ku_ch" = changed ] && systemctl restart fxe2e-master-ipfs.service
for i in $(seq 1 30); do curl -s -X POST http://127.0.0.1:15001/api/v0/id >/dev/null 2>&1 && break; [ "$i" = 30 ] && die "master kubo not healthy on :15001"; sleep 3; done
info "master kubo healthy ($MASTER_KUBO_PEERID)"

# ---- cluster (shifted ports: swarm 19096, REST 127.0.0.1:19094, proxy 127.0.0.1:19095) ----
cl() { docker run --rm -e IPFS_CLUSTER_PATH=/data/ipfs-cluster -e CLUSTER_SECRET="$SECRET" -v "$CL_DIR":/data/ipfs-cluster --entrypoint ipfs-cluster-service "$CLUSTER_IMAGE" "$@"; }
if [ -f "$CL_DIR/identity.json" ]; then info "master cluster identity exists — skip init"; else info "init master cluster"; cl init >/dev/null 2>&1 || cl init >/dev/null; fi
MASTER_CLUSTER_PEERID="$(jq -r '.id' "$CL_DIR/identity.json")"
{ [ -n "$MASTER_CLUSTER_PEERID" ] && [ "$MASTER_CLUSTER_PEERID" != null ]; } || die "no master cluster peer id"

# Trust line mirrors prod shape: present on BOTH Environment= and ExecStart -e so
# phase-1-master-trust.sh (UNIT_PATH/SERVICE_NAME overrides) edits it exactly like prod.
# Re-runs PRESERVE the current trusted list (master-trust may have appended writers —
# regenerating from the template must never revert that).
TRUST_LINE="$MASTER_CLUSTER_PEERID"
if [ -f /etc/systemd/system/fxe2e-master-ipfscluster.service ]; then
  cur_trust="$(grep -oE 'CLUSTER_CRDT_TRUSTEDPEERS=[^" ]+' /etc/systemd/system/fxe2e-master-ipfscluster.service | head -1 | cut -d= -f2- || true)"
  [ -n "$cur_trust" ] && TRUST_LINE="$cur_trust"
fi
cl_ch="$(cat <<EOF | pc_write_if_changed /etc/systemd/system/fxe2e-master-ipfscluster.service
[Unit]
Description=fxe2e master IPFSCLUSTER (TEST ONLY)
After=fxe2e-master-ipfs.service
Requires=fxe2e-master-ipfs.service

[Service]
Type=simple
User=root
Environment="CLUSTER_CRDT_TRUSTEDPEERS=$TRUST_LINE"
ExecStartPre=-/usr/bin/docker rm -f fxe2e_m_cluster
ExecStart=/usr/bin/docker run -u root --rm --name fxe2e_m_cluster --network host -e IPFS_CLUSTER_PATH=/data/ipfs-cluster -e CLUSTER_LISTENMULTIADDRESS=/ip4/0.0.0.0/tcp/19096 -e CLUSTER_RESTAPI_HTTPLISTENMULTIADDRESS=/ip4/127.0.0.1/tcp/19094 -e CLUSTER_IPFSPROXY_LISTENMULTIADDRESS=/ip4/127.0.0.1/tcp/19095 -e CLUSTER_PINSVCAPI_HTTPLISTENMULTIADDRESS=/ip4/127.0.0.1/tcp/19097 -e CLUSTER_IPFSHTTP_NODEMULTIADDRESS=/ip4/127.0.0.1/tcp/15001 -e CLUSTER_ALLOCATOR_ALLOCATEBY="tag:group,pinqueue,reposize" -e CLUSTER_REPLICATIONFACTORMIN=2 -e CLUSTER_REPLICATIONFACTORMAX=4 -e CLUSTER_DISABLEREPINNING=false -e CLUSTER_CLUSTERNAME=$CLUSTERNAME -e CLUSTER_SECRET=$SECRET -e CLUSTER_FOLLOWERMODE=false -e CLUSTER_CRDT_TRUSTEDPEERS=$TRUST_LINE -e CLUSTER_PEERNAME=fxe2e-master -e CLUSTER_MONITORPINGINTERVAL=15s -v $CL_DIR:/data/ipfs-cluster $CLUSTER_IMAGE daemon --upgrade
ExecStop=/usr/bin/docker stop -t 30 fxe2e_m_cluster
Restart=always
RestartSec=10s
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
)"
systemctl daemon-reload; systemctl enable --now fxe2e-master-ipfscluster.service
[ "$cl_ch" = changed ] && systemctl restart fxe2e-master-ipfscluster.service
for i in $(seq 1 30); do docker exec fxe2e_m_cluster ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/19094 id >/dev/null 2>&1 && break; [ "$i" = 30 ] && die "master cluster API not healthy on :19094"; sleep 3; done
info "master cluster healthy"

PUB_IP="${PUBLIC_HOST:-$(hostname -I | awk '{print $1}')}"
cat <<EOF
[fxe2e-master] DONE (idempotent).
  CLUSTERNAME            : $CLUSTERNAME
  MASTER_CLUSTER_PEERID  : $MASTER_CLUSTER_PEERID
  MASTER_KUBO_PEERID     : $MASTER_KUBO_PEERID
  MASTER_CLUSTER_BOOTSTRAP: /ip4/$PUB_IP/tcp/19096/p2p/$MASTER_CLUSTER_PEERID
Next: run the REAL writer script against this master, e.g.
  PUBLIC_HOST=$PUB_IP CLUSTERNAME=$CLUSTERNAME \\
  MASTER_CLUSTER_PEERID=$MASTER_CLUSTER_PEERID \\
  MASTER_CLUSTER_BOOTSTRAP=/ip4/$PUB_IP/tcp/19096/p2p/$MASTER_CLUSTER_PEERID \\
  bash ../../../update-scripts/phase-1-setup-writer.sh
EOF
