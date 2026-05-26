#!/bin/bash

set -e

# Phase 8: Qwen 2.5-3B-Instruct RKLLM W8A8 — base model for Blox AI v1.
#
# Hosted as a GitHub Release on functionland/blox-ai, tag
# `model-qwen-2.5-3b-w8a8-v1`. The 3.74 GB model is split into two
# chunks because GitHub Release assets are capped at 2 GiB per file.
# Chunks are concatenated in array order (chunk-aa, chunk-ab) then
# SHA-verified as a single file against MODEL_SHA256 below.
#
# DOWNLOAD_URL stays as the FIRST chunk URL so the install.sh
# placeholder-check + Phase 18 manifest-helper fallback path (which
# expects a single URL string) still works.
CHUNK_URLS=(
    "https://github.com/functionland/blox-ai/releases/download/model-qwen-2.5-3b-w8a8-v1/chunk-aa"
    "https://github.com/functionland/blox-ai/releases/download/model-qwen-2.5-3b-w8a8-v1/chunk-ab"
)
DOWNLOAD_URL="https://github.com/functionland/blox-ai/releases/download/model-qwen-2.5-3b-w8a8-v1/chunk-aa"
MODEL_SHA256="b7cf8b1c10140ac380535a52602d2ecc862aa96a84e3cf5d8267b6e54cca2607"

MODEL_DIR="/uniondrive/blox-ai/model"
MODEL_FILE="$MODEL_DIR/qwen2.5-3b-instruct-rk3588-w8a8.rkllm"
LOG_FILE="$MODEL_DIR/wget.log"
SERVICE_NAME="blox-ai.service"

# ---------------------------------------------------------------------------
# Phase 18: manifest-driven URL + SHA override (rollback path).
#
# If /etc/fula/ai-manifest.json exists and parses, model_manifest.py picks
# either the manifest's `current` or `rollback` entry (based on
# rollback_required) and prints shell-eval'able overrides. On missing or
# malformed manifest the helper falls back to the hardcoded values above,
# so this block is safe to keep enabled even on devices that have never
# received a manifest.
#
# To trigger a fleet rollback: publish a new ai-manifest.json with
# rollback_required: true. Devices pick it up on the next plugin restart.
# To verify the active source on a device: look for "MANIFEST_SOURCE=" in
# the install.log.
# ---------------------------------------------------------------------------
PLUGIN_DIR_FOR_MANIFEST="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_HELPER="$PLUGIN_DIR_FOR_MANIFEST/model_manifest.py"
if [ -r "$MANIFEST_HELPER" ] && command -v python3 >/dev/null 2>&1; then
    if MANIFEST_EVAL=$(python3 "$MANIFEST_HELPER" \
            --fallback-url "$DOWNLOAD_URL" \
            --fallback-sha256 "$MODEL_SHA256" 2>/dev/null); then
        eval "$MANIFEST_EVAL"
        DOWNLOAD_URL="$MODEL_URL"
        # Only override CHUNK_URLS when a REAL manifest is active. The
        # "fallback" source means the helper couldn't find / parse an
        # ai-manifest.json and is echoing back our own hardcoded
        # --fallback-url — which is just the FIRST chunk's URL, NOT a
        # full-file URL. Clobbering CHUNK_URLS with that would silently
        # downgrade to a 1-chunk download (the bug this guard fixes:
        # install on a device with no published manifest was only
        # fetching chunk-aa, ~1.99 GiB, then refusing to assemble
        # because the result was smaller than SIZE_LIMIT).
        #
        # When MANIFEST_SOURCE is `manifest_current` or `manifest_rollback`,
        # MODEL_URL is the canonical single-file URL the publisher chose;
        # CHUNK_URLS collapses to that one entry and the assembly path
        # below cats the single file before SHA-verifying. When/if the
        # manifest schema bumps to carry chunk arrays, replace this
        # single-element with the parsed array.
        if [ "${MANIFEST_SOURCE:-fallback}" != "fallback" ]; then
            CHUNK_URLS=("$MODEL_URL")
        fi
        # MODEL_SHA256, MODEL_VERSION, MODEL_SIZE_BYTES, MANIFEST_SOURCE
        # are now set from the helper's output.
        echo "Phase 18 manifest source: ${MANIFEST_SOURCE:-unknown}"
        echo "  active model_version: ${MODEL_VERSION:-unknown}"
        if [ "${MANIFEST_SOURCE:-}" = "manifest_rollback" ]; then
            echo "  ROLLBACK ACTIVE — manifest signalled rollback_required=true"
        fi
    fi
