#!/bin/bash

set -e

# Qwen 3-1.7B RKLLM W8A8 — production model for Blox AI (2026-05-26).
#
# History of model swaps for this device class (7.7 GB RAM, RK3588 NPU):
#   - Originally: Deepseek-LLM 7B (loyal-agent slot)         ~7 GB on disk
#   - Switched to: Qwen 2.5 3B W8A8 (Plan B)                 ~3.7 GB, OOM-killed cold start
#   - Switched to: Qwen 2.5 1.5B Instruct W8A8 (Plan B v2)   ~1.89 GB, stable
#   - Switched to: Qwen 3 1.7B W8A8 (THIS COMMIT)            ~2.0-2.4 GB
#
# Why Qwen 3 1.7B over Qwen 2.5 1.5B:
#   - Qwen 3 1.7B-Base ≈ Qwen 2.5 3B-Base on reasoning per
#     Alibaba's release blog. Meaningful uplift for our specific
#     failure modes (lab-observed: kubernetes hallucination, field-
#     confusion, contradiction-with-own-tool-output, overconfident
#     restart_fula recommendations).
#   - Newer arch + Apache 2.0 (no attribution clause vs Hammer's
#     CC-BY-4.0).
#   - Officially supported by RKLLM toolkit (Qwen3 listed in v1.1.x+).
#   - Hybrid thinking mode: container runtime enables it for the
#     intelligence uplift AND strips <think>...</think> blocks from
#     both SSE output (user UX) AND multi-turn history (so KV doesn't
#     accumulate think-content across turns of the tool-call loop).
#
# Hosted as a single GitHub Release asset on functionland/blox-ai,
# tag `model-qwen-3-1.7b-w8a8-v1`. URL + SHA below are PLACEHOLDERS
# — the publisher must populate them BEFORE cutting a fula-ota
# release tag that bundles this script. The fail-fast guard further
# down rejects any download attempt while placeholders are present
# so a device can never silently pull an unverified blob.
# Two-chunk release. The assembled file is 2,375,021,452 bytes (~2.21 GB);
# GitHub's per-asset cap is 2 GiB, so the .rkllm was split into:
#   - part-aa: 1,992,294,400 bytes (~1.9 GB)
#   - part-ab:   382,727,052 bytes (~365 MB)
# The download loop below fetches both, cat's them into MODEL_FILE in
# array order, then verifies the assembled SHA-256.
CHUNK_URLS=(
    "https://github.com/functionland/blox-ai/releases/download/model-qwen-3-1.7b-w8a8-v1/qwen3-1.7b-rk3588-w8a8.rkllm.part-aa"
    "https://github.com/functionland/blox-ai/releases/download/model-qwen-3-1.7b-w8a8-v1/qwen3-1.7b-rk3588-w8a8.rkllm.part-ab"
)
# First chunk URL kept here for the manifest-helper fallback path (Phase 18).
DOWNLOAD_URL="https://github.com/functionland/blox-ai/releases/download/model-qwen-3-1.7b-w8a8-v1/qwen3-1.7b-rk3588-w8a8.rkllm.part-aa"
# SHA-256 of the ASSEMBLED file (cat part-aa part-ab), NOT of individual chunks.
MODEL_SHA256="8843d4612d42a71605c8d0b38cf9a758a5a53f65a8dde3f17f9d4549b9794e87"

MODEL_DIR="/uniondrive/blox-ai/model"
MODEL_FILE="$MODEL_DIR/qwen3-1.7b-rk3588-w8a8.rkllm"
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
# ~1.9 GB lower bound for the W8A8 Qwen 3 1.7B model. Tight enough to
# catch incomplete downloads, loose enough to tolerate variation in the
# converted-file size (RKLLM toolkit output varies slightly between
# toolkit versions and quantization-config tweaks). The exact released
# size lands once the publisher converts + uploads the .rkllm; if a
# future variant comes in smaller than 1.9 GB this guard fires and we
# either lower it or accept the smaller artifact.
SIZE_LIMIT=1900000000

MODEL_BASENAME="$(basename "$MODEL_FILE")"

# Read the device's BLOX_AI_MODEL_PATH from .env so we can honor admin
# overrides. Parse ONE key rather than sourcing the entire file:
#   - Avoids clobbering script-internal vars (MODEL_DIR, MODEL_SHA256,
#     SERVICE_NAME, etc.) if .env ever gains a key that collides with
#     a script variable (codex final-review catch).
#   - Avoids executing arbitrary shell from .env (treats it as
#     docker-compose env semantics, not shell-source semantics).
# Uses the same normalization rules as install.sh's .env merge:
# strip CRLF, leading whitespace, and `export ` prefix.
DEVICE_ENV_FILE="/home/pi/.internal/plugins/blox-ai/.env"
BLOX_AI_MODEL_PATH_FROM_ENV=""
if [ -r "$DEVICE_ENV_FILE" ]; then
  BLOX_AI_MODEL_PATH_FROM_ENV=$(
    sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]\+//' \
      "$DEVICE_ENV_FILE" 2>/dev/null \
    | awk -F= '/^BLOX_AI_MODEL_PATH=/{ sub(/^BLOX_AI_MODEL_PATH=/, ""); print; exit }'
  )
