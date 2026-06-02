#!/usr/bin/env bash
# Shared helpers for fula phase install/update scripts — idempotent + re-runnable.
#
# Source it from a phase script:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; . "$SCRIPT_DIR/lib/phase-common.sh"
#
# Behaviour it gives every phase script:
#  - pc_load_env "$ENV_FILE"  : prior saved params become defaults (a CLI/env value
#                               always wins over a saved one).
#  - pc_prompt VAR "Label" [regex] [secret] : asks INTERACTIVELY (a TTY, or
#                               PC_FORCE_INTERACTIVE=1) showing the current/saved value
#                               as the default; pressing Enter keeps it. NON-interactive
#                               (no TTY, e.g. CI/cron): uses the env/.env value, or dies
#                               if a required value is missing (never guesses).
#  - pc_save_env "$ENV_FILE" VAR...  : persist chosen params for the next run.
#  - pc_write_if_changed PATH  : write stdin to PATH only if different (backs up first),
#                               so re-runs don't needlessly restart services.
#  - pc_have / detection helpers : skip work that's already done; never panic.

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[${PC_TAG:-phase}] $*"; }
pc_have() { command -v "$1" >/dev/null 2>&1; }
pc_is_interactive() { [ -t 0 ] || [ "${PC_FORCE_INTERACTIVE:-0}" = "1" ]; }

pc_load_env() {
  local f="${1:-}"; [ -n "$f" ] && [ -f "$f" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    v="${v%\"}"; v="${v#\"}"
    # only fill if not already set in the environment — a CLI/env value wins
    if [ -z "${!k:-}" ]; then printf -v "$k" '%s' "$v"; export "$k"; fi
  done < "$f"
  info "loaded saved params from $f"
}

pc_save_env() {
  local f="${1:-}"; shift || true
  [ -n "$f" ] || return 0
  mkdir -p "$(dirname "$f")"
  local tmp="${f}.tmp.$$" v
  {
    echo "# fula phase params — auto-saved; safe to edit. Re-running reuses these as defaults."
    for v in "$@"; do printf '%s=%s\n' "$v" "${!v:-}"; done
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
  info "saved params to $f"
}

# pc_prompt VAR "Label" [validation-regex] [secret]
pc_prompt() {
  local var="$1" label="$2" regex="${3:-}" secret="${4:-}"
  local cur input val
  cur="${!var:-}"; val="$cur"; input=""
  if pc_is_interactive; then
    while :; do
      input=""
      if [ -n "$secret" ]; then
        printf '%s%s: ' "$label" "${cur:+ [keep current]}" >&2; read -r -s input || true; echo >&2
      else
        printf '%s%s: ' "$label" "${cur:+ [$cur]}" >&2; read -r input || true
      fi
      [ -z "$input" ] && input="$cur"
      if [ -z "$input" ]; then echo "  required — please enter a value" >&2; continue; fi
      if [ -n "$regex" ] && ! [[ "$input" =~ $regex ]]; then echo "  invalid (expected: $regex)" >&2; continue; fi
      val="$input"; break
    done
  else
    [ -n "$val" ] || die "$var is required — set it as an env var or run interactively (refusing to guess)."
    if [ -n "$regex" ] && ! [[ "$val" =~ $regex ]]; then die "$var='$val' is invalid (expected: $regex)."; fi
  fi
  printf -v "$var" '%s' "$val"; export "$var"
}

# pc_write_if_changed PATH   (new content on stdin) -> echoes "changed" | "unchanged"
pc_write_if_changed() {
  local path="$1" tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; echo "unchanged"; return 0; fi
  [ -f "$path" ] && cp -a "$path" "${path}.bak.$(date +%s)"
  mkdir -p "$(dirname "$path")"
  mv "$tmp" "$path"
  echo "changed"
}

pc_backup()           { [ -f "$1" ] && cp -a "$1" "$1.bak.$(date +%s)" && info "backed up $1"; return 0; }
pc_container_exists() { grep -qx "$1" <<<"$(docker ps -a --format '{{.Names}}' 2>/dev/null)"; }
pc_service_active()   { systemctl is-active --quiet "$1" 2>/dev/null; }
