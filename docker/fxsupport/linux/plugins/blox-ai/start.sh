#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! systemctl list-unit-files | grep -q blox-ai.service; then
    echo "Blox AI service is not installed. Please install it first."
    exit 1
fi

if systemctl is-active --quiet blox-ai.service; then
    echo "Blox AI service is already running."
    exit 0
fi

# ---------------------------------------------------------------------------
# Decommission bypass (reversible — see .env BLOX_AI_MODEL_ENABLED).
#
# When BLOX_AI_MODEL_ENABLED != 1 the model is intentionally absent (see
# custom/download_model.sh, which moves it aside to model-disabled/). The
# container still serves the deterministic YAML trees via its in-container
# MockBackend fallback, so start the service directly and skip the
# model-presence/SHA gate below. Without this, update.sh -> start.sh would
# hit that gate, exit WITHOUT starting, and leave the device with no trees.
# ---------------------------------------------------------------------------
DEVICE_ENV_FILE="/home/pi/.internal/plugins/blox-ai/.env"
BLOX_AI_MODEL_ENABLED_FROM_ENV=""
if [ -r "$DEVICE_ENV_FILE" ]; then
  BLOX_AI_MODEL_ENABLED_FROM_ENV=$(
    sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]\+//' \
      "$DEVICE_ENV_FILE" 2>/dev/null \
    | awk -F= '/^BLOX_AI_MODEL_ENABLED=/{ sub(/^BLOX_AI_MODEL_ENABLED=/, ""); print; exit }'
  )
fi
BLOX_AI_MODEL_ENABLED_FROM_ENV=$(printf '%s' "$BLOX_AI_MODEL_ENABLED_FROM_ENV" | tr -d '[:space:]')
if [ "$BLOX_AI_MODEL_ENABLED_FROM_ENV" != "1" ]; then
  echo "BLOX_AI_MODEL_ENABLED != 1 — starting Blox AI in trees-only mode (no model)."
  systemctl start blox-ai.service
  echo "Blox AI started (trees-only)."
  exit 0
fi

MODEL_DIR="/uniondrive/blox-ai/model"
MODEL_FILE="$MODEL_DIR/qwen3-1.7b-rk3588-w8a8.rkllm"
# ~1.9 GB lower bound for Qwen 3 1.7B W8A8 (estimated 2.0-2.4 GB on
# disk). Kept consistent with download_model.sh's SIZE_LIMIT — the
# test_size_limit_consistent_between_start_and_download test enforces
# the pairing. Update both sides together when the converted file's
# actual size lands.
SIZE_LIMIT=1900000000

# Phase 8: SHA verification is duplicated here (sourced from
# download_model.sh) per Codex post-review HIGH — manual `start.sh`
# invocation can boot a corrupt same-size model if start.sh trusts
# size-only validation. Pull MODEL_SHA256 from the same source of truth
# as download_model.sh so the two scripts never drift.
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOAD_SH="$PLUGIN_DIR/custom/download_model.sh"
if [ -r "$DOWNLOAD_SH" ]; then
  eval "$(grep -E '^MODEL_SHA256=' "$DOWNLOAD_SH")"
else
  echo "Warning: cannot read $DOWNLOAD_SH for SHA reference; skipping SHA verification."
  MODEL_SHA256=""
fi

echo "Checking for the file to be fully downloaded..."

FILE_SIZE=0
if [ -f "$MODEL_FILE" ]; then
  FILE_SIZE=$(stat -c%s "$MODEL_FILE")
fi

if [ ! -f "$MODEL_FILE" ] || [ "$FILE_SIZE" -lt "$SIZE_LIMIT" ]; then
  echo "Download failed or incomplete."
  exit 0
fi

if [ -n "$MODEL_SHA256" ] && [[ "$MODEL_SHA256" != *"__SET_BEFORE_RELEASE__"* ]]; then
  ACTUAL_SHA=$(sha256sum "$MODEL_FILE" | awk '{print $1}')
  if [ "$ACTUAL_SHA" != "$MODEL_SHA256" ]; then
    echo "Model file SHA mismatch — refusing to start service."
    echo "  expected: $MODEL_SHA256"
    echo "  actual:   $ACTUAL_SHA"
    echo "  file:     $MODEL_FILE"
    exit 1
  fi
  echo "File present, size OK, SHA verified."
else
  echo "File present, size OK. (SHA reference unavailable — skipping verify.)"
fi

systemctl start blox-ai.service
echo "Blox AI started successfully."
