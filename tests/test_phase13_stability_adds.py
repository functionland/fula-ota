"""Phase 13 tests — OOM + power + kubo-hang additions to readiness-check.py.

All 3 layers mocked at subprocess/sysfs/glob boundaries. Verifies state
files match Phase 9 diag/* schemas + escalation counter behaviour + env-flag
gating.
"""

import json
import os
from unittest.mock import patch, MagicMock

import pytest

from conftest import readiness


# ---------------------------------------------------------------------------
# Layer 1.5 — check_container_oom
# ---------------------------------------------------------------------------

def _fake_inspect(returncode=0, stdout=""):
    m = MagicMock()
    m.returncode = returncode
    m.stdout = stdout
    return m


def test_check_container_oom_writes_state_file(tmp_path, monkeypatch):
    state_path = tmp_path / "fula-containers.state"
    monkeypatch.setattr(readiness, "CONTAINERS_STATE_PATH", str(state_path))

    def fake_run(args, **kwargs):
        # Only fula_go exists; everything else returns nonzero (no container)
        if args[-1] == "fula_go":
            return _fake_inspect(0, "running|false|0|ipfs/kubo:latest|2026-05-24T07:00:00Z")
        return _fake_inspect(returncode=1, stdout="")

    with patch.object(readiness.subprocess, "run", side_effect=fake_run):
        readiness.check_container_oom()
    data = json.loads(state_path.read_text())
    assert data["containers"] == [{
        "name": "fula_go", "state": "running", "oom_killed": False,
        "restart_count": 0, "image": "ipfs/kubo:latest",
        "started_at": "2026-05-24T07:00:00Z",
    }]


def test_check_container_oom_logs_oom_event(tmp_path, monkeypatch):
    state_path = tmp_path / "fula-containers.state"
    events_path = tmp_path / "events.jsonl"
    monkeypatch.setattr(readiness, "CONTAINERS_STATE_PATH", str(state_path))
    monkeypatch.setattr(readiness, "EVENTS_LOG_PATH", str(events_path))

    def fake_run(args, **kwargs):
        if args[-1] == "ipfs_host":
            return _fake_inspect(0, "exited|true|5|ipfs/kubo:latest|2026-05-24T07:00:00Z")
        return _fake_inspect(returncode=1)

    with patch.object(readiness.subprocess, "run", side_effect=fake_run):
        readiness.check_container_oom()

    events = [json.loads(l) for l in events_path.read_text().splitlines() if l.strip()]
    oom_events = [e for e in events if e.get("category") == "container_oom"]
    assert len(oom_events) == 1
    assert oom_events[0]["detail"]["name"] == "ipfs_host"
    assert oom_events[0]["detail"]["restart_count"] == 5


def test_check_container_oom_coerces_unknown_state(tmp_path, monkeypatch):
    """Phase 9 schema enum: running/restarting/exited/paused/dead/created.
    Docker may report 'removing' or other — coerce to 'dead' so the schema
    doesn't reject the whole state file."""
    state_path = tmp_path / "fula-containers.state"
    monkeypatch.setattr(readiness, "CONTAINERS_STATE_PATH", str(state_path))
    with patch.object(readiness.subprocess, "run",
                       return_value=_fake_inspect(0, "removing|false|0|x|2026-01-01T00:00:00Z")):
        readiness.check_container_oom()
    data = json.loads(state_path.read_text())
    # All 9 candidates get the "removing" coerced response → all end up as dead
    for c in data["containers"]:
        assert c["state"] == "dead"


def test_check_container_oom_swallows_subprocess_failure(tmp_path, monkeypatch):
    """Best-effort: never raise out of the watchdog."""
    state_path = tmp_path / "fula-containers.state"
    monkeypatch.setattr(readiness, "CONTAINERS_STATE_PATH", str(state_path))
    with patch.object(readiness.subprocess, "run", side_effect=OSError("boom")):
        # Should not raise
        readiness.check_container_oom()
    # State file still written (empty containers list)
    data = json.loads(state_path.read_text())
    assert data == {"containers": []}


# ---------------------------------------------------------------------------
# Layer 1.6 — check_power_health
# ---------------------------------------------------------------------------

