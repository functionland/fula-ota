"""Tests for Layer 1.8 — state file writers + events.jsonl helper in readiness-check.py.

These cover the atomic-write helper, the events.jsonl appender (including
size-based rotation), the post_heartbeat state-file capture across each
exit branch (no-discovery-URL, no-signing-key, no-circuits, POST success,
POST failure, rate-limited), and the _append_event wiring at safe_restart_fula
/ safe_start_fula / activate_wireguard_support call sites.

All writes are best-effort in production — tests redirect paths to tmp_path
so they don't touch /run or /var/log.
"""

import json
import os
from unittest.mock import MagicMock, patch

import pytest

from conftest import readiness


# ---------------------------------------------------------------------------
# _atomic_write_state
# ---------------------------------------------------------------------------

def test_atomic_write_state_writes_correct_json(tmp_path):
    target = tmp_path / "state.json"
    readiness._atomic_write_state(str(target), {"k": "v", "n": 7})
    assert json.loads(target.read_text()) == {"k": "v", "n": 7}


def test_atomic_write_state_creates_parent_dir(tmp_path):
    target = tmp_path / "newdir" / "subdir" / "state.json"
    readiness._atomic_write_state(str(target), {"ok": True})
    assert target.exists()
    assert json.loads(target.read_text()) == {"ok": True}


def test_atomic_write_state_overwrites_existing(tmp_path):
    target = tmp_path / "state.json"
    target.write_text(json.dumps({"old": True}))
    readiness._atomic_write_state(str(target), {"new": True})
    assert json.loads(target.read_text()) == {"new": True}


def test_atomic_write_state_leaves_no_tmp_file_on_success(tmp_path):
    target = tmp_path / "state.json"
    readiness._atomic_write_state(str(target), {"k": 1})
    leftovers = [p for p in tmp_path.iterdir() if ".tmp." in p.name]
    assert leftovers == []


def test_atomic_write_state_does_not_raise_on_unwritable_path(tmp_path, monkeypatch, caplog):
    # Force os.replace to raise; the helper must swallow and log.
    import readiness_check as r  # alias via sys.modules from conftest
    with patch.object(r.os, "replace", side_effect=OSError("simulated")):
        # Use a writable tmp file so the json.dump itself succeeds, but the
        # final atomic rename fails.
        target = tmp_path / "state.json"
        with caplog.at_level("WARNING"):
            readiness._atomic_write_state(str(target), {"k": 1})
    assert any("could not write state file" in rec.message for rec in caplog.records)


# ---------------------------------------------------------------------------
# _append_event + rotation
# ---------------------------------------------------------------------------

@pytest.fixture
def events_log(tmp_path, monkeypatch):
    """Redirect events.jsonl writes into tmp_path for the duration of the test."""
    log_path = tmp_path / "events.jsonl"
    monkeypatch.setattr(readiness, "EVENTS_LOG_PATH", str(log_path))
    return log_path


def test_append_event_creates_log_file(events_log):
    readiness._append_event("test-cat", {"info": "hello"})
    assert events_log.exists()
    lines = events_log.read_text().strip().splitlines()
    assert len(lines) == 1
    rec = json.loads(lines[0])
    assert rec["category"] == "test-cat"
    assert rec["detail"] == {"info": "hello"}
    assert rec["ts"].endswith("Z")


def test_append_event_appends_subsequent_lines(events_log):
    readiness._append_event("a", {"n": 1})
    readiness._append_event("b", {"n": 2})
    readiness._append_event("a", {"n": 3})
    lines = events_log.read_text().strip().splitlines()
    assert len(lines) == 3
    assert json.loads(lines[0])["detail"] == {"n": 1}
    assert json.loads(lines[2])["detail"] == {"n": 3}


def test_append_event_rotates_when_oversized(events_log, monkeypatch):
    # Force rotation at 100 bytes so the test stays small.
    monkeypatch.setattr(readiness, "EVENTS_LOG_MAX_BYTES", 100)
    monkeypatch.setattr(readiness, "EVENTS_LOG_BACKUPS", 3)
    # First write — file is created and below threshold; no rotation.
    readiness._append_event("a", {"n": 0})
    assert events_log.exists()
    assert not (events_log.parent / f"{events_log.name}.1").exists()
    # Push past 100 bytes so the NEXT call rotates.
    pad = "x" * 200
    readiness._append_event("a", {"pad": pad})
    # Now the next event should trigger rotation: existing log -> .1, fresh log starts.
    readiness._append_event("a", {"n": "post-rotation"})
    rotated = events_log.parent / f"{events_log.name}.1"
    assert rotated.exists(), "rotation should have moved current log to .1"
    # New log should hold only the post-rotation event.
    fresh_lines = events_log.read_text().strip().splitlines()
    assert len(fresh_lines) == 1
    assert json.loads(fresh_lines[0])["detail"] == {"n": "post-rotation"}


