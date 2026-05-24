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
sync
sleep 1
# Copy docker-compose file

cp "${PLUGIN_EXEC_DIR}/docker-compose.yml" "$BLOX_AI_DIR/"
cp "${PLUGIN_EXEC_DIR}/.env" "$BLOX_AI_DIR/" 2>/dev/null || true
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

# Ensure /var/log/fula exists for the container's mount target. Conservative
# perms per Codex post-review (0775 not 0777 — only root + container's gid
# needs write). Idempotent: a no-op if Phase 1's readiness-check already
# created it via os.makedirs.
mkdir -p /var/log/fula
chmod 0775 /var/log/fula 2>/dev/null || true

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
chmod 0700 /run/fula-ai 2>/dev/null || true

# Stage the BLE command manifest so the core scanner (local_command_server.py)
# can register ai/* and diag/* commands. Touch the reload flag so the next
# BLE invocation triggers a re-scan without waiting for a daemon restart.
cp "${PLUGIN_EXEC_DIR}/ble_commands.json" "$BLOX_AI_DIR/"
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

# Run the download and setup script in the background using nohup and &
nohup bash "${PLUGIN_EXEC_DIR}/custom/download_model.sh" &

exit 0
