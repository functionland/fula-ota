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

MODEL_DIR="/uniondrive/blox-ai/model"
MODEL_FILE="$MODEL_DIR/qwen2.5-1.5b-instruct-rk3588-w8a8.rkllm"
# ~1.7 GB lower bound for Qwen 1.5B W8A8 (file is ~1.89 GB). Was 2.5 GB
# when we shipped the 3B model; bumped down with the 1.5B swap so this
# value stays consistent with download_model.sh's SIZE_LIMIT (the
# test_size_limit_consistent_between_start_and_download test enforces).
SIZE_LIMIT=1700000000

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
