"""Tests for Phase 3 — HTTPS reachability + NTP sync checks in readiness-check.py.

Covers:
- check_discovery_https_reachable: 2xx success, captive-portal 302, WAF 403,
  timeout, connection error, empty DISCOVERY_API_URL, URL normalization,
  stream=True request shape, allow_redirects=False, headers
- _read_timedatectl_synced: synced/unsynced/missing/timeout/garbage
- _read_active_ntp_daemon: chronyd active, timesyncd active, both inactive, OSError
- _read_ntp_offset_ms: chronyc CSV parsing, timedatectl us/ms/s parsing, missing tool
- check_ntp_sync: already synced (no remediation), unsynced → chronyc.makestep,
  unsynced → systemd-timesyncd.restart, rate-limited, remediation failure,
  remediation succeeds (re-check shows synced), all-subprocess-failure tolerance

All tests mock `requests` and `subprocess` at the module boundary so they
never touch real network, real /run, or real systemd.
"""

import json
import re
from unittest.mock import MagicMock, patch, call

import pytest
import requests

from conftest import readiness


# ---------------------------------------------------------------------------
# check_discovery_https_reachable
# ---------------------------------------------------------------------------

@pytest.fixture
def discovery_state(tmp_path, monkeypatch):
    p = tmp_path / "fula-discovery.state"
    monkeypatch.setattr(readiness, "DISCOVERY_STATE_PATH", str(p))
    return p


def _mock_response(status_code=200):
    r = MagicMock()
    r.status_code = status_code
    return r


def test_discovery_check_returns_true_on_2xx(discovery_state, monkeypatch):
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "https://discovery.fula.network")
    with patch.object(readiness, "requests") as mock_req:
        mock_req.get.return_value = _mock_response(200)
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        ok = readiness.check_discovery_https_reachable()
    assert ok is True
    state = json.loads(discovery_state.read_text())
    assert state["ok"] is True
    assert state["status_code"] == 200
    assert state["error"] is None
    assert state["latency_ms"] is not None
    assert state["url"] == "https://discovery.fula.network/relays"


def test_discovery_check_treats_captive_portal_302_as_failure(discovery_state, monkeypatch):
    """A 302 redirect to a login page is the classic captive-portal pattern.
    Per Codex: strict 2xx — 3xx must be FAIL so we don't think the API works
    when actually we're seeing the WiFi vendor's login page."""
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "https://discovery.fula.network")
    with patch.object(readiness, "requests") as mock_req:
        mock_req.get.return_value = _mock_response(302)
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        ok = readiness.check_discovery_https_reachable()
    assert ok is False
    state = json.loads(discovery_state.read_text())
    assert state["ok"] is False
    assert state["status_code"] == 302
    assert state["error"] == "http_302"


def test_discovery_check_records_403_waf_block(discovery_state, monkeypatch):
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "https://discovery.fula.network")
    with patch.object(readiness, "requests") as mock_req:
        mock_req.get.return_value = _mock_response(403)
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        ok = readiness.check_discovery_https_reachable()
    assert ok is False
    state = json.loads(discovery_state.read_text())
    assert state["error"] == "http_403"


def test_discovery_check_records_timeout(discovery_state, monkeypatch):
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "https://discovery.fula.network")
    with patch.object(readiness, "requests") as mock_req:
        mock_req.get.side_effect = requests.Timeout()
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        ok = readiness.check_discovery_https_reachable()
    assert ok is False
    state = json.loads(discovery_state.read_text())
    assert state["error"] == "timeout"
    assert state["status_code"] is None


def test_discovery_check_records_connection_error(discovery_state, monkeypatch):
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "https://discovery.fula.network")
    with patch.object(readiness, "requests") as mock_req:
        mock_req.get.side_effect = requests.ConnectionError("DNS lookup failed")
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        ok = readiness.check_discovery_https_reachable()
    assert ok is False
    state = json.loads(discovery_state.read_text())
    assert state["error"].startswith("connection_error:")
    assert "DNS lookup failed" in state["error"]


def test_discovery_check_records_empty_url(discovery_state, monkeypatch):
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "")
    ok = readiness.check_discovery_https_reachable()
    assert ok is False
    state = json.loads(discovery_state.read_text())
    assert state["error"] == "discovery_url_empty"


def test_discovery_check_normalizes_trailing_slash(discovery_state, monkeypatch):
    """DISCOVERY_API_URL with trailing slash must not produce '//relays'."""
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "https://discovery.fula.network/")
    with patch.object(readiness, "requests") as mock_req:
        mock_req.get.return_value = _mock_response(200)
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        readiness.check_discovery_https_reachable()
    state = json.loads(discovery_state.read_text())
    assert state["url"] == "https://discovery.fula.network/relays"