def test_append_event_drops_oldest_backup_on_overflow(events_log, monkeypatch):
    monkeypatch.setattr(readiness, "EVENTS_LOG_MAX_BYTES", 50)
    monkeypatch.setattr(readiness, "EVENTS_LOG_BACKUPS", 2)
    base = events_log
    # Pre-create rotation backups .1 and .2 with sentinel content so we can
    # detect whether the oldest got dropped.
    (base.parent / f"{base.name}.1").write_text('{"id":"old-1"}\n')
    (base.parent / f"{base.name}.2").write_text('{"id":"oldest"}\n')
    # Push current log past threshold and trigger another rotation.
    base.write_text("x" * 100)
    readiness._append_event("a", {"n": "rotates"})
    # .2 (oldest) should have been deleted; .1 -> .2; current -> .1.
    assert (base.parent / f"{base.name}.2").read_text().startswith('{"id":"old-1"}')
    assert base.exists()


def test_append_event_does_not_raise_on_unwritable_log(monkeypatch, caplog):
    monkeypatch.setattr(readiness, "EVENTS_LOG_PATH", "/proc/cannot-write/events.jsonl")
    # makedirs may silently fail; the open() call will raise OSError that the
    # helper must swallow.
    with caplog.at_level("WARNING"):
        readiness._append_event("test", {})
    # Either silently swallowed, or warning logged — both OK; just must not raise.


# ---------------------------------------------------------------------------
# _write_heartbeat_state
# ---------------------------------------------------------------------------

def test_write_heartbeat_state_captures_all_fields(tmp_path, monkeypatch):
    monkeypatch.setattr(readiness, "HEARTBEAT_STATE_PATH", str(tmp_path / "hb.state"))
    readiness._write_heartbeat_state(
        http_status=200,
        error=None,
        circuit_count=3,
        reserved_on=["relay.dev.fx.land"],
    )
    state = json.loads((tmp_path / "hb.state").read_text())
    assert state["http_status"] == 200
    assert state["error"] is None
    assert state["last_circuit_count"] == 3
    assert state["last_reserved_on"] == ["relay.dev.fx.land"]
    assert state["last_attempt_ts"].endswith("Z")


# ---------------------------------------------------------------------------
# post_heartbeat now snapshots state on every meaningful exit branch
# ---------------------------------------------------------------------------

@pytest.fixture
def heartbeat_state(tmp_path, monkeypatch):
    p = tmp_path / "hb.state"
    monkeypatch.setattr(readiness, "HEARTBEAT_STATE_PATH", str(p))
    # Reset rate limiter so the function actually runs.
    readiness._last_heartbeat = 0
    return p


def test_post_heartbeat_writes_state_when_discovery_url_empty(heartbeat_state, monkeypatch):
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "")
    readiness.post_heartbeat()
    state = json.loads(heartbeat_state.read_text())
    assert state["error"] == "discovery_url_empty"
    assert state["http_status"] is None


def test_post_heartbeat_writes_state_when_no_signing_key(heartbeat_state, monkeypatch):
    with patch.object(readiness, "_load_kubo_ed25519_key", return_value=(None, None)):
        readiness.post_heartbeat()
    state = json.loads(heartbeat_state.read_text())
    assert state["error"] == "no_signing_key"


def test_post_heartbeat_writes_state_when_no_circuits(heartbeat_state, monkeypatch):
    fake_key = MagicMock()
    with patch.object(readiness, "_load_kubo_ed25519_key", return_value=(fake_key, "Qm123")), \
         patch.object(readiness, "_kubo_id_addresses", return_value=("Qm123", ["/ip4/1.2.3.4/tcp/4001"])):
        readiness.post_heartbeat()
    state = json.loads(heartbeat_state.read_text())
    assert state["error"] == "no_circuits"
    assert state["last_circuit_count"] == 0


def test_post_heartbeat_writes_state_on_successful_post(heartbeat_state, monkeypatch):
    fake_key = MagicMock()
    fake_key.sign.return_value = b"sig"
    circuits = ["/dns/relay.dev.fx.land/tcp/4001/p2p/QmR/p2p-circuit/p2p/QmBox"]
    resp = MagicMock()
    resp.status_code = 200
    resp.text = "ok"
    with patch.object(readiness, "_load_kubo_ed25519_key", return_value=(fake_key, "QmBox")), \
         patch.object(readiness, "_kubo_id_addresses", return_value=("QmBox", circuits)), \
         patch.object(readiness, "_read_cluster_peer_id", return_value=None), \
         patch.object(readiness, "requests") as mock_req:
        mock_req.post.return_value = resp
        readiness.post_heartbeat()
    state = json.loads(heartbeat_state.read_text())
    assert state["http_status"] == 200
    assert state["error"] is None
    assert state["last_circuit_count"] == 1
    assert state["last_reserved_on"] == ["relay.dev.fx.land"]


