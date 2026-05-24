"""Tests for Phase 4 — WireGuard handshake-age health check.

Covers:
- _read_wireguard_status: parses status.sh output; handles failures.
- _internet_likely_down: reads /run/fula-discovery.state and applies freshness
  + ok=false gates.
- check_wireguard_handshake_age:
  - not installed → record state, no remediation
  - installed but not active → record state, no remediation
  - active + age=None (never handshook) → grace, no remediation
  - active + age < threshold → healthy, reset escalation counter
  - active + age > threshold + keepalive set → bounce
  - active + age > 300s + null keepalive → bounce
  - active + clock skew (age<0) → don't bounce
  - rate-limited → skip
  - 3-strike escalation → use longer cooldown
  - bounce success → consec_failures resets
  - bounce up-failure → consec_failures increments
  - internet-down guard → skip when discovery state says ok=false recently

All `subprocess.run` calls and the status.sh JSON output are mocked.
"""

import json
import time as _time_mod
from datetime import datetime, timedelta
from unittest.mock import MagicMock, patch

import pytest

from conftest import readiness


# ---------------------------------------------------------------------------
# _read_wireguard_status
# ---------------------------------------------------------------------------

def _mock_status_run(stdout, rc=0):
    r = MagicMock(); r.stdout = stdout; r.returncode = rc; r.stderr = ""
    return r


def test_read_wireguard_status_parses_full_json():
    out = json.dumps({
        "installed": True, "registered": True, "active": True,
        "endpoint": "1.2.3.4:51820", "assigned_ip": "10.250.0.1",
        "peer_id_registered": "abc",
        "last_handshake_age_sec": 42, "rx_bytes": 1000, "tx_bytes": 2000,
        "persistent_keepalive_sec": 25,
    })
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_status_run(out)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        parsed, err = readiness._read_wireguard_status()
    assert err is None
    assert parsed["installed"] is True
    assert parsed["last_handshake_age_sec"] == 42


def test_read_wireguard_status_returns_error_on_nonzero_rc():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_status_run("", rc=1)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        parsed, err = readiness._read_wireguard_status()
    assert parsed == {}
    assert "status_sh rc=1" in err


def test_read_wireguard_status_returns_error_on_malformed_json():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_status_run("{not json")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        parsed, err = readiness._read_wireguard_status()
    assert parsed == {}
    assert "parse_error" in err


def test_read_wireguard_status_handles_subprocess_oserror():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = FileNotFoundError("no bash")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        parsed, err = readiness._read_wireguard_status()
    assert parsed == {}
    assert "FileNotFoundError" in err


# ---------------------------------------------------------------------------
# _internet_likely_down
# ---------------------------------------------------------------------------

@pytest.fixture
def discovery_state(tmp_path, monkeypatch):
    p = tmp_path / "fula-discovery.state"
    monkeypatch.setattr(readiness, "DISCOVERY_STATE_PATH", str(p))
    return p


def test_internet_likely_down_returns_false_when_no_state_file(discovery_state):
    """Missing file → assume OK (don't gate WG remediation on missing data)."""
    assert readiness._internet_likely_down() is False


def test_internet_likely_down_returns_false_when_discovery_ok(discovery_state):
    discovery_state.write_text(json.dumps({
        "ok": True,
        "last_check_ts": datetime.utcnow().isoformat(timespec="seconds") + "Z",
    }))
    assert readiness._internet_likely_down() is False


def test_internet_likely_down_returns_true_when_recent_failure(discovery_state):
    discovery_state.write_text(json.dumps({
        "ok": False, "error": "connection_error",
        "last_check_ts": datetime.utcnow().isoformat(timespec="seconds") + "Z",
    }))
    assert readiness._internet_likely_down() is True


def test_internet_likely_down_ignores_stale_failure(discovery_state):
    """Failure from >10 min ago shouldn't block bounce — that's stale data."""
    old = (datetime.utcnow() - timedelta(hours=2)).isoformat(timespec="seconds") + "Z"
    discovery_state.write_text(json.dumps({"ok": False, "last_check_ts": old}))
    assert readiness._internet_likely_down() is False


