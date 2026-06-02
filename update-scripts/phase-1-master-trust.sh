#!/usr/bin/env bash
#
# Phase 1 (cluster write-federation) — trust a 2nd cluster WRITER on the master.
#
# Appends NEW_WRITER_PEERID to CLUSTER_CRDT_TRUSTEDPEERS in the master's systemd unit
# (both the Environment= line AND the ExecStart `-e` flag), backs up the unit, reloads
# systemd, restarts the cluster, and verifies it came back up.
#
# SAFE: additive only — it just appends a trusted peer id. The cluster datastore
# (/uniondrive/ipfs-cluster/pebble) and identity are never touched, so the existing
# pinset is preserved. A timestamped backup is written and the rollback command printed.
# This is a SERVER-side script (the master is systemd-managed, NOT part of the OTA fleet).
#
# Usage (on the MASTER, as root):
#   NEW_WRITER_PEERID=12D3KooW... ./phase-1-master-trust.sh             # apply
#   NEW_WRITER_PEERID=12D3KooW... DRY_RUN=1 ./phase-1-master-trust.sh   # show plan only
#
# Env overrides:
#   UNIT_PATH     (default /etc/systemd/system/ipfscluster.service)
#   SERVICE_NAME  (default ipfscluster)
#   DRY_RUN=1     print the planned change; modify nothing
#   NO_RESTART=1  edit + backup only; skip daemon-reload/restart/verify (used by tests)
#
set -euo pipefail

UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/ipfscluster.service}"
SERVICE_NAME="${SERVICE_NAME:-ipfscluster}"
DRY_RUN="${DRY_RUN:-0}"
NO_RESTART="${NO_RESTART:-0}"
VAR="CLUSTER_CRDT_TRUSTEDPEERS"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[phase-1-master-trust] $*"; }

# --- preconditions (halt rather than guess) ---
[ -n "${NEW_WRITER_PEERID:-}" ] || die "NEW_WRITER_PEERID is required (the new writer's CLUSTER peer id, e.g. 12D3KooW...). Refusing to guess."
case "$NEW_WRITER_PEERID" in
  12D3KooW*|Qm*) : ;;
  *) die "NEW_WRITER_PEERID='$NEW_WRITER_PEERID' does not look like a libp2p peer id (expected 12D3KooW... or Qm...)." ;;
esac
[ -f "$UNIT_PATH" ] || die "Unit file not found: $UNIT_PATH (set UNIT_PATH=... if it lives elsewhere)."
if [ "$NO_RESTART" != "1" ] && [ "$DRY_RUN" != "1" ]; then
  [ "$(id -u)" = "0" ] || die "Must run as root to edit $UNIT_PATH and restart the service."
fi

# --- read current trusted-peers value ---
CURRENT="$(grep -oE "${VAR}=[^\" ]+" "$UNIT_PATH" | head -1 | cut -d= -f2- || true)"
[ -n "$CURRENT" ] || die "Could not find ${VAR}= in $UNIT_PATH."
info "Current ${VAR} = ${CURRENT}"

# --- idempotency: already trusted? ---
case ",${CURRENT}," in
  *",${NEW_WRITER_PEERID},"*)
    info "Already trusted: ${NEW_WRITER_PEERID} is present — no change needed."
    exit 0
    ;;
esac

NEWVAL="${CURRENT},${NEW_WRITER_PEERID}"
info "New ${VAR} = ${NEWVAL}"

if [ "$DRY_RUN" = "1" ]; then
  info "DRY_RUN=1 — would replace '${VAR}=${CURRENT}' with '${VAR}=${NEWVAL}' (Environment= line AND ExecStart -e). No changes made."
  exit 0
fi

# --- backup ---
BACKUP="${UNIT_PATH}.bak.$(date +%s)"
cp -a "$UNIT_PATH" "$BACKUP"
info "Backed up unit -> $BACKUP"

# --- edit (replaces EVERY occurrence: Environment= and ExecStart -e share the same token) ---
# CURRENT/NEWVAL are peer-id comma lists (base58 alnum + comma): safe as sed text.
sed -i "s|${VAR}=${CURRENT}|${VAR}=${NEWVAL}|g" "$UNIT_PATH"

# --- verify the critical ExecStart -e was updated (that's what reaches the container) ---
if ! grep -q -- "-e ${VAR}=${NEWVAL}" "$UNIT_PATH"; then
  cp -a "$BACKUP" "$UNIT_PATH"
  die "ExecStart '-e ${VAR}' was not updated as expected; restored from backup ($BACKUP)."
fi
info "Updated occurrences: $(grep -c "${VAR}=${NEWVAL}" "$UNIT_PATH" || true) (expect 2: Environment= + ExecStart -e)."

if [ "$NO_RESTART" = "1" ]; then
  info "NO_RESTART=1 — unit edited + backed up; skipping daemon-reload/restart/verify."
  exit 0
fi

# --- apply ---
info "Reloading systemd + restarting ${SERVICE_NAME} (brief cluster-API blip; datastore/pinset untouched)..."
systemctl daemon-reload
systemctl restart "${SERVICE_NAME}"
sleep 5

# --- verify service health ---
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "OK: ${SERVICE_NAME} is active."
else
  echo "ERROR: ${SERVICE_NAME} is NOT active after restart. Roll back with:" >&2
  echo "  cp -a '$BACKUP' '$UNIT_PATH' && systemctl daemon-reload && systemctl restart ${SERVICE_NAME}" >&2
  exit 1
fi
if command -v docker >/dev/null 2>&1; then
  sleep 3
  if docker exec ipfs_cluster ipfs-cluster-ctl id >/dev/null 2>&1; then
    info "OK: cluster API responds."
  else
    info "NOTE: cluster API not responding yet (may still be starting). Re-check: docker exec ipfs_cluster ipfs-cluster-ctl id"
  fi
fi

cat <<EOF
[phase-1-master-trust] DONE.
Verify the new writer is trusted and the pinset is intact:
  docker exec ipfs_cluster ipfs-cluster-ctl peers ls           # the new writer should appear
  docker exec ipfs_cluster ipfs-cluster-ctl status --filter pinned | wc -l   # compare to before
Rollback if needed:
  cp -a '$BACKUP' '$UNIT_PATH' && systemctl daemon-reload && systemctl restart ${SERVICE_NAME}
EOF