def test_check_power_health_writes_uptime_always(tmp_path, monkeypatch):
    """uptime_s is required by Phase 9 schema; even if everything else fails."""
    state_path = tmp_path / "fula-power.state"
    monkeypatch.setattr(readiness, "POWER_STATE_PATH", str(state_path))
    with patch.object(readiness.subprocess, "run", side_effect=OSError("no dmesg")), \
         patch.object(readiness, "_glob_paths", return_value=[]):
        readiness.check_power_health()
    data = json.loads(state_path.read_text())
    assert "uptime_s" in data
    assert isinstance(data["uptime_s"], int)


def test_check_power_health_counts_dmesg_events(tmp_path, monkeypatch):
    """Verifies the NARROW regex (2026-05-26 fix): only true undervoltage
    + brownout events count. Routine thermal/throttle kernel messages
    are NOT counted — temperature health is already captured separately
    as max_temp_c.

    Lab observed before fix: dmesg had 0 actual undervoltage events but
    the counter showed 6 because `thermal` matched benign kernel
    messages on healthy RK3588 boards. That falsely triggered the AI
    to report 'undervoltage emergency'.
    """
    state_path = tmp_path / "fula-power.state"
    monkeypatch.setattr(readiness, "POWER_STATE_PATH", str(state_path))

    dmesg_out = (
        # MUST count (3 true power events):
        "Sun May 24 07:00:00 2026 [    1.000] Undervoltage detected!\n"
        "Sun May 24 07:02:00 2026 [    3.000] brownout protector triggered\n"
        "Sun May 24 07:05:00 2026 [    6.000] under-voltage on rail 5V\n"
        # MUST NOT count (benign — these are normal on healthy RK3588):
        "Sun May 24 07:01:00 2026 [    2.000] thermal throttling cpu5\n"
        "Sun May 24 07:04:00 2026 [    5.000] rk3588-thermal: temperature update\n"
        "Sun May 24 07:06:00 2026 [    7.000] cpufreq: thermal throttle event\n"
        # MUST NOT count (recovery — same incident as the first event):
        "Sun May 24 07:00:30 2026 [    1.500] Undervoltage cleared, voltage OK\n"
        # MUST NOT count (unrelated):
        "Sun May 24 07:03:00 2026 [    4.000] normal log line\n"
    )

    def fake_run(args, **kwargs):
        if args[1] == "dmesg":
            return _fake_inspect(0, dmesg_out)
        if args[0] == "last":
            return _fake_inspect(0, "reboot   system boot  ...\nreboot   system boot  ...\n")
        return _fake_inspect(returncode=1)

    with patch.object(readiness.subprocess, "run", side_effect=fake_run), \
         patch.object(readiness, "_glob_paths", return_value=[]):
        readiness.check_power_health()
    data = json.loads(state_path.read_text())
    # 3 true power events; thermal/throttle/recovery lines excluded.
    assert data["undervoltage_events_24h"] == 3, (
        f"expected 3 true undervoltage+brownout events, got {data['undervoltage_events_24h']}; "
        "if higher, the regex is too broad (thermal/throttle leaking in)"
    )
    assert data["recent_reboots"] == 2


def test_check_power_health_skips_pure_thermal_throttle_noise(tmp_path, monkeypatch):
    """Regression guard: on a healthy RK3588 board, dmesg has many
    routine thermal/throttle messages but ZERO undervoltage. The
    counter MUST be 0 in that case. Lab bug 2026-05-26 had it at 6."""
    state_path = tmp_path / "fula-power.state"
    monkeypatch.setattr(readiness, "POWER_STATE_PATH", str(state_path))

    dmesg_out = (
        "Sun May 24 07:00:00 2026 [    1.000] rk3588-thermal: temperature update\n"
        "Sun May 24 07:01:00 2026 [    2.000] thermal_zone0: temperature changed\n"
        "Sun May 24 07:02:00 2026 [    3.000] cpufreq: thermal throttle event\n"
        "Sun May 24 07:03:00 2026 [    4.000] mali GPU: thermal limit reached\n"
        "Sun May 24 07:04:00 2026 [    5.000] thermal throttling cpu5\n"
    )
    def fake_run(args, **kwargs):
        if args[1] == "dmesg":
            return _fake_inspect(0, dmesg_out)
        if args[0] == "last":
            return _fake_inspect(0, "")
        return _fake_inspect(returncode=1)
    with patch.object(readiness.subprocess, "run", side_effect=fake_run), \
         patch.object(readiness, "_glob_paths", return_value=[]):
        readiness.check_power_health()
    data = json.loads(state_path.read_text())
    assert data["undervoltage_events_24h"] == 0, (
        f"healthy-board thermal noise leaked into undervoltage counter: "
        f"got {data['undervoltage_events_24h']}, expected 0"
    )


