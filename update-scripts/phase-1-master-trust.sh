#!/usr/bin/env bash
#
# Phase 1 — trust a 2nd cluster WRITER on the master. Idempotent + re-runnable.
#
# Appends NEW_WRITER_PEERID to CLUSTER_CRDT_TRUSTEDPEERS in the master's systemd unit
# (both the Environment= line AND the ExecStart `-e` flag), backs up, reloads, restarts,
# verifies. SAFE: additive only — the cluster datastore/identity/pinset are never touched.
# Run interactively and it asks for the peer id (saved for next time); non-interactive
# uses NEW_WRITER_PEERID from env/.env or halts.
#
# Env: UNIT_PATH (default /etc/systemd/system/ipfscluster.service), SERVICE_NAME (ipfscluster),
#      ENV_FILE (default /etc/fula/phase-1-master-trust.env), DRY_RUN=1, NO_RESTART=1 (tests).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/phase-common.sh
. "$SCRIPT_DIR/lib/phase-common.sh"
PC_TAG="phase-1-master-trust"

UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/ipfscluster.service}"
SERVICE_NAME="${SERVICE_NAME:-ipfscluster}"
ENV_FILE="${ENV_FILE:-/etc/fula/phase-1-master-trust.env}"
DRY_RUN="${DRY_RUN:-0}"; NO_RESTART="${NO_RESTART:-0}"
VAR="CLUSTER_CRDT_TRUSTEDPEERS"

pc_load_env "$ENV_FILE"
pc_prompt NEW_WRITER_PEERID "New writer cluster peer id (12D3KooW...)" '^(12D3KooW|Qm)'

[ -f "$UNIT_PATH" ] || die "unit file not found: $UNIT_PATH (set UNIT_PATH=... if elsewhere)."
if [ "$NO_RESTART" != 1 ] && [ "$DRY_RUN" != 1 ]; then [ "$(id -u)" = 0 ] || die "must run as root to edit $UNIT_PATH and restart."; fi

CURRENT="$(grep -oE "${VAR}=[^\" ]+" "$UNIT_PATH" | head -1 | cut -d= -f2- || true)"
[ -n "$CURRENT" ] || die "could not find ${VAR}= in $UNIT_PATH."
info "current ${VAR} = $CURRENT"

case ",${CURRENT}," in
  *",${NEW_WRITER_PEERID},"*) info "already trusted: ${NEW_WRITER_PEERID} — no change."; pc_save_env "$ENV_FILE" NEW_WRITER_PEERID; exit 0 ;;
esac
NEWVAL="${CURRENT},${NEW_WRITER_PEERID}"
info "new ${VAR} = $NEWVAL"
pc_save_env "$ENV_FILE" NEW_WRITER_PEERID

if [ "$DRY_RUN" = 1 ]; then info "DRY_RUN=1 — would set ${VAR}=${NEWVAL} (Environment= + ExecStart -e). No changes."; exit 0; fi

BACKUP="${UNIT_PATH}.bak.$(date +%s)"; cp -a "$UNIT_PATH" "$BACKUP"; info "backed up -> $BACKUP"
sed -i "s|${VAR}=${CURRENT}|${VAR}=${NEWVAL}|g" "$UNIT_PATH"
grep -q -- "-e ${VAR}=${NEWVAL}" "$UNIT_PATH" || { cp -a "$BACKUP" "$UNIT_PATH"; die "ExecStart '-e ${VAR}' not updated; restored from $BACKUP."; }
info "updated occurrences: $(grep -c "${VAR}=${NEWVAL}" "$UNIT_PATH" || true) (expect 2)"

if [ "$NO_RESTART" = 1 ]; then info "NO_RESTART=1 — edited + backed up; skipping restart."; exit 0; fi

info "daemon-reload + restart $SERVICE_NAME (brief cluster-API blip; datastore/pinset untouched)"
systemctl daemon-reload; systemctl restart "$SERVICE_NAME"; sleep 5
if systemctl is-active --quiet "$SERVICE_NAME"; then info "OK: $SERVICE_NAME active."
else echo "ROLL BACK: cp -a '$BACKUP' '$UNIT_PATH' && systemctl daemon-reload && systemctl restart $SERVICE_NAME" >&2; die "$SERVICE_NAME not active after restart."; fi
command -v docker >/dev/null 2>&1 && { sleep 3; docker exec ipfs_cluster ipfs-cluster-ctl id >/dev/null 2>&1 && info "cluster API responds" || info "NOTE: cluster API not up yet."; }
cat <<EOF
[phase-1-master-trust] DONE. Verify the new writer is trusted + pinset intact:
  docker exec ipfs_cluster ipfs-cluster-ctl peers ls
  docker exec ipfs_cluster ipfs-cluster-ctl status --filter pinned | wc -l
Rollback: cp -a '$BACKUP' '$UNIT_PATH' && systemctl daemon-reload && systemctl restart $SERVICE_NAME
EOF
