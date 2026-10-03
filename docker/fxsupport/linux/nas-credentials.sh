#!/usr/bin/env bash
#
# nas-credentials.sh — dedicated Samba-only NAS user with a per-device password.
#
#   ensure     create the user/password if missing and make sure Samba has it
#              (idempotent; never rotates an existing password)
#   show       print username + password (refuses unless stdout is a terminal;
#              --force overrides)
#   rotate     new password, apply it, close open SharedFolder sessions
#   status     username / created_at / provisioned (never the password)
#   username   print the NAS username (no root needed)
#
# The user has no shell, no home and no sudo, and its Linux password stays
# locked: it exists only so Samba can authenticate it. The password is stored
# in a root-only JSON file, which go-fula's owner-only `nas-credentials` action
# reads as /internal/nas/credentials.json. The password is never echoed to logs
# and never passed on a command line.

set -u
umask 077

NAS_USER="${FULA_NAS_USER:-fxnas}"
NAS_SHARE="${FULA_NAS_SHARE:-SharedFolder}"
NAS_DIR="${FULA_NAS_DIR:-/home/pi/.internal/nas}"
CRED_FILE="${NAS_DIR}/credentials.json"
APPLIED_FILE="${NAS_DIR}/.applied"
LOCK_FILE="${FULA_NAS_LOCK:-/run/fula-nas.lock}"

log() { echo "nas-credentials: $*" >&2; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 4 groups of 5 from an unambiguous 31-char alphabet (~99 bits). No @ : / % #,
# so it is safe in smb:// URLs and Windows/macOS connect dialogs.
gen_password() {
    python3 - <<'PY'
import secrets
alphabet = "23456789abcdefghjkmnpqrstuvwxyz"
print("-".join("".join(secrets.choice(alphabet) for _ in range(5)) for _ in range(4)))
PY
}

# read_field <key>: print a field of the credentials file ('' if absent).
read_field() {
    [ -f "$CRED_FILE" ] || return 1
    python3 - "$CRED_FILE" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        value = json.load(f).get(sys.argv[2])
except Exception:
    sys.exit(1)
if value is not None:
    sys.stdout.write(str(value))
PY
}

# write_creds <password> <created_at> <rotated_at|''>: atomic, 0600, dir 0700.
# The password travels in the environment, never in argv.
write_creds() {
    NAS_PW="$1" NAS_CREATED="$2" NAS_ROTATED="$3" \
    python3 - "$CRED_FILE" "$NAS_USER" "$NAS_SHARE" <<'PY'
import json, os, sys, tempfile
path, user, share = sys.argv[1:4]
directory = os.path.dirname(path)
os.makedirs(directory, mode=0o700, exist_ok=True)
os.chmod(directory, 0o700)
doc = {
    "version": 1,
    "username": user,
    "password": os.environ["NAS_PW"],
    "share": share,
    "created_at": os.environ["NAS_CREATED"],
    "rotated_at": os.environ.get("NAS_ROTATED") or None,
}
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".credentials.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

ensure_user() {
    local uid shell
    if id "$NAS_USER" >/dev/null 2>&1; then
        uid=$(id -u "$NAS_USER")
        shell=$(getent passwd "$NAS_USER" | cut -d: -f7)
        if [ "$uid" -ge 1000 ] || { [ "$shell" != "/usr/sbin/nologin" ] && [ "$shell" != "/bin/false" ]; }; then
            log "refusing: existing account '$NAS_USER' (uid $uid, shell $shell) is not a fula system account"
            return 1
        fi
        return 0
    fi
    useradd --system --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin --user-group "$NAS_USER"
}

smb_has_user() {
    timeout 20 pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$NAS_USER"
}

pw_digest() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# apply_password <password>: printf is a builtin, so the password never shows
# up in a process command line.
apply_password() {
    local pw="$1"
    printf '%s\n%s\n' "$pw" "$pw" | timeout 30 smbpasswd -s -a "$NAS_USER" >/dev/null 2>&1 || return 1
    timeout 20 smbpasswd -e "$NAS_USER" >/dev/null 2>&1 || true
    pw_digest "$pw" > "${APPLIED_FILE}.tmp" && chmod 600 "${APPLIED_FILE}.tmp" && \
        mv -f "${APPLIED_FILE}.tmp" "$APPLIED_FILE"
}

cmd_ensure() {
    local pw
    command -v smbpasswd >/dev/null 2>&1 || { log "samba is not installed"; return 1; }
    ensure_user || return 1
    pw=$(read_field password 2>/dev/null) || pw=""
    if [ -z "$pw" ]; then
        pw=$(gen_password) || { log "password generation failed"; return 1; }
        write_creds "$pw" "$(now_utc)" "" || { log "cannot write $CRED_FILE"; return 1; }
        log "generated NAS credentials for '$NAS_USER'"
    fi
    if [ "$(pw_digest "$pw")" != "$(cat "$APPLIED_FILE" 2>/dev/null)" ] || ! smb_has_user; then
        apply_password "$pw" || { log "failed to apply the password to samba"; return 1; }
        log "applied NAS password to samba"
    fi
    return 0
}

cmd_show() {
    if [ ! -t 1 ] && [ "${1:-}" != "--force" ]; then
        log "refusing to print the password to a non-terminal (use --force)"
        return 1
    fi
    [ -f "$CRED_FILE" ] || { log "not provisioned"; return 1; }
    echo "username: $(read_field username)"
    echo "password: $(read_field password)"
    echo "share:    \\\\$(hostname)\\$(read_field share)"
}

cmd_rotate() {
    local pw created
    command -v smbpasswd >/dev/null 2>&1 || { log "samba is not installed"; return 1; }
    ensure_user || return 1
    created=$(read_field created_at 2>/dev/null) || created=""
    [ -n "$created" ] || created=$(now_utc)
    pw=$(gen_password) || return 1
    write_creds "$pw" "$created" "$(now_utc)" || return 1
    apply_password "$pw" || { log "failed to apply the password to samba"; return 1; }
    timeout 20 smbcontrol smbd close-share "$NAS_SHARE" >/dev/null 2>&1 || true
    log "rotated NAS password for '$NAS_USER'"
}

cmd_status() {
    local provisioned=no
    if [ -f "$CRED_FILE" ] && smb_has_user; then
        provisioned=yes
    fi
    echo "username:    $NAS_USER"
    echo "created_at:  $(read_field created_at 2>/dev/null || echo -)"
    echo "provisioned: $provisioned"
}

main() {
    local cmd="${1:-status}"
    [ "$#" -gt 0 ] && shift
    if [ "$cmd" = "username" ]; then
        echo "$NAS_USER"
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        log "must run as root"
        return 1
    fi
    exec 9>"$LOCK_FILE" || return 1
    flock -w 30 9 || { log "another nas-credentials run holds the lock"; return 1; }
    case "$cmd" in
        ensure) cmd_ensure ;;
        show)   cmd_show "$@" ;;
        rotate) cmd_rotate ;;
        status) cmd_status ;;
        *)      log "usage: $0 {ensure|show|rotate|status|username}"; return 2 ;;
    esac
}

main "$@"
