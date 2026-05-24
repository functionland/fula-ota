#!/bin/bash
# Phase 17 — runbook fast-iteration reload.
#
# After OTA pushes a new runbook.md (or a developer drops one in via
# scp), run this script to make the blox-ai container reload the
# runbook WITHOUT a full container restart (avoids the 10–30 s model
# re-warm time on RK3588 NPU).
#
# Flow:
#   1. Validate the runbook.md exists at the plugin install path and
#      parses cleanly (frontmatter present, required keys, integer
#      versions). Refuse to signal if the file is broken — better to
#      keep the container running on the OLD runbook than to ask it
#      to swap to a broken one.
#   2. Send SIGHUP to the running blox-ai container via docker kill
#      --signal=SIGHUP. The cross-repo container is responsible for:
#        - re-reading /usr/bin/fula/ai/runbook.md
#        - parsing frontmatter (via the SAME runbook_frontmatter.py
#          contract — vendored or submoduled from this directory)
#        - refusing the swap if the new runbook_version is not greater
#          than the currently-loaded one (replay protection)
#        - refusing the swap if schema_version changed (breaking;
#          requires a full container restart)
#        - appending a 'runbook_reload' event to /var/log/fula/events.jsonl
#
# This script does NOT bump runbook_version itself — that's the
# author's job before committing the file. It DOES detect the case
# where the OTA push left the file in a state the container can't
# parse, and refuses to signal.

set -e

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNBOOK="$PLUGIN_DIR/runbook.md"
CONTAINER_NAME="${BLOX_AI_CONTAINER:-blox-ai}"

if [ ! -r "$RUNBOOK" ]; then
  echo "reload_runbook: runbook not readable at $RUNBOOK" >&2
  exit 1
fi

# Sanity-validate the frontmatter via the parser. Any failure here
# means: don't bother the container — fix the runbook first.
if ! python3 -c "
import sys
sys.path.insert(0, '$PLUGIN_DIR')
from runbook_frontmatter import parse_file, RunbookFrontmatterError
try:
    fm = parse_file('$RUNBOOK')
    print(f'runbook_version={fm.runbook_version} schema_version={fm.schema_version}')
except RunbookFrontmatterError as e:
    print(f'frontmatter parse failed: {e}', file=sys.stderr)
    sys.exit(2)
"; then
  echo "reload_runbook: refusing to signal — runbook.md is malformed" >&2
  exit 2
fi

# Container must be running. If it's not, there's nothing to reload —
# next container start will pick up the new runbook naturally.
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "reload_runbook: container '$CONTAINER_NAME' not running; next start will pick up new runbook"
  exit 0
fi

echo "reload_runbook: sending SIGHUP to $CONTAINER_NAME"
docker kill --signal=SIGHUP "$CONTAINER_NAME"
echo "reload_runbook: signalled. Container will log the swap result to /var/log/fula/events.jsonl"
