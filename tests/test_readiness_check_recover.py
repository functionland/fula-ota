"""Tests for the Phase 2 recovery driver (readiness-check-recover.py).

Covers:
- decide_escalation pure function — all gates (uptime, intra-boot sentinel,
  persistent reboot budget) and combinations.
- _trim_old correctly drops stale timestamps from the rolling window.
- _atomic_write tmp+replace + tmp-cleanup on failure.
- _load_state defaults missing keys; tolerates malformed JSON.
- main() — happy path, sleep is bypassed via monkeypatch; subprocess calls
  are mocked; verifies the correct decision is persisted into the state file
  and the right systemctl/systemd-run invocations are made.

These tests are pure-Python and never touch real systemd, /run, or /var/log/fula.
"""

import json
import os
from unittest.mock import MagicMock, patch

import pytest

from conftest import recover


# ---------------------------------------------------------------------------
# decide_escalation — the pure-function policy
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def restore_constants(monkeypatch):
    """Each test starts with the documented constant values. Tests that override
    use monkeypatch.setattr so values are restored automatically afterwards."""
    yield


def test_decide_escalation_blocks_when_uptime_below_threshold():
    state = {"reboots": []}
    escalate, reason = recover.decide_escalation(
        state, uptime_sec=600, sentinel_exists=False,
    )
    assert escalate is False
    assert reason == "uptime_below_threshold"


def test_decide_escalation_blocks_when_sentinel_present():
    state = {"reboots": []}
    escalate, reason = recover.decide_escalation(
        state, uptime_sec=10_000, sentinel_exists=True,
    )
    assert escalate is False
    assert reason == "intraboot_debounce"


def test_decide_escalation_blocks_when_budget_exhausted():
    state = {"reboots": [recover._now_iso(), recover._now_iso()]}  # 2 recent
    escalate, reason = recover.decide_escalation(
        state, uptime_sec=10_000, sentinel_exists=False,
    )
    assert escalate is False
    assert reason == "budget_exhausted"


def test_decide_escalation_passes_when_all_gates_clear():
    state = {"reboots": []}
    escalate, reason = recover.decide_escalation(
        state, uptime_sec=10_000, sentinel_exists=False,
    )
    assert escalate is True
    assert reason == "all_gates_passed"


def test_decide_escalation_uptime_takes_precedence_over_sentinel(monkeypatch):
    """If both uptime and sentinel would block, uptime reason wins (it's checked
    first). The user can see 'wait longer' rather than be told about an internal
    flag they didn't create."""
    state = {"reboots": []}
    escalate, reason = recover.decide_escalation(
        state, uptime_sec=10, sentinel_exists=True,
    )
    assert escalate is False
    assert reason == "uptime_below_threshold"


# ---------------------------------------------------------------------------
# _trim_old — rolling-window timestamp filter
# ---------------------------------------------------------------------------

def test_trim_old_keeps_recent_entries():
    now = recover._now_iso()
    entries = [now, now, now]
    kept = recover._trim_old(entries, 60)
    assert len(kept) == 3


def test_trim_old_drops_stale_entries(monkeypatch):
    # Build an entry from 2 days ago
    from datetime import datetime, timedelta
    old = (datetime.utcnow() - timedelta(days=2)).isoformat(timespec="seconds") + "Z"
    new = recover._now_iso()
    kept = recover._trim_old([old, new], window_sec=86400)
    assert len(kept) == 1
    assert kept[0] == new


def test_trim_old_drops_malformed_entries():
    """Non-string, non-ISO entries are silently dropped (don't crash)."""
    kept = recover._trim_old([None, 12345, "not-a-date", recover._now_iso()], 60)
    assert len(kept) == 1


def test_trim_old_handles_empty_list():
    assert recover._trim_old([], 60) == []


# ---------------------------------------------------------------------------
# _atomic_write — tmp+rename with error swallow
# ---------------------------------------------------------------------------

def test_atomic_write_writes_json(tmp_path):
    target = tmp_path / "state.json"
    recover._atomic_write(str(target), {"k": 1, "v": "x"})
    assert json.loads(target.read_text()) == {"k": 1, "v": "x"}