fi
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

# ---------------------------------------------------------------------------
# Download all chunks sequentially, assemble, then SHA-verify the assembled
# file. Per-chunk SHAs aren't enforced — the assembled-file SHA below is the
# single integrity boundary, so a corrupted chunk shows up as an assembled-
# file mismatch and triggers the same delete+retry cycle as a corrupted
# single-file download.
# ---------------------------------------------------------------------------
echo "Downloading ${#CHUNK_URLS[@]} chunk(s)..."
RETRY_COUNT=0
while true; do
    # Clean any partial state from a prior failed cycle. Done at the top
    # of every cycle so a fresh attempt always starts from a known state.
    rm -f "$MODEL_DIR"/chunk-* "$MODEL_FILE"

    DOWNLOAD_OK=true
    CHUNK_PATHS=()
    for url in "${CHUNK_URLS[@]}"; do
        chunk_path="$MODEL_DIR/$(basename "$url")"
        CHUNK_PATHS+=("$chunk_path")
        # --tries: built-in wget retry for transient connection drops.
        # --waitretry: backoff between retries.
        # --timeout: per-connection timeout (read/connect).
        # No --continue: each cycle restarts cleanly per the rm above.
        if ! wget --tries=3 --waitretry=10 --timeout=60 \
                  -O "$chunk_path" "$url" >> "$LOG_FILE" 2>&1; then
            echo "Chunk download failed: $url"
            DOWNLOAD_OK=false
            break
        fi
    done

    if $DOWNLOAD_OK; then
        # Concatenate in URL order. cat handles arbitrary chunk count;
        # explicit "${CHUNK_PATHS[@]}" expansion avoids glob ordering
        # surprises if extra chunk-* files somehow exist in the dir.
        if cat "${CHUNK_PATHS[@]}" > "$MODEL_FILE"; then
            FILE_SIZE=$(stat -c%s "$MODEL_FILE")
            if [ "$FILE_SIZE" -ge "$SIZE_LIMIT" ]; then
                echo "File downloaded; size OK. Verifying SHA-256..."
                if verify_sha "$MODEL_FILE" "$MODEL_SHA256"; then
                    echo "SHA verified."
                    # Free disk: drop chunk files now that the assembled
                    # file is verified. Chunks are no longer needed.
                    rm -f "$MODEL_DIR"/chunk-*
                    break
                fi
                # User override of the .corrupt.<ts> quarantine pattern:
                # a corrupt .rkllm blob has no forensic value (it's an
                # opaque tensor file; we can't introspect it). Just
                # delete and free the disk. Next cycle re-downloads.
                echo "SHA mismatch after download — refusing to start service."
            else
                echo "Assembled file too small ($FILE_SIZE bytes < $SIZE_LIMIT)"
            fi
        else
            echo "Failed to assemble chunks into $MODEL_FILE"
        fi
    fi

    # This cycle failed; clean up + retry the FULL chunk set.
    echo "Deleting bad files; will retry full download."
    rm -f "$MODEL_DIR"/chunk-*
    rm -f "$MODEL_FILE"
    if [ $RETRY_COUNT -lt 3 ]; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "Retrying (attempt $RETRY_COUNT/3)..."
    else
        echo "Max retries reached. Exiting."
        exit 1
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