def test_internet_likely_down_tolerates_malformed_state(discovery_state):
    discovery_state.write_text("{not json")
    assert readiness._internet_likely_down() is False


# ---------------------------------------------------------------------------
# check_wireguard_handshake_age
# ---------------------------------------------------------------------------

@pytest.fixture
def wg_state(tmp_path, monkeypatch):
    p = tmp_path / "fula-wireguard.state"
    monkeypatch.setattr(readiness, "WIREGUARD_STATE_PATH", str(p))
    # Always start with no rate-limit and fresh escalation counter
    monkeypatch.setattr(readiness, "_last_wg_bounce_attempt", 0.0)
    monkeypatch.setattr(readiness, "_consec_wg_bounce_failures", 0)
    # Bypass the one-shot hydration so tests don't accidentally read leftover
    # state from a sibling test (each test gets a fresh tmp_path so the state
    # file is missing — but the flag persists across test invocations within
    # the same module, so reset it explicitly here).
    monkeypatch.setattr(readiness, "_wg_counter_hydrated", False)
    return p


def _patch_status_returns(parsed, error=None):
    """Helper: makes _read_wireguard_status return the given parsed dict."""
    return patch.object(readiness, "_read_wireguard_status",
                        return_value=(parsed, error))


def test_wg_check_records_state_when_not_installed(wg_state):
    with _patch_status_returns({"installed": False, "registered": False,
                                "active": False, "last_handshake_age_sec": None}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False  # not active
    state = json.loads(wg_state.read_text())
    assert state["installed"] is False
    assert state["active"] is False
    assert state["remediation"] is None


def test_wg_check_records_state_when_active_but_unregistered(wg_state):
    with _patch_status_returns({"installed": True, "registered": False,
                                "active": False, "last_handshake_age_sec": None}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False
    state = json.loads(wg_state.read_text())
    assert state["registered"] is False
    assert state["remediation"] is None


def test_wg_check_gives_grace_when_never_handshook(wg_state):
    """Active + age=None → no bounce yet. Slow first handshakes are normal."""
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": None,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is True  # don't bounce, return True (active)
    state = json.loads(wg_state.read_text())
    assert state["remediation"] is None


def test_wg_check_healthy_path_resets_escalation_counter(wg_state, monkeypatch):
    """Fresh handshake (within keepalive window) resets consec_failures to 0
    so a recovered tunnel doesn't stay in backoff forever."""
    monkeypatch.setattr(readiness, "_consec_wg_bounce_failures", 2)
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 10,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is True
    state = json.loads(wg_state.read_text())
    assert state["consec_failures"] == 0
    # The module-level counter was reset
    assert readiness._consec_wg_bounce_failures == 0


def test_wg_check_does_not_reset_counter_when_age_is_between_keepalive_and_threshold(wg_state, monkeypatch):
    """If keepalive=25 and age=100, that's > 1 keepalive but < 3*keepalive
    threshold (still under 180s floor). Healthy enough not to bounce, but
    not fresh enough to confirm recovery — escalation counter unchanged."""
    monkeypatch.setattr(readiness, "_consec_wg_bounce_failures", 2)
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 100,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is True
    state = json.loads(wg_state.read_text())
    assert state["consec_failures"] == 2  # NOT reset


def test_wg_check_clock_skew_negative_age_does_not_bounce(wg_state):
    """Per Gemini: negative age = clock moved backward (NTP fix in progress).
    Don't bounce; just record the state."""
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": -50,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is True
    state = json.loads(wg_state.read_text())
    assert state["error"] == "clock_skew_negative_age"
    assert state["remediation"] is None


def test_wg_check_bounce_succeeds_only_when_post_bounce_handshake_is_fresh(wg_state):
    """Per Codex (HIGH): `wg-quick up rc=0` only proves interface came up.
    `remediation_ok=True` and counter-reset require a CONFIRMED fresh
    handshake in the post-bounce re-read."""
    # First read: stale (triggers bounce). Re-read after bounce: fresh handshake.
    status_calls = iter([
        ({"installed": True, "registered": True, "active": True,
          "last_handshake_age_sec": 500, "persistent_keepalive_sec": 25}, None),
        ({"installed": True, "registered": True, "active": True,
          "last_handshake_age_sec": 5, "persistent_keepalive_sec": 25}, None),
    ])
    with patch.object(readiness, "_read_wireguard_status",
                      side_effect=lambda: next(status_calls)), \
         patch.object(readiness, "subprocess") as mock_sub, \
         patch.object(readiness.time, "sleep"):
        mock_sub.run.return_value = _mock_status_run("", rc=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        ok = readiness.check_wireguard_handshake_age()
    assert ok is True
    state = json.loads(wg_state.read_text())
    assert state["remediation"] == "wg-quick.down+up"
    assert state["remediation_ok"] is True
    assert state["last_handshake_age_sec"] == 5  # post-bounce fresh age
    assert state["consec_failures"] == 0  # reset on confirmed recovery
    cmd_calls = [c.args[0] for c in mock_sub.run.call_args_list]
    assert any(c[:2] == ["wg-quick", "down"] for c in cmd_calls)
    assert any(c[:2] == ["wg-quick", "up"] for c in cmd_calls)


def test_wg_check_bounce_attempt_ok_but_no_fresh_handshake_counts_as_failure(wg_state):
    """The critical Codex finding: if wg-quick up returns 0 but the handshake
    didn't actually recover (post-bounce age still stale), this MUST count as
    a failure for backoff accounting. Otherwise a tunnel that brings up
    cleanly every cycle but immediately stalls would never enter backoff."""
    status_calls = iter([
        ({"installed": True, "registered": True, "active": True,
          "last_handshake_age_sec": 500, "persistent_keepalive_sec": 25}, None),
        # Post-bounce: interface up, but handshake still stale
        ({"installed": True, "registered": True, "active": True,
          "last_handshake_age_sec": 400, "persistent_keepalive_sec": 25}, None),
    ])
    with patch.object(readiness, "_read_wireguard_status",
                      side_effect=lambda: next(status_calls)), \
         patch.object(readiness, "subprocess") as mock_sub, \
         patch.object(readiness.time, "sleep"):
        mock_sub.run.return_value = _mock_status_run("", rc=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False  # bounce_recovered=False even though up_rc=0
    state = json.loads(wg_state.read_text())
    assert state["remediation_ok"] is False
    # CRITICAL: counter incremented (would have been a false-zero before fix)
    assert state["consec_failures"] == 1
    assert readiness._consec_wg_bounce_failures == 1


def test_wg_check_bounces_when_null_keepalive_and_age_over_300s(wg_state):
    """Per Codex: keepalive=null/0 → 300s threshold (vs the 180s floor for
    keepalive peers). Age=400 should bounce."""
    status_calls = iter([
        ({"installed": True, "registered": True, "active": True,
          "last_handshake_age_sec": 400, "persistent_keepalive_sec": None}, None),
        ({"installed": True, "registered": True, "active": True,
          "last_handshake_age_sec": 10, "persistent_keepalive_sec": None}, None),
    ])
    with patch.object(readiness, "_read_wireguard_status",
                      side_effect=lambda: next(status_calls)), \
         patch.object(readiness, "subprocess") as mock_sub, \
         patch.object(readiness.time, "sleep"):
        mock_sub.run.return_value = _mock_status_run("", rc=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        ok = readiness.check_wireguard_handshake_age()
    assert ok is True
    state = json.loads(wg_state.read_text())
    assert state["remediation"] == "wg-quick.down+up"


def test_wg_check_does_not_bounce_null_keepalive_age_under_300s(wg_state):
    """Boundary check: age=200 < 300 threshold → don't bounce."""
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 200,
                                "persistent_keepalive_sec": None}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is True
    state = json.loads(wg_state.read_text())
    assert state["remediation"] is None


def test_wg_check_rate_limited_skips_bounce(wg_state, monkeypatch):
    """Within cooldown window → no bounce even if stale."""
    monkeypatch.setattr(readiness, "_last_wg_bounce_attempt", _time_mod.time())
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 500,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False
    state = json.loads(wg_state.read_text())
    assert state["remediation"] == "rate_limited"


def test_wg_check_3_strike_escalates_to_longer_cooldown(wg_state, monkeypatch):
    """After 3 consec failures, the cooldown should become WG_BOUNCE_BACKOFF_SEC
    (30 min) rather than WG_BOUNCE_COOLDOWN_SEC (5 min)."""
    monkeypatch.setattr(readiness, "_consec_wg_bounce_failures", 3)
    # last bounce was 10 min ago — past the 5-min cooldown but inside the 30-min backoff
    monkeypatch.setattr(readiness, "_last_wg_bounce_attempt",
                        _time_mod.time() - 600)
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 500,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False
    state = json.loads(wg_state.read_text())
    assert state["remediation"] == "rate_limited_backoff"


def test_wg_check_bounce_failure_increments_consec_failures(wg_state):
    """If wg-quick up returns rc!=0 the counter goes up. After 3 consec, the
    next attempt enters backoff (covered by separate test)."""
    sub_calls = []
    def fake_run(args, **kw):
        sub_calls.append(args)
        # wg-quick down returns 0, wg-quick up returns 1
        if "down" in args:
            r = MagicMock(); r.returncode = 0; r.stderr = ""; r.stdout = ""
        else:
            r = MagicMock(); r.returncode = 1; r.stderr = "address in use"; r.stdout = ""
        return r
    # Status reads: stale → bounce; post-bounce still stale (up failed, so no recovery)
    status_calls = iter([
        ({"installed": True, "registered": True, "active": True,
          "last_handshake_age_sec": 500, "persistent_keepalive_sec": 25}, None),
        ({"installed": True, "registered": True, "active": False,
          "last_handshake_age_sec": None, "persistent_keepalive_sec": 25}, None),
    ])
    with patch.object(readiness, "_read_wireguard_status",
                      side_effect=lambda: next(status_calls)), \
         patch.object(readiness, "subprocess") as mock_sub, \
         patch.object(readiness.time, "sleep"):
        mock_sub.run.side_effect = fake_run
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False
    state = json.loads(wg_state.read_text())
    assert state["remediation_ok"] is False
    assert state["consec_failures"] == 1
    assert "address in use" in state["remediation_stderr"]
    assert readiness._consec_wg_bounce_failures == 1


def test_wg_check_hydrates_counter_from_state_file_on_first_call(tmp_path, monkeypatch):
    """Per built-in advisor: module-level counter resets on daemon restart
    (Phase 2's recovery service triggers exactly that). Without hydration,
    the 3-strike backoff would be silently wiped on every supervisor restart.
    Must read consec_failures back from /run/fula-wireguard.state on the
    first call after process start."""
    state_path = tmp_path / "fula-wireguard.state"
    # Pre-populate the state file as if a prior daemon instance left it
    state_path.write_text(json.dumps({
        "last_check_ts": "2026-05-24T00:00:00Z",
        "installed": True, "registered": True, "active": True,
        "last_handshake_age_sec": 500, "persistent_keepalive_sec": 25,
        "consec_failures": 3,  # ← prior daemon recorded 3 failures
    }))
    monkeypatch.setattr(readiness, "WIREGUARD_STATE_PATH", str(state_path))
    monkeypatch.setattr(readiness, "_last_wg_bounce_attempt", _time_mod.time() - 100)
    # Process just (re)started: hydration flag is False, counter is 0
    monkeypatch.setattr(readiness, "_consec_wg_bounce_failures", 0)
    monkeypatch.setattr(readiness, "_wg_counter_hydrated", False)

    # Stale tunnel + within normal cooldown (300s) but PAST backoff entry (since
    # hydrated counter is 3, cooldown becomes 1800s; 100s elapsed → rate_limited_backoff)
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 500,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()

    assert ok is False
    state = json.loads(state_path.read_text())
    # Counter was hydrated to 3 → cooldown is the long backoff
    assert state["remediation"] == "rate_limited_backoff"
    assert state["consec_failures"] == 3
    # Confirm the module-level counter actually got hydrated
    assert readiness._consec_wg_bounce_failures == 3


def test_wg_check_hydration_runs_only_once(tmp_path, monkeypatch):
    """Subsequent calls (within the same process) must NOT re-hydrate;
    that would let a later state-file write get re-read and clobber the
    current in-memory counter mid-process."""
    state_path = tmp_path / "fula-wireguard.state"
    monkeypatch.setattr(readiness, "WIREGUARD_STATE_PATH", str(state_path))
    monkeypatch.setattr(readiness, "_consec_wg_bounce_failures", 0)
    monkeypatch.setattr(readiness, "_wg_counter_hydrated", False)
    monkeypatch.setattr(readiness, "_last_wg_bounce_attempt", 0.0)

    # First call: no state file, counter stays at 0, hydration flag flips True
    with _patch_status_returns({"installed": False, "registered": False,
                                "active": False, "last_handshake_age_sec": None}):
        readiness.check_wireguard_handshake_age()
    assert readiness._wg_counter_hydrated is True
    assert readiness._consec_wg_bounce_failures == 0

    # Now write a state file with consec_failures=5 (simulating a parallel write)
    state_path.write_text(json.dumps({"consec_failures": 5}))

    # Second call: hydration is already done → counter must NOT be re-read
    with _patch_status_returns({"installed": False, "registered": False,
                                "active": False, "last_handshake_age_sec": None}):
        readiness.check_wireguard_handshake_age()
    assert readiness._consec_wg_bounce_failures == 0  # NOT 5


def test_wg_check_internet_down_guard_skips_bounce(wg_state, tmp_path, monkeypatch):
    """If discovery state shows recent ok=false, skip bounce (WG can't fix WAN)."""
    discovery_path = tmp_path / "fula-discovery.state"
    discovery_path.write_text(json.dumps({
        "ok": False, "error": "timeout",
        "last_check_ts": datetime.utcnow().isoformat(timespec="seconds") + "Z",
    }))
    monkeypatch.setattr(readiness, "DISCOVERY_STATE_PATH", str(discovery_path))
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 500,
                                "persistent_keepalive_sec": 25}):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False
    state = json.loads(wg_state.read_text())
    assert state["remediation"] == "skipped_no_internet"


def test_wg_check_records_error_when_status_sh_fails(wg_state):
    with _patch_status_returns({}, error="status_sh rc=2"):
        ok = readiness.check_wireguard_handshake_age()
    assert ok is False
    state = json.loads(wg_state.read_text())
    assert state["error"] == "status_sh rc=2"


def test_wg_check_does_not_crash_on_remediation_subprocess_exception(wg_state):
    """If wg-quick itself raises (missing binary, weird OSError), check must
    not crash — caller's contract per best-effort design."""
    with _patch_status_returns({"installed": True, "registered": True,
                                "active": True, "last_handshake_age_sec": 500,
                                "persistent_keepalive_sec": 25}), \
         patch.object(readiness, "subprocess") as mock_sub, \
         patch.object(readiness.time, "sleep"):
        mock_sub.run.side_effect = OSError("missing wg-quick")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        try:
            ok = readiness.check_wireguard_handshake_age()
        except OSError:
            pytest.fail("check_wireguard_handshake_age must not leak OSError")
    assert ok is False
    state = json.loads(wg_state.read_text())
    # remediation was attempted but both branches OSError'd → remediation_ok stays None then becomes False
    assert "missing wg-quick" in state["remediation_stderr"]
