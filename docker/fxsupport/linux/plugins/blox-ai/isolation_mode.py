#!/usr/bin/env python3
"""Phase 14 — Layer 3.5 isolated-mode staging.

When the device has had no libp2p AND no BLE activity for >6 hours AND
discovery is unreachable, run the AI in autonomous diagnostic mode: it
self-diagnoses + stages up to 3 recommended_actions in
/var/log/fula/ai-pending-actions.jsonl WITHOUT EXECUTING. Sets the
device LED to slow-blinking magenta so a person walking up to the device
knows something is staged.

When the user reconnects (via BLE or libp2p), the app reads
ai-pending-actions.jsonl via the `ai/pending` BLE command (Phase 6)
and renders the staged recommendations in the Pending panel (Phase 15).

Run via systemd timer (blox-ai-isolation.timer) every 6 hours. Idempotent:
if criteria don't all hit, exit cleanly without staging anything. The
LED clears on next user-connect (the app's chat session start can write
a different LED state via the existing `.command_led` flag-file path).

Privacy: the autonomous session runs ENTIRELY on-device — no central
upload. ai-pending-actions.jsonl is opt-in-readable via the same BLE
proxy as everything else; if the user never connects, the file rotates
out per the 50 MB cap.
"""
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

# Paths (host-side; the isolation service runs on the host, not inside container)
HEARTBEAT_STATE_PATH = "/run/fula-heartbeat.state"
DISCOVERY_STATE_PATH = "/run/fula-discovery.state"
BLE_STATE_PATH = "/run/fula-ble.state"  # Phase 1.9 scanner could optionally write this on BLE command
PENDING_LOG_PATH = "/var/log/fula/ai-pending-actions.jsonl"
PENDING_LOG_MAX_BYTES = 10 * 1024 * 1024  # 10 MB (smaller than events log; entries are rare)
COMMANDS_FLAG_DIR = "/home/pi/commands"
LED_FLAG_PATH = os.path.join(COMMANDS_FLAG_DIR, ".command_led")
GO_FULA_ACCESS_LOG = "/var/log/go-fula-access.log"  # path may vary; defensive read

# Idleness thresholds — 6h matches the plan Layer 3.5
IDLE_THRESHOLD_SEC = 6 * 60 * 60

# Container endpoint
TROUBLESHOOT_URL = "http://127.0.0.1:8083/troubleshoot"
MAX_RECOMMENDATIONS_TO_STAGE = 3
HTTP_TIMEOUT_SEC = 60

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s isolation_mode: %(message)s",
)


def _now_ts():
    return time.time()


def _iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_json_state(path):
    """Best-effort JSON read. Returns {} on any error."""
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _last_libp2p_activity_ts():
    """Most-recent libp2p activity timestamp (epoch seconds). Returns None
    if no log or no parseable line."""
    # go-fula's access log path is install-specific; tolerant of absence.
    try:
        st = os.stat(GO_FULA_ACCESS_LOG)
        # mtime as a proxy for last activity. Cheap + portable.
        return st.st_mtime
    except OSError:
        return None


def _last_ble_activity_ts():
    """Most-recent BLE command timestamp from /run/fula-ble.state, if the
    Phase 1.9 scanner writes one. Falls back to None."""
    s = _read_json_state(BLE_STATE_PATH)
    ts = s.get("last_command_ts")
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    if isinstance(ts, (int, float)):
        return float(ts)
    return None


def _discovery_unreachable():
    """True iff /run/fula-discovery.state says discovery is unreachable.
    Defensive: missing/malformed file → assume reachable (don't fire
    isolation mode spuriously)."""
    s = _read_json_state(DISCOVERY_STATE_PATH)
    ok = s.get("ok")
    # Phase 3 schema: ok is a bool. False = unreachable.
    return ok is False


def _is_isolated() -> bool:
    """Decision: all 3 criteria must hold."""
    now = _now_ts()
    libp2p_ts = _last_libp2p_activity_ts()
    ble_ts = _last_ble_activity_ts()
    libp2p_idle = libp2p_ts is None or (now - libp2p_ts) > IDLE_THRESHOLD_SEC
    ble_idle = ble_ts is None or (now - ble_ts) > IDLE_THRESHOLD_SEC
    return libp2p_idle and ble_idle and _discovery_unreachable()


