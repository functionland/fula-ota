#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

USER="pi"
PLUGIN_NAME="blox-ai"
INTERNAL_DIR="/home/$USER/.internal"
BLOX_AI_DIR="$INTERNAL_DIR/plugins/$PLUGIN_NAME"
PLUGIN_EXEC_DIR="/usr/bin/fula/plugins/${PLUGIN_NAME}"
COMMANDS_DIR="/home/$USER/commands"

# Container's bloxai user is uid 1000 (Dockerfile pins it). Match host's
# pi user (also uid 1000 on RK3588 fula-ota images) for read/write across
# bind mounts. Literal "1000:1000" fallback covers a hypothetical fleet
# member where the `pi` user lookup fails (shouldn't happen on fula-ota
# but defensive — Gemini v2 advisor catch).
PLUGIN_OWNER="pi:pi"
id -u pi >/dev/null 2>&1 || PLUGIN_OWNER="1000:1000"

# ---------------------------------------------------------------------------
# Phase 6 migration shim — clean up the prior `loyal-agent` plugin slot.
# Idempotent; safe to run when no loyal-agent unit/dir exists. The /uniondrive
# model data is preserved deliberately so the user can manually reclaim disk.
# Remove this block in Phase 22 once all canary devices have rotated.
# ---------------------------------------------------------------------------
if systemctl list-unit-files 2>/dev/null | grep -q '^loyal-agent\.service'; then
  echo "Phase 6 migration: stopping/disabling prior loyal-agent.service"
  # Tear down the compose stack BEFORE removing the unit so containers don't
  # linger if systemctl stop alone misses them (e.g. compose was invoked
  # directly, or the unit's ExecStop never ran cleanly). 60s timeout because
  # `|| true` only handles non-zero exit, not an indefinite hang — direct
  # install.sh has no outer wrapper, plugins.sh's 300s wrapper only applies
  # via that path (Codex post-review catch).
  if [ -f "/home/pi/.internal/plugins/loyal-agent/docker-compose.yml" ]; then
    timeout 60 docker-compose -f /home/pi/.internal/plugins/loyal-agent/docker-compose.yml down 2>/dev/null || true
  fi
  systemctl stop loyal-agent.service 2>/dev/null || true
  systemctl disable loyal-agent.service 2>/dev/null || true
  rm -f /etc/systemd/system/loyal-agent.service
  systemctl daemon-reload || true
fi
if [ -d "/home/pi/.internal/plugins/loyal-agent" ]; then
  rm -rf /home/pi/.internal/plugins/loyal-agent || true
fi

# RAM gate — Phase 8 lowered to accept 4 GB-spec devices now that the
# model is Qwen 3B (~3 GB resident) instead of Deepseek 7B.
# Threshold in KB (NOT GB) for precision: 4 GB-spec RK3588 boards report
# MemTotal between ~3.6 GB and ~3.8 GB after firmware + kernel reservations
# (GPU carveout, kernel data structures). An integer-GB check
# (`RAM_GB -lt 4`) would reject all 4 GB-spec devices. Phase 6 lab caught
# the equivalent bug at the 8 GB level (8 GB-spec device showed 7 by
# integer math); same lesson applies here.
# 3460032 KB ≈ 3.3 GB — accepts any 4 GB-spec device, rejects 2 GB devices
# (~1.8 GB measured) which would OOM running Qwen 3B alongside the fula
# stack (~3 GB resident for kubo + cluster + go-fula + fxsupport).
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB_DISPLAY=$(awk -v k="$RAM_KB" 'BEGIN { printf "%.1f", k/1024/1024 }')
RAM_MIN_KB=3460032   # ~3.3 GB; accepts any 4 GB-spec device

if [ "$RAM_KB" -lt "$RAM_MIN_KB" ]; then
  echo "Insufficient RAM. At least 4 GB-spec device required (measured: ${RAM_GB_DISPLAY} GB)."
  exit 1
fi

mkdir -p "$INTERNAL_DIR/plugins"
mkdir -p "$BLOX_AI_DIR"

sudo bash ${PLUGIN_EXEC_DIR}/custom/fix_freq_rk3588.sh

mkdir -p /uniondrive/blox-ai
mkdir -p /uniondrive/blox-ai/model

