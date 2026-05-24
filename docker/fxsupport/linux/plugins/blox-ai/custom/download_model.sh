#!/bin/bash

set -e

# Phase 8: Qwen 2.5-3B-Instruct RKLLM W8A8.
#
# DOWNLOAD_URL and MODEL_SHA256 are PLACEHOLDERS until the sibling
# functionland/blox-ai PR quantizes the model and uploads to CDN. The
# placeholder guard below makes install fail-fast if either is still a
# placeholder — CI can also grep for __SET_BEFORE_RELEASE__ to catch a
# bad merge.
#
# When the model lands:
#   1. Compute sha256 of the published file:  sha256sum qwen2.5-3b-instruct-rk3588-w8a8.rkllm
#   2. Replace MODEL_SHA256 below with the result.
#   3. Confirm DOWNLOAD_URL matches the CDN-published URL.
#   4. Bump info.json version.
DOWNLOAD_URL="https://functionyard.fx.land/qwen2.5-3b-instruct-rk3588-w8a8.rkllm"
MODEL_SHA256="__SET_BEFORE_RELEASE__"

MODEL_DIR="/uniondrive/blox-ai/model"
MODEL_FILE="$MODEL_DIR/qwen2.5-3b-instruct-rk3588-w8a8.rkllm"
LOG_FILE="$MODEL_DIR/wget.log"
SERVICE_NAME="blox-ai.service"
# ~2.5 GB lower bound for the W8A8 Qwen 3B model. Actual file is ~2.8-3.1 GB
# depending on quantization options chosen at conversion. Tight enough to
# catch incomplete downloads, loose enough to tolerate small variations.
SIZE_LIMIT=2500000000

MODEL_BASENAME="$(basename "$MODEL_FILE")"

# ---------------------------------------------------------------------------
# Placeholder fail-fast (Codex post-review HIGH: both URL and SHA, not just SHA)
# ---------------------------------------------------------------------------
if [[ "$DOWNLOAD_URL" == *"__SET_BEFORE_RELEASE__"* ]] || [[ "$MODEL_SHA256" == *"__SET_BEFORE_RELEASE__"* ]]; then
    echo "ERROR: download_model.sh has unresolved placeholders for model URL or SHA-256."
    echo "       DOWNLOAD_URL=$DOWNLOAD_URL"
    echo "       MODEL_SHA256=$MODEL_SHA256"
    echo "       The sibling functionland/blox-ai PR must populate both before this"
    echo "       fula-ota release tag is cut. Refusing to download an unverified model."
    exit 1
fi

# Create necessary directories
mkdir -p "$MODEL_DIR"

# ---------------------------------------------------------------------------
# Verify any already-present cache file. Per Codex post-review HIGH: the
# previous "exists + size >= limit" logic let a corrupt or malicious cached
# file survive forever. SHA check on cache is the right boundary.
# ---------------------------------------------------------------------------
verify_sha() {
    local f="$1"
    local expected="$2"
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "ERROR: sha256sum not available; cannot verify model integrity."
        return 2
    fi
    local actual
    actual=$(sha256sum "$f" | awk '{print $1}')
    if [ "$actual" = "$expected" ]; then
        return 0
    fi
    echo "SHA mismatch for $f"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    return 1
}

if [ -f "$MODEL_FILE" ]; then
    FILE_SIZE=$(stat -c%s "$MODEL_FILE")
    if [ "$FILE_SIZE" -lt "$SIZE_LIMIT" ]; then
        echo "Cached model file exists but is smaller than $SIZE_LIMIT bytes. Deleting it..."
        rm -f "$MODEL_FILE"
    elif verify_sha "$MODEL_FILE" "$MODEL_SHA256"; then
        echo "Cached model file exists, size OK, SHA verified. Starting service."
        # Free disk: drop any prior Deepseek 7B model now that Qwen is verified.
        # User override of Codex/Gemini "preserve" recommendation — practical
        # disk reclamation matters more than the theoretical rollback path
        # that doesn't actually exist until Phase 18.
        rm -f "$MODEL_DIR"/deepseek-*.rkllm 2>/dev/null || true
        systemctl restart "$SERVICE_NAME"
        echo "Blox AI started from cached model."
        exit 0
    else
        echo "Cached model file failed SHA verification. Deleting and re-downloading."
        rm -f "$MODEL_FILE"
    fi
else
    echo "Model file does not exist."
fi

# Start downloading in the background
nohup wget -b -N -P "$MODEL_DIR" "$DOWNLOAD_URL" &> "$LOG_FILE" &
WGET_PID=$!

# Wait for the file to finish downloading. Per Codex post-review: build the
# pgrep pattern from MODEL_BASENAME so swapping models doesn't leave a
# stale grep pattern referencing the old model name.
echo "Waiting for the file to be fully downloaded..."
RETRY_COUNT=0
while true; do
    if pgrep -f "wget.*${MODEL_BASENAME}" > /dev/null; then
        echo "Download in progress..."
        sleep 10
    else
        FILE_SIZE=0
        if [ -f "$MODEL_FILE" ]; then
            FILE_SIZE=$(stat -c%s "$MODEL_FILE")
        fi
        if [ -f "$MODEL_FILE" ] && [ "$FILE_SIZE" -ge "$SIZE_LIMIT" ]; then
            echo "File downloaded; size OK. Verifying SHA-256..."
            if verify_sha "$MODEL_FILE" "$MODEL_SHA256"; then
                echo "SHA verified."
                break
            else
                # User override of the .corrupt.<ts> quarantine pattern:
                # a corrupt .rkllm blob has no forensic value (it's an
                # opaque tensor file; we can't introspect it). Just
                # delete and free the disk. Next install re-downloads.
                echo "SHA mismatch after download — refusing to start service."
                echo "Deleting bad file ($MODEL_FILE); next install will re-download."
                rm -f "$MODEL_FILE"
                exit 1
            fi
        else
            echo "Download failed or incomplete."
            if [ $RETRY_COUNT -lt 3 ]; then
                echo "Retrying..."
                kill "$WGET_PID" 2>/dev/null
                nohup wget -b -N -P "$MODEL_DIR" "$DOWNLOAD_URL" &> "$LOG_FILE" &
                WGET_PID=$!
                RETRY_COUNT=$((RETRY_COUNT + 1))
            else
                echo "Max retries reached. Exiting."
                exit 1
            fi
        fi
    fi
done

# User override of Codex/Gemini "preserve" stance: free the ~7 GB of
# disk the prior Deepseek 7B model was using. Only happens AFTER the new
# Qwen download succeeded + SHA verified (the if/else above), so a
# failed Qwen download never deletes the working Deepseek file.
# Most devices won't have this file (loyal-agent slot was unused for
# most users); the rm is a no-op there. Glob is constrained to the
# specific model dir.
rm -f "$MODEL_DIR"/deepseek-*.rkllm 2>/dev/null || true

echo "Starting $SERVICE_NAME..."
systemctl restart "$SERVICE_NAME"
echo "Blox AI installed successfully."

exit 0
