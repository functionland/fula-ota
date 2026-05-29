#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if ! systemctl list-unit-files | grep -q blox-ai.service; then
    echo "Blox AI service is not installed. No action needed"
    exit 0
fi

# fula-plugins.service invokes this script with CWD=/ (the unit has no
# WorkingDirectory and plugins.sh never cd's), so resolve the sibling
# stop/start scripts relative to THIS file. Without this, `./stop.sh` would
# resolve to /stop.sh and `set -e` would abort before anything ran.
cd "$(dirname "$0")"

# Pull the SAME tag the container actually runs. docker-compose.yml pins
# functionland/blox-ai:${BLOX_AI_IMAGE_TAG:-release}; a bare
# `docker pull functionland/blox-ai` fetches :latest, which the publish
# workflow never produces (registry has release/main/test, no latest), so the
# old pull always failed. Read the tag from the device .env, default release.
DEVICE_ENV_FILE="/home/pi/.internal/plugins/blox-ai/.env"
BLOX_AI_IMAGE_TAG_FROM_ENV=""
if [ -r "$DEVICE_ENV_FILE" ]; then
  BLOX_AI_IMAGE_TAG_FROM_ENV=$(
    sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]\+//' \
      "$DEVICE_ENV_FILE" 2>/dev/null \
    | awk -F= '/^BLOX_AI_IMAGE_TAG=/{ sub(/^BLOX_AI_IMAGE_TAG=/, ""); print; exit }'
  )
fi
BLOX_AI_IMAGE_TAG_FROM_ENV=$(printf '%s' "$BLOX_AI_IMAGE_TAG_FROM_ENV" | tr -d '[:space:]')
BLOX_AI_IMAGE_TAG="${BLOX_AI_IMAGE_TAG_FROM_ENV:-release}"

# Pull FIRST, while the old container keeps serving, and make it non-fatal: a
# failed or timed-out pull (plugins.sh wraps us in `timeout 300`) must never
# leave the container stopped. The stop+start below then recreates from
# whatever :release resolves to locally (new image if the pull succeeded).
docker pull "functionland/blox-ai:${BLOX_AI_IMAGE_TAG}" || echo "WARN: pull of functionland/blox-ai:${BLOX_AI_IMAGE_TAG} failed; restarting current image"

bash ./stop.sh
bash ./start.sh