# Copy service file
cp "${PLUGIN_EXEC_DIR}/blox-ai.service" "/etc/systemd/system/"
# Phase 14 — install isolation-mode timer + service. Timer runs the
# self-diagnostic every 6h (plan Layer 3.5); criteria check inside
# isolation_mode.py is the actual gate.
cp "${PLUGIN_EXEC_DIR}/blox-ai-isolation.service" "/etc/systemd/system/" 2>/dev/null || true
cp "${PLUGIN_EXEC_DIR}/blox-ai-isolation.timer" "/etc/systemd/system/" 2>/dev/null || true
cp "${PLUGIN_EXEC_DIR}/isolation_mode.py" "$BLOX_AI_DIR/" 2>/dev/null || true
sync
sleep 1
# Copy docker-compose file

cp "${PLUGIN_EXEC_DIR}/docker-compose.yml" "$BLOX_AI_DIR/"

# .env: preserve device-side customizations across OTAs.
#
# The naive `cp` overwrites every OTA, wiping per-device overrides
# (canary's BLOX_AI_IMAGE_TAG=test, admin's custom BLOX_AI_MODEL_PATH,
# emergency rollback's BLOX_AI_IMAGE_TAG=rollback-2026-05-26). Instead:
# fresh install gets the shipped file; existing devices keep their .env
# and only have NEW keys we ship appended.
#
# Hardening (advisor catches):
#   - Literal key match (no regex injection)
#   - Strict key validation: ^[A-Za-z_][A-Za-z0-9_]*$
#   - CRLF / `export X=y` / leading whitespace normalized before lookup
#     in BOTH shipped and existing files (so device's `export X=y`
#     isn't seen as missing)
#   - `|| [ -n "$key$val" ]` catches last line without trailing newline
#   - Log key names only — never values (some keys hold paths/secrets)
#   - DOCKER_GID NOT in FORCE_UPDATE_KEYS because the dedicated
#     dynamic-detection block below sed-updates it from getent.
FORCE_UPDATE_KEYS=""   # empty by default; add keys here only with cause

if [ ! -f "$BLOX_AI_DIR/.env" ]; then
  cp "${PLUGIN_EXEC_DIR}/.env" "$BLOX_AI_DIR/" 2>/dev/null || true
  echo "[blox-ai install] shipped fresh .env"
elif [ -f "${PLUGIN_EXEC_DIR}/.env" ]; then
  echo "[blox-ai install] preserving existing .env, merging new keys"
  TMPSHIP=$(mktemp)
  TMPDEV=$(mktemp)
  trap 'rm -f "$TMPSHIP" "$TMPDEV"' EXIT
  sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]\+//' \
    "${PLUGIN_EXEC_DIR}/.env" > "$TMPSHIP"
  sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]\+//' \
    "$BLOX_AI_DIR/.env" > "$TMPDEV"

  # `|| [ -n "$key$val" ]` catches files without trailing newline
  # so the last line isn't dropped.
  while IFS='=' read -r key val || [ -n "$key$val" ]; do
    case "$key" in ''|\#*) continue ;; esac
    key=$(printf '%s' "$key" | sed 's/[[:space:]]\+$//')
    # Validate as POSIX shell identifier
    case "$key" in
      [A-Za-z_]*) : ;;
      *) echo "[blox-ai install] skipping invalid key: $key"; continue ;;
    esac
    case "$key" in
      *[!A-Za-z0-9_]*) echo "[blox-ai install] skipping invalid key: $key"; continue ;;
    esac

    for fk in $FORCE_UPDATE_KEYS; do
      if [ "$key" = "$fk" ]; then
        if grep -q "^${key}=" "$TMPDEV"; then
          # Escape val for sed RHS (& | \ are sed-special).
          val_esc=$(printf '%s\n' "$val" | sed -e 's/[&|\\]/\\&/g')
          sed -i "s|^${key}=.*|${key}=${val_esc}|" "$BLOX_AI_DIR/.env"
          echo "[blox-ai install] force-updated key: ${key}"
        else
          [ -s "$BLOX_AI_DIR/.env" ] && \
            [ -n "$(tail -c1 "$BLOX_AI_DIR/.env")" ] && \
            echo "" >> "$BLOX_AI_DIR/.env"
          echo "${key}=${val}" >> "$BLOX_AI_DIR/.env"
          echo "[blox-ai install] appended force-update key: ${key}"
        fi
        continue 2
      fi
    done

    if ! grep -q "^${key}=" "$TMPDEV"; then
      [ -s "$BLOX_AI_DIR/.env" ] && \
        [ -n "$(tail -c1 "$BLOX_AI_DIR/.env")" ] && \
        echo "" >> "$BLOX_AI_DIR/.env"
      echo "${key}=${val}" >> "$BLOX_AI_DIR/.env"
      echo "[blox-ai install] appended new key: ${key}"
    fi
  done < "$TMPSHIP"
