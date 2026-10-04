#!/usr/bin/env bash
#
# test-nas-credentials.sh — exercises docker/fxsupport/linux/nas-credentials.sh
# against shimmed account/Samba tools, so it never touches real users or Samba.
#
# Must run as root (the script refuses otherwise) on a Linux host with python3:
#   sudo bash tests/test-nas-credentials.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../docker/fxsupport/linux/nas-credentials.sh"
PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

if [ "$(id -u)" -ne 0 ]; then
    echo "SKIP: must run as root (nas-credentials.sh refuses non-root)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SHIMS="$WORK/shims"
STATE="$WORK/state"
mkdir -p "$SHIMS" "$STATE"

# --- shims ------------------------------------------------------------------
cat > "$SHIMS/useradd" <<EOF
#!/bin/sh
echo "\$*" >> "$STATE/useradd.log"
echo 999 > "$STATE/uid"; echo /usr/sbin/nologin > "$STATE/shell"; touch "$STATE/user"
EOF
cat > "$SHIMS/id" <<EOF
#!/bin/sh
case "\$*" in
  "-u")        echo 0 ;;
  "-u fxnas")  [ -f "$STATE/user" ] && cat "$STATE/uid" || exit 1 ;;
  "fxnas")     [ -f "$STATE/user" ] || exit 1; echo "uid=\$(cat $STATE/uid)(fxnas)" ;;
  *)           exec /usr/bin/id "\$@" ;;
esac
EOF
cat > "$SHIMS/getent" <<EOF
#!/bin/sh
[ "\$1 \$2" = "passwd fxnas" ] && [ -f "$STATE/user" ] || exit 2
echo "fxnas:x:\$(cat $STATE/uid):\$(cat $STATE/uid)::/nonexistent:\$(cat $STATE/shell)"
EOF
cat > "$SHIMS/pdbedit" <<EOF
#!/bin/sh
[ -f "$STATE/smbuser" ] && echo "fxnas:999:"
[ -f "$STATE/smbpi" ] && echo "pi:1000:pi"
exit 0
EOF
cat > "$SHIMS/smbpasswd" <<EOF
#!/bin/sh
echo "\$*" >> "$STATE/smbpasswd.log"
case "\$*" in
  "-s -a fxnas") read -r p1; read -r p2; [ "\$p1" = "\$p2" ] || exit 1
                 printf '%s' "\$p1" > "$STATE/smbpw"; touch "$STATE/smbuser" ;;
  "-x pi")       rm -f "$STATE/smbpi" ;;
esac
exit 0
EOF
cat > "$SHIMS/smbcontrol" <<EOF
#!/bin/sh
echo "\$*" >> "$STATE/smbcontrol.log"
EOF
chmod +x "$SHIMS"/*

export PATH="$SHIMS:$PATH"
export FULA_NAS_DIR="$WORK/nas"
export FULA_NAS_LOCK="$WORK/nas.lock"
CRED="$FULA_NAS_DIR/credentials.json"
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]] or "")' "$CRED" "$1"; }
run()   { bash "$SCRIPT" "$@" > "$WORK/out" 2>&1; echo $? > "$WORK/rc"; }

echo "== ensure (fresh) =="
run ensure
check '[ "$(cat $WORK/rc)" = 0 ]' "ensure exits 0"
check 'grep -q -- "--system" "$STATE/useradd.log" && grep -q -- "--shell /usr/sbin/nologin" "$STATE/useradd.log"' \
      "fxnas created as a nologin system account"
check '[ "$(stat -c %a "$CRED")" = 600 ] && [ "$(stat -c %a "$FULA_NAS_DIR")" = 700 ]' "credentials 0600 in a 0700 dir"
PW="$(field password)"
check '[[ "$PW" =~ ^[2-9a-hjkmnp-z]{5}(-[2-9a-hjkmnp-z]{5}){3}$ ]]' "password has the expected format"
check '[ "$(cat $STATE/smbpw)" = "$PW" ]' "samba received the stored password"
check '! grep -qF "$PW" "$WORK/out"' "password not printed by ensure"
check '[ "$(field username)" = fxnas ] && [ "$(field share)" = SharedFolder ]' "username/share recorded"

echo "== ensure (again) =="
before_calls=$(wc -l < "$STATE/smbpasswd.log")
run ensure
check '[ "$(cat $WORK/rc)" = 0 ]' "second ensure exits 0"
check '[ "$(wc -l < $STATE/useradd.log)" = 1 ]' "no second useradd"
check '[ "$(field password)" = "$PW" ]' "password unchanged"
check '[ "$(wc -l < $STATE/smbpasswd.log)" = "$before_calls" ]' "samba not re-applied when already in sync"

echo "== ensure re-applies when samba lost the user =="
rm -f "$STATE/smbuser"
run ensure
check '[ -f "$STATE/smbuser" ] && [ "$(cat $STATE/smbpw)" = "$PW" ]' "re-applied the same password"

echo "== status / show =="
run status
check 'grep -q "provisioned: yes" "$WORK/out" && ! grep -qF "$PW" "$WORK/out"' "status reports provisioned, no password"
run show
check '[ "$(cat $WORK/rc)" != 0 ] && ! grep -qF "$PW" "$WORK/out"' "show refuses a non-terminal"
run show --force
check 'grep -qF "$PW" "$WORK/out"' "show --force prints the password"

echo "== rotate =="
created="$(field created_at)"
run rotate
NEWPW="$(field password)"
check '[ "$(cat $WORK/rc)" = 0 ] && [ "$NEWPW" != "$PW" ]' "rotate changes the password"
check '[ "$(cat $STATE/smbpw)" = "$NEWPW" ]' "samba has the rotated password"
check 'grep -q "close-share SharedFolder" "$STATE/smbcontrol.log"' "rotate closes open SharedFolder sessions"
check '[ "$(field created_at)" = "$created" ] && [ -n "$(field rotated_at)" ]' "created_at kept, rotated_at set"
check '! grep -qF "$NEWPW" "$WORK/out"' "password not printed by rotate"

echo "== hostile pre-existing account =="
rm -rf "$FULA_NAS_DIR" "$STATE"/*
touch "$STATE/user"; echo 1001 > "$STATE/uid"; echo /bin/bash > "$STATE/shell"
run ensure
check '[ "$(cat $WORK/rc)" != 0 ] && [ ! -f "$CRED" ]' "refuses to take over a real user account"

echo
echo "nas-credentials tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