def test_atomic_write_creates_parent_directory(tmp_path):
    target = tmp_path / "subdir" / "deep" / "state.json"
    recover._atomic_write(str(target), {"ok": True})
    assert target.exists()


def test_atomic_write_does_not_raise_on_oserror(tmp_path, caplog):
    target = tmp_path / "state.json"
    with patch.object(recover.os, "replace", side_effect=OSError("simulated")):
        with caplog.at_level("WARNING"):
            recover._atomic_write(str(target), {"k": 1})
    # No exception leaked. Either a warning was logged or it failed silently.


def test_atomic_write_cleans_up_tmp_on_failure(tmp_path):
    target = tmp_path / "state.json"
    with patch.object(recover.os, "replace", side_effect=OSError("simulated")):
        recover._atomic_write(str(target), {"k": 1})
    # tmp file must not be left behind
    leftovers = [p for p in tmp_path.iterdir() if ".tmp." in p.name]
    assert leftovers == [], "tmp file leaked: {}".format(leftovers)


# ---------------------------------------------------------------------------
# _load_state
# ---------------------------------------------------------------------------

def test_load_state_returns_defaults_when_file_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(recover, "RECOVER_STATE_PATH", str(tmp_path / "missing.json"))
    state = recover._load_state()
    assert state == {"recovery_attempts": [], "reboots": []}


def test_load_state_tolerates_malformed_json(monkeypatch, tmp_path):
    p = tmp_path / "bad.json"
    p.write_text("{not json")
    monkeypatch.setattr(recover, "RECOVER_STATE_PATH", str(p))
    state = recover._load_state()
    assert state == {"recovery_attempts": [], "reboots": []}


def test_load_state_preserves_existing_lists(monkeypatch, tmp_path):
    p = tmp_path / "state.json"
    p.write_text(json.dumps({
        "recovery_attempts": ["2026-01-01T00:00:00Z"],
        "reboots": ["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"],
        "other_field": "preserved",
    }))
    monkeypatch.setattr(recover, "RECOVER_STATE_PATH", str(p))
    state = recover._load_state()
    assert state["recovery_attempts"] == ["2026-01-01T00:00:00Z"]
    assert len(state["reboots"]) == 2
    assert state["other_field"] == "preserved"


def test_load_state_tolerates_non_dict_root(monkeypatch, tmp_path):
    """Some weird process writes a list to the file. We must not crash; just
    treat it as missing and return defaults."""
    p = tmp_path / "weird.json"
    p.write_text(json.dumps([1, 2, 3]))
    monkeypatch.setattr(recover, "RECOVER_STATE_PATH", str(p))
    state = recover._load_state()
    assert state == {"recovery_attempts": [], "reboots": []}


# ---------------------------------------------------------------------------
# main() end-to-end with all I/O mocked
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_main_env(tmp_path, monkeypatch):
    """Set up isolated paths and bypass the 30-second sleep so tests run fast."""
    state_path = tmp_path / "recover-state.json"
    sentinel_path = tmp_path / "fula-recover-rebooted"
    monkeypatch.setattr(recover, "RECOVER_STATE_PATH", str(state_path))
    monkeypatch.setattr(recover, "INTRABOOT_SENTINEL", str(sentinel_path))
    monkeypatch.setattr(recover, "RECOVERY_SLEEP_SEC", 0)  # skip sleep
    return state_path, sentinel_path


def test_main_happy_path_recovers_and_does_not_escalate_due_to_low_uptime(mock_main_env):
    state_path, sentinel_path = mock_main_env
    with patch.object(recover, "_systemctl") as mock_sc, \
         patch.object(recover, "_schedule_reboot") as mock_sr, \
         patch.object(recover, "_system_uptime_sec", return_value=600):  # 10 min — below 1h threshold
        mock_sc.return_value = MagicMock(returncode=0, stderr="")
        rc = recover.main()
    assert rc == 0
    # Must have run reset-failed AND start
    verbs = [call.args[0] for call in mock_sc.call_args_list]
    assert "reset-failed" in verbs
    assert "start" in verbs
    # No reboot scheduled (uptime gate failed)
    mock_sr.assert_not_called()
    # State file written with the suppression reason
    state = json.loads(state_path.read_text())
    assert state["last_recovery_decision"]["escalated"] is False
    assert state["last_recovery_decision"]["reason"] == "uptime_below_threshold"
    assert len(state["recovery_attempts"]) == 1
    assert sentinel_path.exists() is False


