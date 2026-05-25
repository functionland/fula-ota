"""Recovery driver for fula-readiness-check.service.

Invoked via systemd `OnFailure=` whenever the main readiness-check unit enters
the `failed` state (e.g., after `StartLimitBurst=10` is exceeded in 5 minutes).

What this script does, in order:
  1. Sleep ~30s to let any transient contention settle (Docker recovery, kernel
     module reload, NetworkManager finishing a reconnect, etc.).
  2. `systemctl reset-failed fula-readiness-check.service` — clear systemd's
     internal failure counter so a subsequent start can succeed.
  3. `systemctl start fula-readiness-check.service` — actually bring it back up.
  4. Update persistent recovery state at /var/log/fula/recover-state.json.
  5. Decide whether to schedule an emergency reboot 5 min from now:
       - Gate A: uptime >= UPTIME_MIN_SEC (don't reboot a freshly-booted device
         that crashed early — the same bug will recur immediately).
       - Gate B: /run/fula-recover-rebooted absent (intra-boot debounce — at
         most one reboot scheduled per boot, even if recovery runs many times).
       - Gate C: < REBOOT_BUDGET reboots in the last REBOOT_BUDGET_WINDOW_SEC
         (persistent across boots — prevents an indefinite reboot loop when the
         daemon is deterministically broken, e.g., after a bad OTA).
     If any gate fails, log loudly and exit success. Recovery (steps 2-3) still
     happened; only the reboot escalation is suppressed.

Design rationale (Gemini + Codex consensus from pre-implementation review):
  - The /run-only sentinel from the original plan would have caused a slow
    reboot loop (~70/day) for a permanently-broken daemon. Persistent budget
    fixes that without giving up the last-resort recovery for true hardware
    weirdness (stuck kernel driver, hung Docker socket).
  - Shell-in-unit-file gets unmanageable once you need counters, timestamps,
    and decision policy. Python is already required by the watchdog itself so
    no new dependency.
  - The script MUST NOT crash. Any uncaught exception is logged and swallowed
    to keep the OnFailure unit from itself going into failed state, which
    would defeat the entire purpose.

Lab test (per Codex's recommendation — the original `systemctl kill` loop is
unreliable because RestartSec=15s leaves long windows with no process to kill):
  Use a deterministic drop-in override that forces the daemon to exit 1 every
  1s, so 10 starts complete in ~10s and the lockout fires cleanly:
    sudo systemctl edit fula-readiness-check.service
      [Service]
      ExecStart=
      ExecStart=/bin/sh -c 'exit 1'
      Restart=on-failure
      RestartSec=1s
    sudo systemctl daemon-reload
    sudo systemctl restart fula-readiness-check
    journalctl -u fula-readiness-check -u fula-readiness-check-recover -f
"""

import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime


RECOVER_STATE_PATH = "/var/log/fula/recover-state.json"
INTRABOOT_SENTINEL = "/run/fula-recover-rebooted"
MAIN_UNIT = "fula-readiness-check.service"
LOGGER_TAG = "fula-recover"

RECOVERY_SLEEP_SEC = 30
UPTIME_MIN_SEC = 3600  # 1h — don't reboot if we just booted
REBOOT_BUDGET = 2  # max reboots in REBOOT_BUDGET_WINDOW_SEC
REBOOT_BUDGET_WINDOW_SEC = 86400  # 24h rolling window
REBOOT_SCHEDULE_DELAY_SEC = 300  # systemd-run --on-active=<this>


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    stream=sys.stdout,
)


def _log(msg, level="info"):
    """Log to stdout (which systemd captures into journalctl for the unit)
    AND to syslog via `logger -t fula-recover` so high-importance events are
    trivially greppable across journals."""
    getattr(logging, level)(msg)
    try:
        subprocess.run(["logger", "-t", LOGGER_TAG, msg],
                       capture_output=True, timeout=5)
    except Exception:
        pass


def _atomic_write(path, data):
    """Atomically write JSON to path via tmp + os.replace. Best-effort: any
    OSError is logged and swallowed so the recovery driver always completes."""
    tmp = None
    try:
        dirname = os.path.dirname(path)
        if dirname:
            try:
                os.makedirs(dirname, exist_ok=True)
            except OSError:
                pass
        tmp = "{}.tmp.{}".format(path, os.getpid())
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except OSError as e:
        _log("could not write {}: {}".format(path, e), "warning")
        if tmp is not None:
            try:
                if os.path.exists(tmp):
                    os.unlink(tmp)
            except OSError:
                pass


def _load_state():
    """Read recover-state.json. Returns a dict with required keys defaulted."""
    try:
        with open(RECOVER_STATE_PATH) as f:
            state = json.load(f)
        if not isinstance(state, dict):
            state = {}
    except (OSError, json.JSONDecodeError):
        state = {}
    state.setdefault("recovery_attempts", [])  # list of ISO timestamps
    state.setdefault("reboots", [])             # list of ISO timestamps
    return state


def _system_uptime_sec():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return 0.0


def _now_iso():
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


def _now_ts():
    return time.time()


def _trim_old(entries, window_sec):
    """Drop ISO-string timestamps older than window_sec from now. Robust to
    malformed entries (they're dropped silently rather than raising)."""
    cutoff = _now_ts() - window_sec
    kept = []
    for entry in entries:
        if not isinstance(entry, str):
            continue
        try:
            ts = datetime.fromisoformat(entry.rstrip("Z")).timestamp()
        except (ValueError, TypeError):
            continue
        if ts >= cutoff:
            kept.append(entry)
    return kept


