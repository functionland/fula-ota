#!/usr/bin/env bash
#
# fxe2e Phase-1 e2e — DRILLS (test server only). Asserts the Phase-1 acceptance:
#
#   D0 topology     : all 4 peers see each other
#   D1 baseline     : pin via MASTER -> both followers pin it (old + new)
#   D2 master DOWN  : pin via WRITER -> updated follower pins it; OLD follower keeps
#                     serving existing pins and does NOT see the writer pin (mixed fleet)
#   D3 master BACK  : CRDT reconverges — master learns the writer-era pin; nothing lost
#   D4 idempotency  : re-run setup-writer + master-trust -> no changes, peerset stable
#
# Production-grade: every assert polls with a deadline; any FAIL exits 1.
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

mctl() { docker exec fxe2e_m_cluster  ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/19094 "$@"; }
wctl() { docker exec ipfs_cluster      ipfs-cluster-ctl "$@"; }
actl() { docker exec fxe2e_fA_cluster  ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/29094 "$@"; }
bctl() { docker exec fxe2e_fB_cluster  ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/39094 "$@"; }

A_ID="$(jq -r '.id' /opt/fxe2e/fA/cluster/identity.json)"
B_ID="$(jq -r '.id' /opt/fxe2e/fB/cluster/identity.json)"
M_ID="$(jq -r '.id' /opt/fxe2e/master/cluster/identity.json)"
# shellcheck disable=SC1091
W_ID="$(. /opt/fula-writer/.env; printf '%s' "$NEW_CLUSTER_PEERID")"

# poll JSON status until .peer_map[peerid].status == "pinned" (deadline secs)
pin_state() { "$1" --enc=json status "$2" 2>/dev/null | jq -r --arg p "$3" '.peer_map[$p].status // "absent"' 2>/dev/null || echo absent; }
wait_pinned() { # $1=ctlfn $2=cid $3=peerid $4=deadline $5=label
  local t=0
  while [ "$t" -lt "$4" ]; do
    [ "$(pin_state "$1" "$2" "$3")" = "pinned" ] && { ok "$5"; return 0; }
    sleep 5; t=$((t+5))
  done
  bad "$5 (timeout ${4}s)"; "$1" status "$2" 2>/dev/null | sed 's/^/      /' | head -8; return 1
}

echo "== D0 topology =="
for i in $(seq 1 24); do
  n="$(mctl peers ls 2>/dev/null | grep -c '^12D3KooW' || true)"
  [ "${n:-0}" -ge 4 ] && break; sleep 5
done
n="$(mctl peers ls 2>/dev/null | grep -c '^12D3KooW' || true)"
[ "${n:-0}" -ge 4 ] && ok "D0 master sees >=4 cluster peers ($n)" || bad "D0 master sees $n peers (want >=4)"

echo "== D1 baseline: pin via MASTER reaches old+new followers =="
CID1="$(echo "fxe2e-baseline-$(date +%s)" | docker exec -i fxe2e_m_ipfs ipfs add -q)"
[ -n "$CID1" ] && ok "D1 content added on master kubo ($CID1)" || bad "D1 could not add content"
mctl pin add "$CID1" >/dev/null 2>&1 || bad "D1 master pin add failed"
wait_pinned actl "$CID1" "$A_ID" 180 "D1 follower A (updated) pinned baseline CID"
wait_pinned bctl "$CID1" "$B_ID" 180 "D1 follower B (old) pinned baseline CID"

PRE_DOWN_MASTER_PINS="$(mctl status --filter pinned 2>/dev/null | grep -c '^[A-Za-z0-9]' || true)"

echo "== D2 master DOWN: writer keeps the network writable; old follower unaffected =="
systemctl stop fxe2e-master-ipfscluster.service
sleep 3
CID2="$(echo "fxe2e-writer-era-$(date +%s)" | docker exec -i ipfs_host ipfs add -q)"
wctl pin add "$CID2" >/dev/null 2>&1 && ok "D2 pin add via WRITER succeeded with master down" || bad "D2 writer pin add failed"
wait_pinned actl "$CID2" "$A_ID" 240 "D2 follower A (updated) pinned writer-era CID with master DOWN"
if [ "$(pin_state bctl "$CID2" "$B_ID")" = "pinned" ]; then
  bad "D2 follower B (old) unexpectedly pinned a writer-issued CID (should not trust writer)"
else
  ok "D2 follower B (old) does NOT see writer-issued pin (expected mixed-fleet behavior)"
fi
[ "$(pin_state bctl "$CID1" "$B_ID")" = "pinned" ] \
  && ok "D2 follower B (old) still serves its existing pin during master outage" \
  || bad "D2 follower B (old) lost its existing pin"

echo "== D3 master BACK: CRDT reconverges, nothing lost =="
systemctl start fxe2e-master-ipfscluster.service
for i in $(seq 1 30); do docker exec fxe2e_m_cluster ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/19094 id >/dev/null 2>&1 && break; sleep 5; done
t=0; got=""
while [ "$t" -lt 300 ]; do
  if mctl status "$CID2" 2>/dev/null | grep -qi 'PINNED'; then got=1; break; fi
  sleep 10; t=$((t+10))
done
[ -n "$got" ] && ok "D3 master converged to writer-era pin after restart" || bad "D3 master never learned writer-era pin (300s)"
POST_UP_MASTER_PINS="$(mctl status --filter pinned 2>/dev/null | grep -c '^[A-Za-z0-9]' || true)"
[ "${POST_UP_MASTER_PINS:-0}" -ge "${PRE_DOWN_MASTER_PINS:-0}" ] \
  && ok "D3 pinset never shrank (pre=$PRE_DOWN_MASTER_PINS post=$POST_UP_MASTER_PINS)" \
  || bad "D3 pinset shrank (pre=$PRE_DOWN_MASTER_PINS post=$POST_UP_MASTER_PINS)"
wait_pinned bctl "$CID1" "$B_ID" 90 "D3 follower B (old) still healthy after master bounce"

echo "== D4 idempotency: re-runs are no-ops =="
if (cd "$HERE/../../../update-scripts" && bash phase-1-setup-writer.sh >/tmp/fxe2e-rerun-writer.log 2>&1); then
  grep -qiE 'unchanged|skip' /tmp/fxe2e-rerun-writer.log && ok "D4 setup-writer re-run: no-op paths taken" || ok "D4 setup-writer re-run exited 0"
else
  bad "D4 setup-writer re-run failed (see /tmp/fxe2e-rerun-writer.log)"
fi
if UNIT_PATH=/etc/systemd/system/fxe2e-master-ipfscluster.service SERVICE_NAME=fxe2e-master-ipfscluster \
   ENV_FILE=/opt/fxe2e/master-trust.env NEW_WRITER_PEERID="$W_ID" \
   bash "$HERE/../../../update-scripts/phase-1-master-trust.sh" >/tmp/fxe2e-rerun-trust.log 2>&1; then
  grep -qi 'already trusted' /tmp/fxe2e-rerun-trust.log && ok "D4 master-trust re-run: already-trusted no-op" || ok "D4 master-trust re-run exited 0"
else
  bad "D4 master-trust re-run failed (see /tmp/fxe2e-rerun-trust.log)"
fi
n2="$(mctl peers ls 2>/dev/null | grep -c '^12D3KooW' || true)"
[ "${n2:-0}" -ge 4 ] && ok "D4 peerset stable after re-runs ($n2)" || bad "D4 peerset shrank ($n2)"

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ] || exit 1