fi

# Append host-specific DOCKER_GID so the container can read /var/run/docker.sock.
# The sock is owned by root:<docker_gid> on the host; the container's bloxai
# user (uid 1000) needs to be added to that GID via group_add in compose.
# Detect dynamically because the docker group GID varies by distro install
# path (Armbian/Ubuntu apt install often produces 990, but compose-installed
# docker can pick 999 or 1001). Without this, docker-py inside the container
# gets PermissionError(13) and diag/containers returns running_count=0.
#
# Idempotent: we grep for the key first so reinstalls don't append duplicates,
# and overwrite the line if the host's docker_gid changed (rare, but the
# previous append would otherwise leave a stale value that breaks compose).
DOCKER_GID=$(getent group docker 2>/dev/null | cut -d: -f3 || true)
if [ -n "$DOCKER_GID" ]; then
  # Ensure .env ends with a newline before appending (otherwise the new
  # line concatenates onto the previous one — e.g. the shipped .env from
  # the image not ending in \n produced a malformed line
  # `BLOX_AI_MODEL_PATH=...rkllmDOCKER_GID=990` that broke env parsing).
  if [ -s "$BLOX_AI_DIR/.env" ] && [ -n "$(tail -c1 "$BLOX_AI_DIR/.env")" ]; then
    echo "" >> "$BLOX_AI_DIR/.env"
  fi
  if grep -q '^DOCKER_GID=' "$BLOX_AI_DIR/.env" 2>/dev/null; then
    sed -i "s|^DOCKER_GID=.*|DOCKER_GID=${DOCKER_GID}|" "$BLOX_AI_DIR/.env"
  else
    echo "DOCKER_GID=${DOCKER_GID}" >> "$BLOX_AI_DIR/.env"
  fi
  echo "wired DOCKER_GID=${DOCKER_GID} into ${BLOX_AI_DIR}/.env"
else
  echo "WARNING: could not detect host docker group GID; diag/containers will fail"
fi
# Phase 7: copy runbook + action_whitelist so the docker-compose `./`
# bind-mount source files exist at the WorkingDirectory the systemd unit
# uses ($BLOX_AI_DIR). Without these, the container start would fail
# trying to mount missing files.
cp "${PLUGIN_EXEC_DIR}/runbook.md" "$BLOX_AI_DIR/"
cp "${PLUGIN_EXEC_DIR}/action_whitelist.json" "$BLOX_AI_DIR/"
# Phase 9: API contract schemas — bind-mounted into container at /etc/fula/blox-ai/api/
cp -r "${PLUGIN_EXEC_DIR}/api" "$BLOX_AI_DIR/"
sync
sleep 1