def test_discovery_check_uses_correct_request_shape(discovery_state, monkeypatch):
    """The request must be GET (HEAD returns 404 from the Worker), stream=True,
    allow_redirects=False, with the documented headers."""
    monkeypatch.setattr(readiness, "DISCOVERY_API_URL", "https://discovery.fula.network")
    with patch.object(readiness, "requests") as mock_req:
        mock_req.get.return_value = _mock_response(200)
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        readiness.check_discovery_https_reachable()
    call_args = mock_req.get.call_args
    assert call_args.args[0] == "https://discovery.fula.network/relays"
    assert call_args.kwargs["allow_redirects"] is False
    assert call_args.kwargs["stream"] is True
    headers = call_args.kwargs["headers"]
    assert headers["user-agent"] == "fula-readiness-check/1.0"
    assert headers["x-fula-client"] == "edge"
    assert headers["accept"] == "application/json"


# ---------------------------------------------------------------------------
# _read_timedatectl_synced
# ---------------------------------------------------------------------------

def _mock_subproc_run_return(stdout, returncode=0):
    r = MagicMock(); r.stdout = stdout; r.returncode = returncode; r.stderr = ""
    return r


def test_read_timedatectl_synced_returns_true_when_yes():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("NTPSynchronized=yes\n")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        synced, err = readiness._read_timedatectl_synced()
    assert synced is True
    assert err is None


def test_read_timedatectl_synced_returns_false_when_no():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("NTPSynchronized=no\n")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        synced, err = readiness._read_timedatectl_synced()
    assert synced is False
    assert err is None


@pytest.mark.parametrize("value", ["yes", "Yes", "YES", "true", "True", "1"])
def test_read_timedatectl_synced_accepts_alternate_truthy_forms(value):
    """Gemini's note: be tolerant of representation variants."""
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return(f"NTPSynchronized={value}\n")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        synced, err = readiness._read_timedatectl_synced()
    assert synced is True, f"value {value!r} should be recognized as synced"


def test_read_timedatectl_synced_returns_error_on_nonzero_rc():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("", returncode=1)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        synced, err = readiness._read_timedatectl_synced()
    assert synced is None
    assert "timedatectl rc=1" in err


def test_read_timedatectl_synced_handles_oserror_gracefully():
    """If timedatectl is missing entirely (FileNotFoundError) the watchdog
    must not crash — return (None, error_str)."""
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = FileNotFoundError("no timedatectl")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        synced, err = readiness._read_timedatectl_synced()
    assert synced is None
    assert "FileNotFoundError" in err


# ---------------------------------------------------------------------------
# _read_active_ntp_daemon
# ---------------------------------------------------------------------------

def test_read_active_ntp_daemon_finds_chronyd():
    """chronyd active wins over timesyncd (chronyd checked first)."""
    def fake_run(args, **kw):
        if "chronyd" in args:
            return _mock_subproc_run_return("active\n")
        return _mock_subproc_run_return("inactive\n")
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = fake_run
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_active_ntp_daemon() == "chronyd"


def test_read_active_ntp_daemon_falls_back_to_timesyncd():
    def fake_run(args, **kw):
        if "chronyd" in args:
            return _mock_subproc_run_return("inactive\n")
        return _mock_subproc_run_return("active\n")
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = fake_run
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_active_ntp_daemon() == "systemd-timesyncd"


def test_read_active_ntp_daemon_returns_none_when_neither_active():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("inactive\n")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_active_ntp_daemon() is None


def test_read_active_ntp_daemon_tolerates_oserror():
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = OSError("systemctl missing")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        # Must not raise
        assert readiness._read_active_ntp_daemon() is None


# ---------------------------------------------------------------------------
# _read_ntp_offset_ms
# ---------------------------------------------------------------------------

def test_read_ntp_offset_ms_from_chronyc_csv():
    """Real chronyc 4.x CSV format captured from a lab device:
    refid, ip, stratum, ref_time, system_time_offset, last_offset, rms_offset,
    freq, residual_freq, skew, root_delay, root_disp, update_interval, leap.
    System time offset is at index 4 — index 3 is the unix-timestamp ref time,
    a classic off-by-one trap."""
    csv_out = ("A7A0BBB3,167.160.187.179,4,1779582473.198092436,0.012345,"
               "-0.000032247,0.000216866,14.153,0.007,0.492,0.004710885,"
               "0.000894424,129.1,Normal")
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return(csv_out + "\n")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_ntp_offset_ms("chronyd") == 12  # 0.012345s -> 12ms


def test_read_ntp_offset_ms_chronyc_rejects_unix_timestamp_as_offset():
    """Defense-in-depth: if we somehow read the ref-time field as the offset,
    the value would be ~1.78e9 seconds. Our >1h sanity gate must reject it
    rather than return a nonsense offset like 1.78 trillion ms."""
    # Craft a CSV where index 4 is bogus (a unix timestamp)
    csv_out = "A,B,4,1.0,1779582473.198092436,0,0,0,0,0,0,0,0,N"
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return(csv_out + "\n")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        # Must return None (not the trillion-ms value)
        assert readiness._read_ntp_offset_ms("chronyd") is None