def _systemctl(verb, unit, timeout=60):
    # No sudo: the recover unit runs as User=root already, so the extra
    # fork would just create a needless dependency on sudoers config.
    return subprocess.run(["systemctl", verb, unit],
                          capture_output=True, text=True, timeout=timeout)


def _schedule_reboot():
    """Schedule a one-shot reboot REBOOT_SCHEDULE_DELAY_SEC from now using a
    transient systemd timer (systemd-run --on-active). --no-block makes
    systemctl reboot return immediately when the timer fires, rather than
    waiting for the reboot transaction to complete.

    No sudo: the recover unit runs as User=root."""
    return subprocess.run(
        ["systemd-run",
         "--on-active={}".format(REBOOT_SCHEDULE_DELAY_SEC),
         "systemctl", "reboot", "--no-block"],
        capture_output=True, text=True, timeout=10,
    )


def _create_sentinel(path):
    try:
        with open(path, "w") as f:
            f.write(_now_iso())
        return True
    except OSError as e:
        _log("could not create sentinel {}: {}".format(path, e), "warning")
        return False


def decide_escalation(state, uptime_sec, sentinel_exists):
    """Pure-function decision: should we escalate to reboot? Returns
    (escalate: bool, reason: str). Extracted so it's directly unit-testable
    without mocking subprocess or filesystem."""
    if uptime_sec < UPTIME_MIN_SEC:
        return False, "uptime_below_threshold"
    if sentinel_exists:
        return False, "intraboot_debounce"
    recent_reboots = len(_trim_old(state.get("reboots", []), REBOOT_BUDGET_WINDOW_SEC))
    if recent_reboots >= REBOOT_BUDGET:
        return False, "budget_exhausted"
    return True, "all_gates_passed"


def main():
    """Recovery driver entry point. Always returns 0 — any internal exception
    is logged and swallowed so this never puts the OnFailure unit into a
    failed state of its own (which would defeat the entire purpose)."""
    _log("recovery driver invoked")
    try:
        time.sleep(RECOVERY_SLEEP_SEC)

        state = _load_state()
        now = _now_iso()
        state["recovery_attempts"].append(now)
        state["recovery_attempts"] = _trim_old(state["recovery_attempts"],
                                               REBOOT_BUDGET_WINDOW_SEC)

        # Step 1 + 2: reset failed counter, restart the main unit
        reset = _systemctl("reset-failed", MAIN_UNIT, timeout=20)
        start = _systemctl("start", MAIN_UNIT, timeout=60)
        _log("reset-failed rc={} start rc={} (stderr={!r})".format(
            reset.returncode, start.returncode,
            (start.stderr or "").strip()[:200],
        ))

        # Step 3: decide whether to escalate to emergency reboot
        uptime_sec = _system_uptime_sec()
        state["reboots"] = _trim_old(state.get("reboots", []),
                                     REBOOT_BUDGET_WINDOW_SEC)
        sentinel_exists = os.path.exists(INTRABOOT_SENTINEL)
        escalate, reason = decide_escalation(state, uptime_sec, sentinel_exists)

        decision = {
            "ts": now,
            "escalated": escalate,
            "reason": reason,
            "uptime_sec": uptime_sec,
            "recent_reboots_24h": len(state["reboots"]),
        }

        if not escalate:
            _log("escalation suppressed: {} (uptime={:.0f}s, recent_reboots={})".format(
                reason, uptime_sec, len(state["reboots"]),
            ))
            state["last_recovery_decision"] = decision
            _atomic_write(RECOVER_STATE_PATH, state)
            return 0

        # All gates passed — attempt to schedule the reboot. Only consume the
        # 24h budget AFTER systemd-run confirms scheduling success. Per Codex's
        # post-implementation review: if scheduling fails for any reason
        # (D-Bus down, transient systemd issue), the original code would have
        # falsely consumed the budget AND created the intraboot sentinel,
        # suppressing future escalation even though no reboot was actually
        # scheduled. Now we only mutate state on confirmed success.
        _log("ESCALATING: attempting to schedule emergency reboot in {}s "
             "(would be reboot {}/{} in last 24h if scheduling succeeds)".format(
                 REBOOT_SCHEDULE_DELAY_SEC, len(state["reboots"]) + 1, REBOOT_BUDGET),
             "warning")

        reboot_result = _schedule_reboot()
        if reboot_result.returncode == 0:
            _log("systemd-run reboot scheduled successfully (rc=0)")
            _create_sentinel(INTRABOOT_SENTINEL)
            state["reboots"].append(now)
            state["last_recovery_decision"] = decision
        else:
            err = (reboot_result.stderr or "").strip()[:200]
            _log("systemd-run scheduling FAILED rc={} stderr={!r} — "
                 "budget NOT consumed, sentinel NOT set; retry will be permitted "
                 "on the next OnFailure".format(reboot_result.returncode, err),
                 "error")
            state["last_recovery_decision"] = {
                "ts": now,
                "escalated": False,
                "reason": "systemd_run_failed",
                "uptime_sec": uptime_sec,
                "recent_reboots_24h": len(state["reboots"]),
                "stderr": err,
            }
        _atomic_write(RECOVER_STATE_PATH, state)
        return 0
    except Exception as e:
        # Last-resort safety net: a crash here would put the recover unit into
        # failed state, defeating the entire purpose. Log and return success.
        _log("UNCAUGHT EXCEPTION in recovery driver: {}: {}".format(
            type(e).__name__, e), "error")
        return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