fi

# ---------------------------------------------------------------------------
# Decommission gate (reversible — see .env BLOX_AI_MODEL_ENABLED).
#
# When BLOX_AI_MODEL_ENABLED != 1 the AI model is intentionally NOT loaded:
# the container still runs and the deterministic YAML troubleshooting trees
# work via the in-container MockBackend fallback, but no ~2.3 GB model is
# downloaded or kept on disk. This frees the RAM and removes the NPU
# inference load that was tripping RK3588 thermal shutdowns.
#
# The model is MOVED (not deleted) into a sibling model-disabled/ dir so
# re-enabling needs no 2.3 GB CDN re-download. The move matters because the
# container's find_model_path() scans MODEL_DIR for ANY *.rkllm — a disabled
# model must therefore leave the scanned dir entirely. model-disabled/ is a
# sibling of MODEL_DIR on the same persistent /uniondrive mount, so it
# survives reboots and OTA (OTA ships only host scripts, never /uniondrive).
#
# Reversal: ship BLOX_AI_MODEL_ENABLED=1 (a FORCE_UPDATE_KEY, so the OTA
# re-applies it fleet-wide). The enabled branch below restores the model from
# model-disabled/ when present, else falls through to the normal download.
# ---------------------------------------------------------------------------
BLOX_AI_MODEL_ENABLED_FROM_ENV=""
if [ -r "$DEVICE_ENV_FILE" ]; then
  BLOX_AI_MODEL_ENABLED_FROM_ENV=$(
    sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]\+//' \
      "$DEVICE_ENV_FILE" 2>/dev/null \
    | awk -F= '/^BLOX_AI_MODEL_ENABLED=/{ sub(/^BLOX_AI_MODEL_ENABLED=/, ""); print; exit }'
  )
fi
BLOX_AI_MODEL_ENABLED_FROM_ENV=$(printf '%s' "$BLOX_AI_MODEL_ENABLED_FROM_ENV" | tr -d '[:space:]')
DISABLED_DIR="$(dirname "$MODEL_DIR")/model-disabled"