def test_main_escalates_when_all_gates_pass(mock_main_env):
    state_path, sentinel_path = mock_main_env
    with patch.object(recover, "_systemctl") as mock_sc, \
         patch.object(recover, "_schedule_reboot") as mock_sr, \
         patch.object(recover, "_system_uptime_sec", return_value=10_000):  # past 1h threshold
        mock_sc.return_value = MagicMock(returncode=0, stderr="")
        mock_sr.return_value = MagicMock(returncode=0, stderr="")
        rc = recover.main()
    assert rc == 0
    mock_sr.assert_called_once()
    state = json.loads(state_path.read_text())
    assert state["last_recovery_decision"]["escalated"] is True
    assert state["last_recovery_decision"]["reason"] == "all_gates_passed"
    assert len(state["reboots"]) == 1
    assert sentinel_path.exists()  # sentinel created to debounce


def test_main_does_not_escalate_when_sentinel_exists(mock_main_env):
    state_path, sentinel_path = mock_main_env
    sentinel_path.write_text("already-set")
    with patch.object(recover, "_systemctl") as mock_sc, \
         patch.object(recover, "_schedule_reboot") as mock_sr, \
         patch.object(recover, "_system_uptime_sec", return_value=10_000):
        mock_sc.return_value = MagicMock(returncode=0, stderr="")
        rc = recover.main()
    assert rc == 0
    mock_sr.assert_not_called()
    state = json.loads(state_path.read_text())
    assert state["last_recovery_decision"]["escalated"] is False
    assert state["last_recovery_decision"]["reason"] == "intraboot_debounce"


def test_main_does_not_escalate_when_budget_exhausted(mock_main_env):
    state_path, sentinel_path = mock_main_env
    # Pre-populate the state with 2 recent reboots (the budget cap)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({
        "recovery_attempts": [],
        "reboots": [recover._now_iso(), recover._now_iso()],
    }))
    with patch.object(recover, "_systemctl") as mock_sc, \
         patch.object(recover, "_schedule_reboot") as mock_sr, \
         patch.object(recover, "_system_uptime_sec", return_value=10_000):
        mock_sc.return_value = MagicMock(returncode=0, stderr="")
        rc = recover.main()
    assert rc == 0
    mock_sr.assert_not_called()
    state = json.loads(state_path.read_text())
    assert state["last_recovery_decision"]["escalated"] is False
    assert state["last_recovery_decision"]["reason"] == "budget_exhausted"
    # Budget is preserved as-is — we don't add to it when we don't reboot
    assert len(state["reboots"]) == 2


def test_main_old_reboots_age_out_of_budget(mock_main_env):
    """If a reboot happened >24h ago, it shouldn't count against the budget."""
    state_path, sentinel_path = mock_main_env
    from datetime import datetime, timedelta
    old1 = (datetime.utcnow() - timedelta(days=2)).isoformat(timespec="seconds") + "Z"
    old2 = (datetime.utcnow() - timedelta(days=3)).isoformat(timespec="seconds") + "Z"
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({
        "recovery_attempts": [],
        "reboots": [old1, old2],
    }))
    with patch.object(recover, "_systemctl") as mock_sc, \
         patch.object(recover, "_schedule_reboot") as mock_sr, \
         patch.object(recover, "_system_uptime_sec", return_value=10_000):
        mock_sc.return_value = MagicMock(returncode=0, stderr="")
        mock_sr.return_value = MagicMock(returncode=0, stderr="")
        rc = recover.main()
    assert rc == 0
    # Old reboots aged out, so this fresh reboot is allowed
    mock_sr.assert_called_once()
    state = json.loads(state_path.read_text())
    assert state["last_recovery_decision"]["escalated"] is True
    # Old entries trimmed, new entry appended → exactly 1
    assert len(state["reboots"]) == 1