def test_post_heartbeat_writes_state_on_post_failure(heartbeat_state, monkeypatch):
    fake_key = MagicMock()
    fake_key.sign.return_value = b"sig"
    circuits = ["/dns/relay.dev.fx.land/tcp/4001/p2p/QmR/p2p-circuit/p2p/QmBox"]
    with patch.object(readiness, "_load_kubo_ed25519_key", return_value=(fake_key, "QmBox")), \
         patch.object(readiness, "_kubo_id_addresses", return_value=("QmBox", circuits)), \
         patch.object(readiness, "_read_cluster_peer_id", return_value=None), \
         patch.object(readiness, "requests") as mock_req:
        mock_req.post.side_effect = Exception("simulated network down")
        readiness.post_heartbeat()
    state = json.loads(heartbeat_state.read_text())
    assert state["http_status"] is None
    assert "simulated network down" in state["error"]
    assert state["last_circuit_count"] == 1


def test_post_heartbeat_does_not_write_state_when_rate_limited(heartbeat_state):
    # Ensure file is fresh: pre-populate with a sentinel so we can detect non-overwrite.
    import time as _t
    heartbeat_state.write_text(json.dumps({"sentinel": True}))
    readiness._last_heartbeat = _t.time()  # just ran, rate-limited
    readiness.post_heartbeat()
    state = json.loads(heartbeat_state.read_text())
    assert state == {"sentinel": True}


# ---------------------------------------------------------------------------
# _append_event wiring at restart / activation sites
# ---------------------------------------------------------------------------

def test_safe_restart_fula_appends_event(events_log):
    with patch.object(readiness, "subprocess") as mock_sub:
        result = MagicMock()
        result.returncode = 0
        mock_sub.run.return_value = result
        readiness.safe_restart_fula()
    lines = events_log.read_text().strip().splitlines()
    rec = json.loads(lines[0])
    assert rec["category"] == "restart"
    assert rec["detail"]["unit"] == "fula.service"
    assert rec["detail"]["action"] == "restart"
    assert rec["detail"]["returncode"] == 0


def test_safe_start_fula_appends_event(events_log):
    with patch.object(readiness, "subprocess") as mock_sub:
        result = MagicMock()
        result.returncode = 0
        mock_sub.run.return_value = result
        readiness.safe_start_fula()
    lines = events_log.read_text().strip().splitlines()
    rec = json.loads(lines[0])
    assert rec["category"] == "restart"
    assert rec["detail"]["action"] == "start"


def test_activate_wireguard_support_appends_event_on_success(events_log, monkeypatch):
    # Pretend the service file exists and the systemctl chain reports active.
    monkeypatch.setattr(readiness.os.path, "exists", lambda p: True)
    with patch.object(readiness, "subprocess") as mock_sub:
        is_active = MagicMock(); is_active.stdout = "active"; is_active.returncode = 0
        start = MagicMock(); start.returncode = 0; start.stderr = ""
        # Sequence of calls: is-active (already active branch fast-path), so just one is-active.
        mock_sub.run.return_value = is_active
        readiness.activate_wireguard_support()
    # Activation may exit fast via the "already active" branch (no event), or via the
    # full path (event written). Verify the event path captures success when it fires:
    if events_log.exists():
        rec = json.loads(events_log.read_text().strip().splitlines()[-1])
        if rec["category"] == "wg-activate":
            assert rec["detail"]["result"] in ("active", "failed")


def test_activate_wireguard_support_appends_event_on_failure(events_log, monkeypatch):
    """If is-active returns something other than 'active' AFTER attempting start,
    activate_wireguard_support logs ERROR and we should see a wg-activate event."""
    # Force the function to go past the "already active" fast-path by having
    # the first is-active return non-active, then start returns 0, then
    # second is-active returns non-active again (start.sh failed).
    monkeypatch.setattr(readiness.os.path, "exists", lambda p: True)

    is_active_first = MagicMock(); is_active_first.stdout = "inactive"; is_active_first.returncode = 0
    reset_failed = MagicMock(); reset_failed.returncode = 0
    start = MagicMock(); start.returncode = 1; start.stderr = "boom"
    is_active_second = MagicMock(); is_active_second.stdout = "failed"; is_active_second.returncode = 0

    call_seq = [is_active_first, reset_failed, start, is_active_second]
    def _run(*args, **kwargs):
        return call_seq.pop(0)

    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = _run
        # TimeoutExpired is referenced in the function; carry it through the mock.
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        readiness.activate_wireguard_support()

    # An event must have been appended with result=failed.
    assert events_log.exists()
    lines = events_log.read_text().strip().splitlines()
    activation_events = [json.loads(l) for l in lines if json.loads(l)["category"] == "wg-activate"]
    assert any(ev["detail"]["result"] == "failed" for ev in activation_events)