if [ "$BLOX_AI_MODEL_ENABLED_FROM_ENV" != "1" ]; then
  echo "BLOX_AI_MODEL_ENABLED='$BLOX_AI_MODEL_ENABLED_FROM_ENV' (!= 1) — AI model decommissioned."
  echo "Moving any on-disk model aside to model-disabled/ and starting trees-only."
  mkdir -p "$DISABLED_DIR" 2>/dev/null || true
  shopt -s nullglob
  for f in "$MODEL_DIR"/*.rkllm; do
    echo "  $(basename "$f") -> model-disabled/ (reversible; no re-download on enable)"
    mv -f "$f" "$DISABLED_DIR"/ 2>/dev/null || rm -f "$f" 2>/dev/null || true
  done
  shopt -u nullglob
  # Drop chunk/partial leftovers so nothing can be re-assembled into a model.
  rm -f "$MODEL_DIR"/chunk-* "$MODEL_DIR"/"$MODEL_BASENAME".part-* 2>/dev/null || true
  systemctl restart "$SERVICE_NAME"
  echo "Blox AI restarted in trees-only mode (MockBackend; no model loaded)."
  exit 0
fi

# Enabled (BLOX_AI_MODEL_ENABLED=1): if the model was previously moved aside,
# restore it instead of re-downloading 2.3 GB from the CDN.
if [ ! -f "$MODEL_FILE" ] && [ -f "$DISABLED_DIR/$MODEL_BASENAME" ]; then
  echo "BLOX_AI_MODEL_ENABLED=1 — restoring model from model-disabled/ (no re-download)."
  mkdir -p "$MODEL_DIR" 2>/dev/null || true
  mv -f "$DISABLED_DIR/$MODEL_BASENAME" "$MODEL_FILE" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Stale-model cleanup (3B and old 1.5B).
#
# Devices that previously installed earlier Blox AI models carry stale
# .rkllm files on disk:
#   - qwen2.5-3b-instruct-rk3588-w8a8.rkllm     (~3.7 GB) — Plan B v1
#   - qwen2.5-1.5b-instruct-rk3588-w8a8.rkllm   (~1.89 GB) — Plan B v2
# Both are unused by Qwen 3 1.7B. Free them up during install, BUT:
#   - Don't delete a file the admin pinned via BLOX_AI_MODEL_PATH
#     (deliberate config — they may be canary-testing the old model)
#   - Pre-download cleanup when disk is tight (gemini v2 catch:
#     3.7 GB old + 1.89 GB old-1.5 + 2.4 GB new exceeds free space on
#     constrained boards — must clean before fetching the new one)
#   - Post-verify cleanup when disk is fine (preserves the working old
#     file until the new download is SHA-verified — rollback safety)
# ---------------------------------------------------------------------------
OLD_3B_PATH="$MODEL_DIR/qwen2.5-3b-instruct-rk3588-w8a8.rkllm"
OLD_1_5B_PATH="$MODEL_DIR/qwen2.5-1.5b-instruct-rk3588-w8a8.rkllm"
SAFE_TO_CLEAN_OLD_3B=0
SAFE_TO_CLEAN_OLD_1_5B=0

# Translate BLOX_AI_MODEL_PATH from container-side to host-side for the
# guard comparison (codex final-review BLOCKING catch).
# docker-compose mounts the host's /uniondrive/blox-ai/ as the
# container's /uniondrive/. So a value like
# /uniondrive/model/foo.rkllm in .env actually points at the host path
# /uniondrive/blox-ai/model/foo.rkllm. Without this translation, the
# guard always evaluates "different" (container path != host path) and
# the admin-pinned file gets deleted anyway — defeating the entire
# purpose of the guard.
container_path_to_host_path() {
  local p="$1"
  case "$p" in
    /uniondrive/blox-ai/*) printf '%s' "$p" ;;
    /uniondrive/*)         printf '/uniondrive/blox-ai/%s' "${p#/uniondrive/}" ;;
    *)                     printf '%s' "$p" ;;
  esac
}

# Resolve BLOX_AI_MODEL_PATH from .env once for both guards.
CONFIGURED_PATH=""
if [ -n "$BLOX_AI_MODEL_PATH_FROM_ENV" ]; then
  host_side=$(container_path_to_host_path "$BLOX_AI_MODEL_PATH_FROM_ENV")
  CONFIGURED_PATH=$(cd "$MODEL_DIR" 2>/dev/null && \
    readlink -f "$host_side" 2>/dev/null || \
    echo "$host_side")
fi

if [ -f "$OLD_3B_PATH" ]; then
  OLD_RESOLVED=$(readlink -f "$OLD_3B_PATH" 2>/dev/null || echo "$OLD_3B_PATH")
  if [ "$CONFIGURED_PATH" != "$OLD_RESOLVED" ]; then
    SAFE_TO_CLEAN_OLD_3B=1
  else
    echo "BLOX_AI_MODEL_PATH points at the old 3B file; keeping it."
  fi
fi

if [ -f "$OLD_1_5B_PATH" ]; then
  OLD_RESOLVED=$(readlink -f "$OLD_1_5B_PATH" 2>/dev/null || echo "$OLD_1_5B_PATH")
  if [ "$CONFIGURED_PATH" != "$OLD_RESOLVED" ]; then
    SAFE_TO_CLEAN_OLD_1_5B=1
  else
    echo "BLOX_AI_MODEL_PATH points at the old 1.5B file; keeping it."
  fi
fi

# Phase A — pre-download cleanup when disk is tight.
# Threshold: enough free for the new model + 1 GB safety margin.
NEW_MODEL_SIZE_BYTES=2400000000   # ~2.4 GB for Qwen 3 1.7B W8A8 (estimated upper)
SAFETY_MARGIN_BYTES=1073741824    # 1 GB
REQUIRED_BYTES=$((NEW_MODEL_SIZE_BYTES + SAFETY_MARGIN_BYTES))
FREE_BYTES=$(df --output=avail -B1 "$MODEL_DIR" 2>/dev/null | tail -1 | tr -d ' ')
# df may print non-numeric on busybox; guard the int compare
case "$FREE_BYTES" in
  ''|*[!0-9]*) FREE_BYTES=0 ;;
esac

reclaim_under_pressure() {
  # Recompute free space after a deletion and update FREE_BYTES.
  FREE_BYTES=$(df --output=avail -B1 "$MODEL_DIR" 2>/dev/null | tail -1 | tr -d ' ')
  case "$FREE_BYTES" in
    ''|*[!0-9]*) FREE_BYTES=0 ;;
  esac
}

# Clean the larger one first if both are present (more reclaim per delete).
if [ "$FREE_BYTES" -lt "$REQUIRED_BYTES" ] && [ "$SAFE_TO_CLEAN_OLD_3B" = "1" ]; then
  echo "Disk tight (free=$FREE_BYTES, need=$REQUIRED_BYTES); pre-cleaning old 3B."
  rm -f "$OLD_3B_PATH"
  reclaim_under_pressure
fi
if [ "$FREE_BYTES" -lt "$REQUIRED_BYTES" ] && [ "$SAFE_TO_CLEAN_OLD_1_5B" = "1" ]; then
  echo "Disk tight (free=$FREE_BYTES, need=$REQUIRED_BYTES); pre-cleaning old 1.5B."
  rm -f "$OLD_1_5B_PATH"
  reclaim_under_pressure
fi
if [ "$FREE_BYTES" -lt "$REQUIRED_BYTES" ]; then
  echo "ERROR: still under threshold (free=$FREE_BYTES, need=$REQUIRED_BYTES) after pre-cleanup."
  echo "       Refusing to attempt a download that will run out of space."
  exit 1
fi

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
        # Post-verify cleanup of stale models — guard prevents touching
        # admin-pinned configurations.
        if [ "$SAFE_TO_CLEAN_OLD_3B" = "1" ] && [ -f "$OLD_3B_PATH" ]; then
            echo "Removing old 3B model file (~3.7 GB) — cached Qwen3 SHA verified."
            rm -f "$OLD_3B_PATH" 2>/dev/null || true
        fi
        if [ "$SAFE_TO_CLEAN_OLD_1_5B" = "1" ] && [ -f "$OLD_1_5B_PATH" ]; then
            echo "Removing old 1.5B model file (~1.89 GB) — cached Qwen3 SHA verified."
            rm -f "$OLD_1_5B_PATH" 2>/dev/null || true
        fi
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
    # Clean chunk leftovers from prior cycles. Two patterns covered:
    #   - chunk-*       (legacy naming, kept for backwards compat)
    #   - <MODEL>.part-* (current naming — split -b produces these for
    #     2-chunk models that exceed GitHub's 2 GiB per-asset cap)
    rm -f "$MODEL_DIR"/chunk-* "$MODEL_DIR"/"$MODEL_BASENAME".part-* "$MODEL_FILE"

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
        # Single-chunk shortcut + bug fix: when CHUNK_URLS has one entry
        # and the chunk's basename equals MODEL_FILE's basename, wget
        # already wrote the model directly to MODEL_FILE. The cat step
        # below would be `cat MODEL_FILE > MODEL_FILE`, which the shell
        # opens for write (truncating to 0) BEFORE cat starts reading.
        # Result: every download succeeds, then the file is wiped to 0
        # bytes, the "Assembled file too small" branch fires, the file
        # is deleted, and we retry forever. Lab-verified bug.
        SINGLE_CHUNK_IS_MODEL_FILE=false
        if [ "${#CHUNK_PATHS[@]}" -eq 1 ] && [ "${CHUNK_PATHS[0]}" = "$MODEL_FILE" ]; then
            SINGLE_CHUNK_IS_MODEL_FILE=true
        fi
        # Concatenate in URL order. cat handles arbitrary chunk count;
        # explicit "${CHUNK_PATHS[@]}" expansion avoids glob ordering
        # surprises if extra chunk-* files somehow exist in the dir.
        if $SINGLE_CHUNK_IS_MODEL_FILE || cat "${CHUNK_PATHS[@]}" > "$MODEL_FILE"; then
            FILE_SIZE=$(stat -c%s "$MODEL_FILE")
            if [ "$FILE_SIZE" -ge "$SIZE_LIMIT" ]; then
                echo "File downloaded; size OK. Verifying SHA-256..."
                if verify_sha "$MODEL_FILE" "$MODEL_SHA256"; then
                    echo "SHA verified."
                    # Free disk: drop chunk files now that the assembled
                    # file is verified. Chunks are no longer needed.
                    # Two patterns: legacy `chunk-*` + current `<model>.part-*`.
                    rm -f "$MODEL_DIR"/chunk-* "$MODEL_DIR"/"$MODEL_BASENAME".part-*
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
    rm -f "$MODEL_DIR"/chunk-* "$MODEL_DIR"/"$MODEL_BASENAME".part-*
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

# Post-verify cleanup of stale models. Guards prevent touching files the
# admin pinned via BLOX_AI_MODEL_PATH (deliberate config). If pre-download
# cleanup already removed them (tight-disk path), these are no-ops.
if [ "$SAFE_TO_CLEAN_OLD_3B" = "1" ] && [ -f "$OLD_3B_PATH" ]; then
    echo "Removing old 3B model file (~3.7 GB) — new Qwen3 SHA verified."
    rm -f "$OLD_3B_PATH" 2>/dev/null || true
fi
if [ "$SAFE_TO_CLEAN_OLD_1_5B" = "1" ] && [ -f "$OLD_1_5B_PATH" ]; then
    echo "Removing old 1.5B model file (~1.89 GB) — new Qwen3 SHA verified."
    rm -f "$OLD_1_5B_PATH" 2>/dev/null || true
fi

echo "Starting $SERVICE_NAME..."
systemctl restart "$SERVICE_NAME"
echo "Blox AI installed successfully."

exit 0
