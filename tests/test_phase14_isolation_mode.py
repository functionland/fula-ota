"""Phase 14 tests — isolated-mode self-diagnostic staging.

isolation_mode.py is a standalone host-side script. Tests mock the file-
system + requests + filesystem boundaries to exercise the decision logic
+ staging behavior without actually firing the AI container.
"""

import json
import os
from unittest.mock import patch, MagicMock

import pytest

# Load isolation_mode.py without executing main()
import importlib.util
_HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_ISO_PATH = os.path.join(
    _HERE, "docker", "fxsupport", "linux", "plugins", "blox-ai", "isolation_mode.py",
)
_spec = importlib.util.spec_from_file_location("isolation_mode", _ISO_PATH)
iso = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(iso)


# ---------------------------------------------------------------------------
# _is_isolated decision logic
# ---------------------------------------------------------------------------

def test_is_isolated_returns_false_when_libp2p_recent(monkeypatch):
    monkeypatch.setattr(iso, "_last_libp2p_activity_ts", lambda: iso._now_ts())
    monkeypatch.setattr(iso, "_last_ble_activity_ts", lambda: None)
    monkeypatch.setattr(iso, "_discovery_unreachable", lambda: True)
    assert iso._is_isolated() is False


def test_is_isolated_returns_false_when_ble_recent(monkeypatch):
    monkeypatch.setattr(iso, "_last_libp2p_activity_ts", lambda: None)
    monkeypatch.setattr(iso, "_last_ble_activity_ts", lambda: iso._now_ts())
    monkeypatch.setattr(iso, "_discovery_unreachable", lambda: True)
    assert iso._is_isolated() is False


def test_is_isolated_returns_false_when_discovery_reachable(monkeypatch):
    monkeypatch.setattr(iso, "_last_libp2p_activity_ts", lambda: None)
    monkeypatch.setattr(iso, "_last_ble_activity_ts", lambda: None)
    monkeypatch.setattr(iso, "_discovery_unreachable", lambda: False)
    assert iso._is_isolated() is False


def test_is_isolated_returns_true_when_all_criteria_met(monkeypatch):
    monkeypatch.setattr(iso, "_last_libp2p_activity_ts", lambda: None)
    monkeypatch.setattr(iso, "_last_ble_activity_ts", lambda: None)
    monkeypatch.setattr(iso, "_discovery_unreachable", lambda: True)
    assert iso._is_isolated() is True


def test_is_isolated_treats_old_activity_as_idle(monkeypatch):
    """Activity timestamps older than IDLE_THRESHOLD_SEC count as idle."""
    very_old = iso._now_ts() - (iso.IDLE_THRESHOLD_SEC + 3600)
    monkeypatch.setattr(iso, "_last_libp2p_activity_ts", lambda: very_old)
    monkeypatch.setattr(iso, "_last_ble_activity_ts", lambda: very_old)
    monkeypatch.setattr(iso, "_discovery_unreachable", lambda: True)
    assert iso._is_isolated() is True


def test_discovery_unreachable_returns_false_when_state_missing(monkeypatch, tmp_path):
    """Defensive: missing state file → assume discovery IS reachable
    (don't fire isolation mode spuriously on a healthy-but-fresh device)."""
    monkeypatch.setattr(iso, "DISCOVERY_STATE_PATH", str(tmp_path / "missing.state"))
    assert iso._discovery_unreachable() is False


def test_discovery_unreachable_returns_false_when_ok_is_true(monkeypatch, tmp_path):
    path = tmp_path / "discovery.state"
    path.write_text(json.dumps({"ok": True}))
    monkeypatch.setattr(iso, "DISCOVERY_STATE_PATH", str(path))
    assert iso._discovery_unreachable() is False


def test_discovery_unreachable_returns_true_when_ok_is_false(monkeypatch, tmp_path):
    path = tmp_path / "discovery.state"
    path.write_text(json.dumps({"ok": False, "error": "DNS failed"}))
    monkeypatch.setattr(iso, "DISCOVERY_STATE_PATH", str(path))
    assert iso._discovery_unreachable() is True


# ---------------------------------------------------------------------------
# _filter_recommended_actions
# ---------------------------------------------------------------------------

def _valid_action(action_id="a1"):
    return {
        "type": "recommended_action",
        "action_id": action_id,
        "action_name": "restart_fula",
        "args": {},
        "reasoning": "x",
        "confidence": 0.7,
        "tier": 2,
        "approval_token": "t" * 64,
    }


def test_filter_caps_at_max(monkeypatch):
    events = [_valid_action(f"a{i}") for i in range(10)]
    out = iso._filter_recommended_actions(events, 3)
    assert len(out) == 3
    assert [a["action_id"] for a in out] == ["a0", "a1", "a2"]


def test_filter_skips_non_recommended_action_events():
    events = [
        {"type": "thought", "payload": "x"},
        _valid_action("a1"),
        {"type": "verdict", "payload": {"summary": "ok", "severity": "green"}},
        _valid_action("a2"),
    ]
    out = iso._filter_recommended_actions(events, 5)
    assert len(out) == 2
    assert {a["action_id"] for a in out} == {"a1", "a2"}