def _post_self_diagnostic():
    """POST to /troubleshoot with a self-diagnostic prompt; collect the
    streamed events. The container streams SSE; we read until close.
    Returns list of parsed event objects (best-effort)."""
    try:
        import requests
    except ImportError:
        logging.error("requests library not available; isolation mode cannot self-diagnose")
        return []
    body = {
        "prompt": (
            "You are running in ISOLATED MODE. The device has had no app activity "
            "for >6h and cannot reach discovery. Run a full self-diagnostic. "
            "Recommend up to 3 actions; do NOT execute anything."
        ),
    }
    try:
        with requests.post(TROUBLESHOOT_URL, json=body, stream=True,
                            timeout=HTTP_TIMEOUT_SEC) as resp:
            events = []
            for raw_line in resp.iter_lines(decode_unicode=True):
                if not raw_line:
                    continue
                # SSE format: lines starting with "data: " carry payloads.
                # The container's stream may also use plain JSONL — be tolerant.
                payload_str = raw_line
                if raw_line.startswith("data: "):
                    payload_str = raw_line[6:]
                try:
                    ev = json.loads(payload_str)
                except json.JSONDecodeError:
                    continue
                events.append(ev)
            return events
    except Exception as e:
        logging.warning("self-diagnostic POST failed: %s", e)
        return []


def _filter_recommended_actions(events, max_count):
    """Pull at most `max_count` recommended_action events. Skip any that
    don't have the required fields (defense in depth — container should
    validate, but isolation log shouldn't poison itself either)."""
    out = []
    for ev in events:
        if not isinstance(ev, dict) or ev.get("type") != "recommended_action":
            continue
        required = {"action_id", "action_name", "args", "reasoning",
                    "confidence", "tier"}
        if not required.issubset(ev.keys()):
            continue
        out.append(ev)
        if len(out) >= max_count:
            break
    return out


def _stage_pending(action_events, verdict_event):
    """Append a single JSONL line to /var/log/fula/ai-pending-actions.jsonl
    with the staged action set + verdict context."""
    try:
        os.makedirs(os.path.dirname(PENDING_LOG_PATH), exist_ok=True)
    except OSError:
        pass
    record = {
        "ts": _iso_now(),
        "trigger": "isolation_mode",
        "verdict": verdict_event,
        "actions": action_events,
    }
    # Cheap rotation: if the file grew past PENDING_LOG_MAX_BYTES,
    # rename to .1 and start fresh. One-deep rotation is enough — these
    # entries are rare (every 6h at most).
    try:
        if os.path.exists(PENDING_LOG_PATH) and os.path.getsize(PENDING_LOG_PATH) > PENDING_LOG_MAX_BYTES:
            os.replace(PENDING_LOG_PATH, PENDING_LOG_PATH + ".1")
    except OSError:
        pass
    try:
        with open(PENDING_LOG_PATH, "a") as f:
            f.write(json.dumps(record) + "\n")
    except OSError as e:
        logging.error("could not append pending-action log: %s", e)


def _set_led_magenta():
    """Write the .command_led flag-file with `magenta 999999` so commands.sh
    picks it up and sets the LED. Uses the existing core LED dispatch
    (no new core command added per plan: 'plugin writes the existing
    .command_led flag-file with new patterns; no new colors needed in core')."""
    try:
        os.makedirs(COMMANDS_FLAG_DIR, exist_ok=True)
    except OSError:
        pass
    try:
        with open(LED_FLAG_PATH, "w") as f:
            f.write("magenta 999999\n")
    except OSError as e:
        logging.warning("could not write LED flag-file: %s", e)


def main():
    if not _is_isolated():
        logging.info("not in isolated state; exiting")
        return 0
    logging.info("isolation criteria met (libp2p+ble idle >6h, discovery unreachable); running self-diagnostic")
    events = _post_self_diagnostic()
    if not events:
        logging.warning("self-diagnostic produced no events; staging nothing")
        return 0
    # Pull the verdict (last one wins) + up to 3 recommended_actions
    verdict = None
    for ev in events:
        if isinstance(ev, dict) and ev.get("type") == "verdict":
            verdict = ev
    actions = _filter_recommended_actions(events, MAX_RECOMMENDATIONS_TO_STAGE)
    if not actions:
        logging.info("self-diagnostic produced no recommended_actions; verdict-only stage")
    _stage_pending(actions, verdict)
    _set_led_magenta()
    logging.info("staged %d recommendations; LED set to magenta", len(actions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