# Ensure /var/log/fula exists for the container's mount target.
# Owner uid:gid 1000:1000 because that's the container's bloxai user
# (Dockerfile pins it) AND the host's pi user — so the container can
# write events.jsonl / ai-actions.jsonl / ai-feedback.jsonl directly.
# Without chown, the dir is root:root and the non-root container hits
# Permission denied on every audit-log write (lab-verified bug).
# Idempotent: a no-op if Phase 1's readiness-check already created it.
mkdir -p /var/log/fula
chown "$PLUGIN_OWNER" /var/log/fula 2>/dev/null || true
chmod 0755 /var/log/fula 2>/dev/null || true
# Chown existing files too — readiness-check.py may have created events.jsonl
# as root via the systemd unit, and that root-owned file blocks the bloxai
# container from appending even though the parent dir is writable.
chown "$PLUGIN_OWNER" /var/log/fula/* 2>/dev/null || true

# Phase 10 defense-in-depth: ensure /etc/fula/blox-ai/security-code +
# /run/fula-ai exist as the RIGHT TYPE before the container starts.
# Primary creation is in fula.sh boot block; this is a backstop in case
# install.sh runs first on a fresh device. Same docker-compose
# single-file-bind footgun handling as fula.sh.
mkdir -p /etc/fula/blox-ai
chmod 0700 /etc/fula/blox-ai 2>/dev/null || true
if [ -e /etc/fula/blox-ai/security-code ] && [ ! -f /etc/fula/blox-ai/security-code ]; then
  rm -rf /etc/fula/blox-ai/security-code 2>/dev/null || true
fi
if [ ! -f /etc/fula/blox-ai/security-code ]; then
  echo "1234" > /etc/fula/blox-ai/security-code 2>/dev/null || true
  chmod 0600 /etc/fula/blox-ai/security-code 2>/dev/null || true
fi
mkdir -p /run/fula-ai
chown "$PLUGIN_OWNER" /run/fula-ai 2>/dev/null || true
chmod 0700 /run/fula-ai 2>/dev/null || true

# Stage the BLE command manifest so the core scanner (local_command_server.py)
# can register ai/* and diag/* commands. Touch the reload flag so the next
# BLE invocation triggers a re-scan without waiting for a daemon restart.
cp "${PLUGIN_EXEC_DIR}/ble_commands.json" "$BLOX_AI_DIR/"

# Plan HTTP v2.2 hotfix (gemini final-review BLOCK): if the admin overrode
# BLOX_AI_PORT, the docker host bind moves to that port and `127.0.0.1:8083`
# is no longer bound — but `ble_commands.json` hardcodes 127.0.0.1:8083 in
# every proxy_url. The host-side BLE proxy (local_command_server.py) would
# then get connection-refused on every ai/* and diag/* command.
#
# Fix: read the device's BLOX_AI_PORT (post-merge) and rewrite the device's
# ble_commands.json proxy_url ports to match. Default 8083 → no-op.
# Source .env: shipped path. Substitutes literal "127.0.0.1:8083" in the
# device-side JSON.
BLOX_AI_PORT_RUNTIME=$(awk -F= '/^BLOX_AI_PORT=/{print $2; exit}' \
  "$BLOX_AI_DIR/.env" 2>/dev/null | tr -d '[:space:]')
case "$BLOX_AI_PORT_RUNTIME" in
  ''|*[!0-9]*) BLOX_AI_PORT_RUNTIME=8083 ;;
esac
if [ "$BLOX_AI_PORT_RUNTIME" != "8083" ]; then
  # Validated above to be numeric, so safe in the sed RHS.
  sed -i "s|http://127\.0\.0\.1:8083/|http://127.0.0.1:${BLOX_AI_PORT_RUNTIME}/|g" \
    "$BLOX_AI_DIR/ble_commands.json"
  echo "[blox-ai install] templated ble_commands.json proxy_url -> 127.0.0.1:${BLOX_AI_PORT_RUNTIME}"
fi

mkdir -p "$COMMANDS_DIR"
touch "$COMMANDS_DIR/.command_plugin_reload" 2>/dev/null || true
sync
sleep 1

# Phase 8: placeholder check hoisted from download_model.sh.
# install.sh runs download_model.sh via `nohup ... &` without redirect, so
# any error from it lands in `nohup.out` and not in fula.sh.log /
# journalctl. If we relied on download_model.sh's own placeholder
# fail-fast, install would "succeed" (service enabled, BLE manifest
# registered) but the model would never download — the worst kind of
# silent failure ("looks installed; every call fails"). Built-in advisor
# catch from Phase 8 post-review.
#
# Source only the two variable assignments from download_model.sh so this
# stays the single source of truth — no string duplication.
eval "$(grep -E '^(DOWNLOAD_URL|MODEL_SHA256)=' "${PLUGIN_EXEC_DIR}/custom/download_model.sh")"
if [[ "$DOWNLOAD_URL" == *"__SET_BEFORE_RELEASE__"* ]] || [[ "$MODEL_SHA256" == *"__SET_BEFORE_RELEASE__"* ]]; then
    echo "ERROR: install.sh refuses to enable the service while download_model.sh"
    echo "       still has unresolved placeholders:"
    echo "         DOWNLOAD_URL=$DOWNLOAD_URL"
    echo "         MODEL_SHA256=$MODEL_SHA256"
    echo "       The sibling functionland/blox-ai PR must populate both before"
    echo "       this release tag is cut. Refusing to leave the device in a"
    echo "       'service enabled, model never downloads' state."
    exit 1
fi

# Reload systemd
systemctl daemon-reload
sync
sleep 1

# Enable the service
systemctl enable blox-ai.service
# Phase 14 — enable + start the isolation timer (the service runs only
# when the timer fires + criteria are met; enabling the unit itself does
# nothing). Skip silently if files missing on a partial install.
if [ -f /etc/systemd/system/blox-ai-isolation.timer ]; then
  systemctl enable blox-ai-isolation.timer 2>/dev/null || true
  systemctl start blox-ai-isolation.timer 2>/dev/null || true
fi

# Run the download and setup script in the background using nohup and &
nohup bash "${PLUGIN_EXEC_DIR}/custom/download_model.sh" &

exit 0