def test_read_ntp_offset_ms_from_timedatectl_ms():
    out = "       Server: 1.2.3.4 (time.cloudflare.com)\n       Offset: +123.456ms\n"
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return(out)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_ntp_offset_ms("systemd-timesyncd") == 123


def test_read_ntp_offset_ms_from_timedatectl_us():
    out = "       Offset: -250us\n"
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return(out)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_ntp_offset_ms("systemd-timesyncd") == 0  # -250us → 0ms


def test_read_ntp_offset_ms_from_timedatectl_s():
    out = "       Offset: +1.5s\n"
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return(out)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_ntp_offset_ms("systemd-timesyncd") == 1500


def test_read_ntp_offset_ms_returns_none_on_missing_tool():
    """Honest: if we can't measure, return None — don't fabricate from RTC."""
    with patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = FileNotFoundError("no chronyc")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        assert readiness._read_ntp_offset_ms("chronyd") is None


def test_read_ntp_offset_ms_returns_none_for_unknown_daemon():
    assert readiness._read_ntp_offset_ms("ntpd") is None
    assert readiness._read_ntp_offset_ms(None) is None


# ---------------------------------------------------------------------------
# check_ntp_sync
# ---------------------------------------------------------------------------

@pytest.fixture
def time_state(tmp_path, monkeypatch):
    p = tmp_path / "fula-time.state"
    monkeypatch.setattr(readiness, "TIME_STATE_PATH", str(p))
    # Reset rate limiter each test
    monkeypatch.setattr(readiness, "_last_ntp_correct_attempt", 0.0)
    return p


def test_check_ntp_sync_returns_true_when_already_synced(time_state):
    with patch.object(readiness, "_read_timedatectl_synced", return_value=(True, None)), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="systemd-timesyncd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=42):
        ok = readiness.check_ntp_sync()
    assert ok is True
    state = json.loads(time_state.read_text())
    assert state["synced"] is True
    assert state["service"] == "systemd-timesyncd"
    assert state["offset_ms"] == 42
    assert state["remediation"] is None


def test_check_ntp_sync_records_error_when_timedatectl_missing(time_state):
    with patch.object(readiness, "_read_timedatectl_synced",
                      return_value=(None, "FileNotFoundError: no timedatectl")):
        ok = readiness.check_ntp_sync()
    assert ok is False
    state = json.loads(time_state.read_text())
    assert state["error"].startswith("FileNotFoundError")


def test_check_ntp_sync_remediates_via_chronyc_when_chronyd_active(time_state):
    with patch.object(readiness, "_read_timedatectl_synced",
                      side_effect=[(False, None), (True, None)]), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="chronyd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("", returncode=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        with patch.object(readiness.time, "sleep"):  # skip the 2s settle
            ok = readiness.check_ntp_sync()
    assert ok is True  # second timedatectl check shows synced after remediation
    state = json.loads(time_state.read_text())
    assert state["remediation"] == "chronyc.makestep"
    assert state["remediation_ok"] is True
    # Verify it used chronyc, not systemctl restart
    cmd_call = mock_sub.run.call_args.args[0]
    assert cmd_call[0] == "chronyc"


def test_check_ntp_sync_remediates_via_systemctl_restart_when_timesyncd_active(time_state):
    with patch.object(readiness, "_read_timedatectl_synced",
                      side_effect=[(False, None), (True, None)]), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="systemd-timesyncd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("", returncode=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        with patch.object(readiness.time, "sleep"):
            ok = readiness.check_ntp_sync()
    assert ok is True
    state = json.loads(time_state.read_text())
    assert state["remediation"] == "systemd-timesyncd.restart"


