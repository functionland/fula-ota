#!/bin/bash

set -e

# Define variables
DOWNLOAD_URL="https://functionyard.fx.land/deepseek-llm-7b-chat-rk3588-w8a8_g256-opt-1-hybrid-ratio-0.5.rkllm"
MODEL_DIR="/uniondrive/loyal-agent/model"
MODEL_FILE="$MODEL_DIR/deepseek-llm-7b-chat-rk3588-w8a8_g256-opt-1-hybrid-ratio-0.5.rkllm"
LOG_FILE="$MODEL_DIR/wget.log"
SIZE_LIMIT=7500000000  # Size in bytes (7.5 GB)
STATUS_FILE="/home/pi/.internal/plugins/loyal-agent/status.txt"

# Create necessary directories
mkdir -p "$MODEL_DIR"

# Check if the model file exists
if [ -f "$MODEL_FILE" ]; then
    # Get the file size in bytes
    FILE_SIZE=$(stat -c%s "$MODEL_FILE")

    # Compare the file size with the size limit
    if [ "$FILE_SIZE" -lt "$SIZE_LIMIT" ]; then
        echo "Model file exists but is smaller than $SIZE_LIMIT bytes. Deleting it..."
        rm -f "$MODEL_FILE"
    else
        echo "Model file exists and meets the size requirement."
    fi
else
    echo "Model file does not exist."
fi

# Start downloading in the background
nohup wget -b -N -P "$MODEL_DIR" "$DOWNLOAD_URL" &> "$LOG_FILE" &
WGET_PID=$!

# Wait for the file to finish downloading
echo "Waiting for the file to be fully downloaded..."
RETRY_COUNT=0
while true; do
    # Check if wget is still running
    if pgrep -f "wget.*deepseek-llm-7b-chat-rk3588-w8a8_g256-opt-1-hybrid-ratio-0.5.rkllm" > /dev/null; then
        echo "Download in progress..."
        # Report download progress to status file
        if [ -f "$MODEL_FILE" ]; then
            FILE_SIZE=$(stat -c%s "$MODEL_FILE" 2>/dev/null || echo 0)
            PERCENT=$((FILE_SIZE * 100 / SIZE_LIMIT))
            echo -n "Downloading ${PERCENT}%" > "$STATUS_FILE"
        fi
        sleep 10 # Wait for 10 seconds before checking again
    else
        FILE_SIZE=0
        if [ -f "$MODEL_FILE" ]; then
            FILE_SIZE=$(stat -c%s "$MODEL_FILE")
        fi
        # Check if the file exists and is fully downloaded
        if [ -f "$MODEL_FILE" ] && [ "$FILE_SIZE" -ge "$SIZE_LIMIT" ]; then
            echo "File downloaded successfully."
            # Model integrity verification
            EXPECTED_SHA256=""
            INFO_FILE="/usr/bin/fula/plugins/loyal-agent/info.json"
            if [ -f "$INFO_FILE" ] && command -v python3 &>/dev/null; then
                EXPECTED_SHA256=$(python3 -c "
import json
try:
    with open('$INFO_FILE') as f:
        print(json.load(f).get('modelSha256', ''))
except:
    print('')
" 2>/dev/null || echo "")
            fi
            if [ -n "$EXPECTED_SHA256" ]; then
                echo "Verifying model integrity..."
                echo -n "Verifying" > "$STATUS_FILE"
                ACTUAL_SHA256=$(sha256sum "$MODEL_FILE" | cut -d' ' -f1)
                if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
                    echo "INTEGRITY CHECK FAILED: expected $EXPECTED_SHA256, got $ACTUAL_SHA256"
                    rm -f "$MODEL_FILE"
                    echo -n "Failed" > "$STATUS_FILE"
                    exit 1
                fi
                echo "Integrity check passed."
            fi
            break
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

echo "Download complete."

exit 0
