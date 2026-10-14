#!/usr/bin/env bash
# Tests the shared phase-common helpers: env save/load (+ precedence), interactive
# prompt-with-default (forced via PC_FORCE_INTERACTIVE + piped stdin), non-interactive
# required/validation, and write-if-changed idempotency + backup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../update-scripts/lib/phase-common.sh"
[ -f "$LIB" ] || { echo "FAIL: lib not found $LIB"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0; pass(){ echo "ok   - $1"; }; bad(){ echo "FAIL - $1"; fail=1; }

# shellcheck disable=SC1090
. "$LIB"   # note: die() exits, so negative cases run in subshells

# save/load round-trip
FOO=hello; BAR=world
pc_save_env "$TMP/p.env" FOO BAR >/dev/null
unset FOO BAR
pc_load_env "$TMP/p.env" >/dev/null
{ [ "${FOO:-}" = hello ] && [ "${BAR:-}" = world ]; } && pass "save/load round-trip" || bad "save/load round-trip"

# CLI/env value beats a saved .env value
FOO=cli; pc_load_env "$TMP/p.env" >/dev/null
[ "$FOO" = cli ] && pass "env beats saved .env" || bad "env beats saved .env (got $FOO)"

# non-interactive: missing required -> die
( unset BAZ; PC_FORCE_INTERACTIVE=0; pc_prompt BAZ "Baz" >/dev/null 2>&1 ) && bad "noninteractive missing -> die" || pass "noninteractive missing -> die"
# non-interactive: present + valid -> kept
( QUX=12D3KooWabc; PC_FORCE_INTERACTIVE=0; pc_prompt QUX "Qux" '^12D3KooW' >/dev/null 2>&1 && [ "$QUX" = 12D3KooWabc ] ) && pass "noninteractive valid kept" || bad "noninteractive valid kept"
# non-interactive: present + invalid -> die
( BADV=nope; PC_FORCE_INTERACTIVE=0; pc_prompt BADV "Badv" '^12D3KooW' >/dev/null 2>&1 ) && bad "noninteractive invalid -> die" || pass "noninteractive invalid -> die"

# interactive (forced) empty input keeps current default
out="$(printf '\n' | PC_FORCE_INTERACTIVE=1 bash -c '. "'"$LIB"'"; CUR=keepme; pc_prompt CUR "Cur"; echo "VAL=$CUR"' 2>/dev/null)"
echo "$out" | grep -q "VAL=keepme" && pass "interactive empty keeps default" || bad "interactive empty keeps default ($out)"
# interactive new value overrides
out2="$(printf 'newval\n' | PC_FORCE_INTERACTIVE=1 bash -c '. "'"$LIB"'"; CUR=old; pc_prompt CUR "Cur"; echo "VAL=$CUR"' 2>/dev/null)"
echo "$out2" | grep -q "VAL=newval" && pass "interactive new value used" || bad "interactive new value used ($out2)"

# write-if-changed: changed -> unchanged -> changed(+backup)
f="$TMP/u.conf"
[ "$(printf 'A\n' | pc_write_if_changed "$f")" = changed ]   && pass "write: first=changed"        || bad "write: first=changed"
[ "$(printf 'A\n' | pc_write_if_changed "$f")" = unchanged ] && pass "write: same=unchanged"       || bad "write: same=unchanged"
r3="$(printf 'B\n' | pc_write_if_changed "$f")"
{ [ "$r3" = changed ] && ls "$f".bak.* >/dev/null 2>&1; } && pass "write: diff=changed+backup" || bad "write: diff=changed+backup ($r3)"

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