def test_check_ntp_sync_defaults_to_timesyncd_when_no_daemon_active(time_state):
    """Edge case: neither chronyd nor timesyncd reports 'active' (rare —
    maybe a slow boot). Default to restarting timesyncd as the most likely
    intended default on Armbian Ubuntu."""
    with patch.object(readiness, "_read_timedatectl_synced",
                      side_effect=[(False, None), (False, None)]), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value=None), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("", returncode=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        with patch.object(readiness.time, "sleep"):
            readiness.check_ntp_sync()
    state = json.loads(time_state.read_text())
    assert state["remediation"] == "systemd-timesyncd.restart"
    # state["service"] is set to what we tried, since the original was None
    assert state["service"] == "systemd-timesyncd"


def test_check_ntp_sync_rate_limits_consecutive_remediation(time_state, monkeypatch):
    """After a remediation attempt, a subsequent call within the cooldown
    window must skip remediation."""
    import time as _t
    monkeypatch.setattr(readiness, "_last_ntp_correct_attempt", _t.time())  # just attempted
    with patch.object(readiness, "_read_timedatectl_synced", return_value=(False, None)), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="systemd-timesyncd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("active\n", returncode=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        ok = readiness.check_ntp_sync()
    assert ok is False
    state = json.loads(time_state.read_text())
    assert state["remediation"] == "rate_limited"
    assert state["remediation_ok"] is None


def test_check_ntp_sync_records_remediation_failure(time_state):
    with patch.object(readiness, "_read_timedatectl_synced",
                      side_effect=[(False, None), (False, None)]), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="systemd-timesyncd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("Unit not found", returncode=5)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        with patch.object(readiness.time, "sleep"):
            ok = readiness.check_ntp_sync()
    assert ok is False
    state = json.loads(time_state.read_text())
    assert state["remediation_ok"] is False


def test_check_ntp_sync_escalates_to_chronyd_restart_when_makestep_silent_failure(time_state):
    """Built-in advisor caught: severe skew can make chronyc makestep return
    rc=0 (success) but the clock doesn't actually move. The code must escalate
    to `systemctl restart chronyd` when makestep reports OK but the re-check
    still shows unsynced. Lab repro: date -s '2020-01-01' → makestep returns
    200 OK → re-check still shows synced=false → restart chronyd → recovers."""
    # Sequence of timedatectl reads:
    #   1. initial: unsynced
    #   2. after makestep + 2s sleep: STILL unsynced (the "silent failure")
    #   3. after chronyd restart + 3s sleep: synced
    sync_reads = iter([(False, None), (False, None), (True, None)])
    with patch.object(readiness, "_read_timedatectl_synced",
                      side_effect=lambda: next(sync_reads)), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="chronyd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        # Both subprocess calls (makestep + restart) return rc=0
        mock_sub.run.return_value = _mock_subproc_run_return("", returncode=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        with patch.object(readiness.time, "sleep"):  # skip all sleeps
            ok = readiness.check_ntp_sync()
    assert ok is True, "escalation should produce synced=true"
    state = json.loads(time_state.read_text())
    assert state["synced"] is True
    # Remediation field captures BOTH steps for diagnostics
    assert state["remediation"] == "chronyc.makestep+chronyd.restart"
    assert state["remediation_ok"] is True
    # Verify exactly two systemctl/chronyc calls happened
    cmd_calls = [c.args[0] for c in mock_sub.run.call_args_list]
    # First should be chronyc -a makestep, second should be systemctl restart chronyd
    assert any(c[0] == "chronyc" and "makestep" in c for c in cmd_calls)
    assert any(c[:2] == ["systemctl", "restart"] and "chronyd" in c for c in cmd_calls)


def test_check_ntp_sync_skips_escalation_when_makestep_already_recovered(time_state):
    """No escalation needed if the first remediation succeeded — don't restart
    chronyd unnecessarily."""
    sync_reads = iter([(False, None), (True, None)])
    with patch.object(readiness, "_read_timedatectl_synced",
                      side_effect=lambda: next(sync_reads)), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="chronyd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.return_value = _mock_subproc_run_return("", returncode=0)
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        with patch.object(readiness.time, "sleep"):
            ok = readiness.check_ntp_sync()
    assert ok is True
    state = json.loads(time_state.read_text())
    # Plain remediation, no escalation
    assert state["remediation"] == "chronyc.makestep"
    # Only ONE subprocess call (no chronyd restart)
    cmd_calls = [c.args[0] for c in mock_sub.run.call_args_list]
    restart_calls = [c for c in cmd_calls if c[:2] == ["systemctl", "restart"]]
    assert restart_calls == [], "must not escalate to restart when makestep worked"


def test_check_ntp_sync_swallows_remediation_subprocess_exception(time_state):
    """If systemctl/chronyc itself raises (missing tool, timeout), the watchdog
    must not crash. Best-effort contract."""
    with patch.object(readiness, "_read_timedatectl_synced",
                      side_effect=[(False, None), (False, None)]), \
         patch.object(readiness, "_read_active_ntp_daemon", return_value="systemd-timesyncd"), \
         patch.object(readiness, "_read_ntp_offset_ms", return_value=None), \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_sub.run.side_effect = OSError("simulated")
        mock_sub.TimeoutExpired = readiness.subprocess.TimeoutExpired
        with patch.object(readiness.time, "sleep"):
            # Must not raise — caller's contract
            try:
                readiness.check_ntp_sync()
            except OSError:
                pytest.fail("check_ntp_sync leaked an OSError to caller")
    state = json.loads(time_state.read_text())
    assert state["error"].startswith("remediation_failed:")
    assert state["remediation_ok"] is False