def test_check_power_health_max_thermal_zone(tmp_path, monkeypatch):
    state_path = tmp_path / "fula-power.state"
    monkeypatch.setattr(readiness, "POWER_STATE_PATH", str(state_path))

    fake_zones = [
        str(tmp_path / "zone0/temp"),
        str(tmp_path / "zone1/temp"),
    ]
    os.makedirs(os.path.dirname(fake_zones[0]))
    os.makedirs(os.path.dirname(fake_zones[1]))
    with open(fake_zones[0], "w") as f:
        f.write("55000\n")  # 55.0 C
    with open(fake_zones[1], "w") as f:
        f.write("72500\n")  # 72.5 C

    def fake_glob(pattern):
        if "thermal" in pattern:
            return fake_zones
        return []

    with patch.object(readiness.subprocess, "run", side_effect=OSError()), \
         patch.object(readiness, "_glob_paths", side_effect=fake_glob):
        readiness.check_power_health()
    data = json.loads(state_path.read_text())
    assert data["max_temp_c"] == 72.5


# ---------------------------------------------------------------------------
# Layer 1.7 — kubo hang escalation
# ---------------------------------------------------------------------------

def test_record_api_timeout_increments_streak():
    readiness._api_timeout_streak["kubo"] = 0
    readiness._record_api_timeout("kubo")
    assert readiness._api_timeout_streak["kubo"] == 1
    readiness._record_api_timeout("kubo")
    assert readiness._api_timeout_streak["kubo"] == 2


def test_record_api_success_resets_streak():
    readiness._api_timeout_streak["kubo"] = 5
    readiness._record_api_success("kubo")
    assert readiness._api_timeout_streak["kubo"] == 0


def test_record_api_timeout_unknown_component_is_noop():
    """Defensive: never KeyError if a future caller passes a new name."""
    assert readiness._record_api_timeout("fula_gateway") is False


def test_escalation_default_off_returns_false_at_threshold(monkeypatch):
    """With KUBO_HANG_ESCALATION_ENABLED=False (default), even 100 timeouts
    don't trigger escalation."""
    monkeypatch.setattr(readiness, "_KUBO_HANG_ESCALATION_ENABLED", False)
    readiness._api_timeout_streak["kubo"] = 0
    triggered = False
    for _ in range(10):
        if readiness._record_api_timeout("kubo"):
            triggered = True
    assert not triggered
    assert readiness._api_timeout_streak["kubo"] == 10


def test_escalation_when_enabled_fires_at_threshold(monkeypatch):
    monkeypatch.setattr(readiness, "_KUBO_HANG_ESCALATION_ENABLED", True)
    monkeypatch.setattr(readiness, "_KUBO_HANG_ESCALATION_STREAK_THRESHOLD", 3)
    readiness._api_timeout_streak["kubo"] = 0
    assert readiness._record_api_timeout("kubo") is False  # 1
    assert readiness._record_api_timeout("kubo") is False  # 2
    assert readiness._record_api_timeout("kubo") is True   # 3 → fire


def test_escalate_kubo_hang_resets_streak_after_run(tmp_path, monkeypatch):
    """After escalation runs (success path or kill path), the counter resets
    so the next cycle starts fresh."""
    monkeypatch.setattr(readiness, "_KUBO_HANG_ESCALATION_ENABLED", True)
    monkeypatch.setattr(readiness, "EVENTS_LOG_PATH", str(tmp_path / "events.jsonl"))
    readiness._api_timeout_streak["kubo"] = 5
    with patch.object(readiness.subprocess, "run", return_value=_fake_inspect(0, "")):
        readiness._escalate_kubo_hang("kubo")
    assert readiness._api_timeout_streak["kubo"] == 0


def test_escalate_kubo_hang_unknown_component_is_noop():
    """Defensive: bogus component name doesn't crash the escalation path."""
    # Should not raise
    readiness._escalate_kubo_hang("nonexistent")