def test_filter_skips_malformed_recommended_actions():
    events = [
        {"type": "recommended_action", "action_id": "incomplete"},  # missing fields
        _valid_action("ok"),
    ]
    out = iso._filter_recommended_actions(events, 5)
    assert len(out) == 1
    assert out[0]["action_id"] == "ok"


# ---------------------------------------------------------------------------
# _stage_pending
# ---------------------------------------------------------------------------

def test_stage_pending_writes_jsonl_line(tmp_path, monkeypatch):
    path = tmp_path / "ai-pending-actions.jsonl"
    monkeypatch.setattr(iso, "PENDING_LOG_PATH", str(path))
    verdict = {"type": "verdict", "payload": {"summary": "broken", "severity": "red"}}
    actions = [_valid_action("a1"), _valid_action("a2")]
    iso._stage_pending(actions, verdict)
    lines = path.read_text().splitlines()
    assert len(lines) == 1
    record = json.loads(lines[0])
    assert record["trigger"] == "isolation_mode"
    assert record["verdict"] == verdict
    assert [a["action_id"] for a in record["actions"]] == ["a1", "a2"]
    assert "ts" in record


def test_stage_pending_rotates_oversized_file(tmp_path, monkeypatch):
    path = tmp_path / "ai-pending-actions.jsonl"
    monkeypatch.setattr(iso, "PENDING_LOG_PATH", str(path))
    monkeypatch.setattr(iso, "PENDING_LOG_MAX_BYTES", 100)
    path.write_text("x" * 200)  # >max → triggers rotation
    iso._stage_pending([_valid_action("a")], None)
    rotated = path.parent / "ai-pending-actions.jsonl.1"
    assert rotated.exists()
    new_lines = path.read_text().splitlines()
    assert len(new_lines) == 1  # fresh start after rotate


def test_stage_pending_creates_parent_dir(tmp_path, monkeypatch):
    path = tmp_path / "nested/subdir/ai-pending-actions.jsonl"
    monkeypatch.setattr(iso, "PENDING_LOG_PATH", str(path))
    iso._stage_pending([_valid_action("a")], None)
    assert path.exists()


# ---------------------------------------------------------------------------
# _set_led_magenta
# ---------------------------------------------------------------------------

def test_set_led_magenta_writes_command_led_flag(tmp_path, monkeypatch):
    flag = tmp_path / "commands" / ".command_led"
    monkeypatch.setattr(iso, "COMMANDS_FLAG_DIR", str(flag.parent))
    monkeypatch.setattr(iso, "LED_FLAG_PATH", str(flag))
    iso._set_led_magenta()
    assert flag.exists()
    assert flag.read_text().strip() == "magenta 999999"


# ---------------------------------------------------------------------------
# main() integration
# ---------------------------------------------------------------------------

def test_main_skips_when_not_isolated(monkeypatch):
    monkeypatch.setattr(iso, "_is_isolated", lambda: False)
    # _post_self_diagnostic, _stage_pending, _set_led_magenta MUST NOT be called
    called = {"post": False, "stage": False, "led": False}
    monkeypatch.setattr(iso, "_post_self_diagnostic", lambda: called.__setitem__("post", True) or [])
    monkeypatch.setattr(iso, "_stage_pending", lambda *a: called.__setitem__("stage", True))
    monkeypatch.setattr(iso, "_set_led_magenta", lambda: called.__setitem__("led", True))
    assert iso.main() == 0
    assert called == {"post": False, "stage": False, "led": False}


def test_main_stages_when_isolated(monkeypatch, tmp_path):
    monkeypatch.setattr(iso, "_is_isolated", lambda: True)
    pending = tmp_path / "ai-pending.jsonl"
    led = tmp_path / ".command_led"
    monkeypatch.setattr(iso, "PENDING_LOG_PATH", str(pending))
    monkeypatch.setattr(iso, "COMMANDS_FLAG_DIR", str(tmp_path))
    monkeypatch.setattr(iso, "LED_FLAG_PATH", str(led))
    monkeypatch.setattr(iso, "_post_self_diagnostic", lambda: [
        {"type": "verdict", "payload": {"summary": "x", "severity": "yellow"}},
        _valid_action("a1"),
    ])
    assert iso.main() == 0
    assert pending.exists()
    assert led.exists()
    assert "magenta" in led.read_text()


def test_main_handles_empty_diagnostic_gracefully(monkeypatch, tmp_path):
    """If the AI container produced no events (e.g. timeout), exit 0
    and don't stage anything."""
    monkeypatch.setattr(iso, "_is_isolated", lambda: True)
    monkeypatch.setattr(iso, "_post_self_diagnostic", lambda: [])
    staged = {"called": False}
    monkeypatch.setattr(iso, "_stage_pending", lambda *a: staged.__setitem__("called", True))
    assert iso.main() == 0
    assert staged["called"] is False