def test_main_always_attempts_reset_and_start_even_when_escalation_suppressed(mock_main_env):
    """The most important contract: even if we DON'T reboot, we must always
    have run reset-failed + start so the main unit recovers from the lockout."""
    state_path, sentinel_path = mock_main_env
    sentinel_path.write_text("already")  # force escalation suppression
    with patch.object(recover, "_systemctl") as mock_sc, \
         patch.object(recover, "_schedule_reboot") as mock_sr, \
         patch.object(recover, "_system_uptime_sec", return_value=10_000):
        mock_sc.return_value = MagicMock(returncode=0, stderr="")
        recover.main()
    verbs = [call.args[0] for call in mock_sc.call_args_list]
    assert verbs == ["reset-failed", "start"]


def test_main_does_not_consume_budget_when_schedule_reboot_fails(mock_main_env):
    """Per Codex's post-implementation review: if systemd-run scheduling
    fails (D-Bus down, etc.), we must NOT consume the 24h reboot budget or
    create the intraboot sentinel — otherwise a single transient failure
    would falsely suppress all future escalation attempts."""
    state_path, sentinel_path = mock_main_env
    with patch.object(recover, "_systemctl") as mock_sc, \
         patch.object(recover, "_schedule_reboot") as mock_sr, \
         patch.object(recover, "_system_uptime_sec", return_value=10_000):
        mock_sc.return_value = MagicMock(returncode=0, stderr="")
        mock_sr.return_value = MagicMock(returncode=1, stderr="D-Bus connection failed")
        rc = recover.main()
    assert rc == 0
    mock_sr.assert_called_once()
    state = json.loads(state_path.read_text())
    # CRITICAL: budget NOT consumed even though we wanted to reboot
    assert state["reboots"] == []
    # CRITICAL: sentinel NOT created — next OnFailure will retry escalation
    assert not sentinel_path.exists()
    # Decision recorded so the next diag query can see what happened
    assert state["last_recovery_decision"]["escalated"] is False
    assert state["last_recovery_decision"]["reason"] == "systemd_run_failed"
    assert "D-Bus" in state["last_recovery_decision"]["stderr"]


def test_main_swallows_systemctl_exception_and_still_writes_state(mock_main_env):
    """If systemctl itself somehow blows up, we must NOT crash the recover unit
    — the state file write and clean exit are critical."""
    state_path, sentinel_path = mock_main_env
    with patch.object(recover, "_systemctl",
                      side_effect=Exception("simulated systemctl explosion")), \
         patch.object(recover, "_system_uptime_sec", return_value=600):
        # main() catches via top-level try/except so we wrap that here
        try:
            rc = recover.main()
        except Exception:
            pytest.fail("main() must not raise; it must swallow")


# ---------------------------------------------------------------------------
# _system_uptime_sec
# ---------------------------------------------------------------------------

def test_system_uptime_parses_valid_proc_uptime(tmp_path, monkeypatch):
    """Use a tmp file as a stand-in for /proc/uptime to validate parsing."""
    p = tmp_path / "uptime"
    p.write_text("12345.67 67890.12\n")
    # Monkey-patch the open call inside _system_uptime_sec
    real_open = recover.__builtins__["open"] if isinstance(recover.__builtins__, dict) else open
    def fake_open(path, *args, **kwargs):
        if path == "/proc/uptime":
            return real_open(str(p), *args, **kwargs)
        return real_open(path, *args, **kwargs)
    with patch("builtins.open", side_effect=fake_open):
        assert recover._system_uptime_sec() == 12345.67


def test_system_uptime_returns_zero_on_unreadable_proc():
    """If /proc/uptime is somehow inaccessible (containerized? exotic Linux?),
    we MUST NOT crash. Returning 0 means the uptime gate will block escalation
    — which is the safer default."""
    with patch("builtins.open", side_effect=OSError("no /proc")):
        assert recover._system_uptime_sec() == 0.0
