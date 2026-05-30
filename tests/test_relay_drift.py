"""Tests for maybe_refresh_relays in readiness-check.py.

The function periodically asks the Discovery API for the current relay list
and triggers a kubo container restart if it differs from what's on disk.
We mock the `requests` and `subprocess` modules so tests don't hit the
network or touch docker.
"""

import json
from unittest.mock import patch, MagicMock

import pytest

from conftest import readiness


@pytest.fixture(autouse=True)
def reset_rate_limiter():
    """Ensure each test starts with the drift-check rate limiter cleared so
    the function actually executes its body."""
    readiness._last_relay_drift_check = 0
    yield


def _mk_response(status_code=200, payload=None):
    """Build a mock requests.Response."""
    m = MagicMock()
    m.status_code = status_code
    m.json.return_value = payload or []
    return m


def _seed_kubo_config(tmp_path, static_relays):
    """Write a minimal kubo config with a given StaticRelays list and
    point KUBO_CONFIG_PATH at it. Returns the path string."""
    cfg = {"Swarm": {"RelayClient": {"StaticRelays": list(static_relays)}}}
    p = tmp_path / "config"
    p.write_text(json.dumps(cfg))
    return str(p)


def test_no_restart_when_lists_match(tmp_path, monkeypatch):
    """Workers' relays match the on-disk StaticRelays → no docker restart."""
    on_disk = ["/dns/relay.dev.fx.land/tcp/4001/p2p/PA"]
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", _seed_kubo_config(tmp_path, on_disk))

    workers_response = [
        {"peerId": "PA", "addr": "/dns/relay.dev.fx.land/tcp/4001",
         "multiaddr": "/dns/relay.dev.fx.land/tcp/4001/p2p/PA"},
    ]
    with patch.object(readiness, "requests") as mock_req, \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_req.get.return_value = _mk_response(200, workers_response)
        readiness.maybe_refresh_relays()
        mock_sub.run.assert_not_called()


def test_restart_when_lists_differ(tmp_path, monkeypatch):
    """Workers returns a different relay set → kubo config is rewritten via
    update_kubo_config.py, THEN ipfs_host is restarted.

    The function does NOT restart kubo by itself anymore: `docker restart`
    alone reloads the same stale on-disk config, so the code first runs
    FULA_PATH/update_kubo_config.py to write the new StaticRelays and only
    restarts if that succeeds. We point FULA_PATH at a tmp dir holding a stub
    script so the existence guard passes, and make the mocked update step
    report returncode 0 so the flow proceeds to the restart."""
    on_disk = ["/dns/old.fx.land/tcp/4001/p2p/OLD"]
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", _seed_kubo_config(tmp_path, on_disk))
    monkeypatch.setattr(readiness, "FULA_PATH", str(tmp_path))
    (tmp_path / "update_kubo_config.py").write_text("# stub")

    workers_response = [
        {"peerId": "NEW", "addr": "/dns/new.fx.land/tcp/4001",
         "multiaddr": "/dns/new.fx.land/tcp/4001/p2p/NEW"},
    ]
    with patch.object(readiness, "requests") as mock_req, \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_req.get.return_value = _mk_response(200, workers_response)
        # update_kubo_config.py must "succeed" (rc 0) so the code reaches the
        # restart step. (A MagicMock default returncode is truthy → treated as
        # failure → would bail before the restart.)
        mock_sub.run.return_value.returncode = 0
        readiness.maybe_refresh_relays()

        calls = mock_sub.run.call_args_list
        # Step 1: the config-rewrite script runs.
        assert any(
            "update_kubo_config.py" in part
            for c in calls for part in c[0][0]
        ), f"update_kubo_config.py was not invoked; calls={calls}"
        # Step 2: ipfs_host is restarted exactly once.
        restart_calls = [
            c for c in calls
            if "docker" in c[0][0] and "restart" in c[0][0] and "ipfs_host" in c[0][0]
        ]
        assert len(restart_calls) == 1, f"expected one ipfs_host restart, got {calls}"


def test_no_restart_when_workers_unreachable(tmp_path, monkeypatch):
    """Workers throws → fetch_discovery_relays returns None → no restart."""
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", _seed_kubo_config(tmp_path, []))
    with patch.object(readiness, "requests") as mock_req, \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_req.get.side_effect = Exception("network down")
        # Must not propagate.
        readiness.maybe_refresh_relays()
        mock_sub.run.assert_not_called()


def test_no_restart_when_workers_returns_empty(tmp_path, monkeypatch):
    """Empty Workers response → None from fetch → no restart, falls back to
    existing on-disk relays."""
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", _seed_kubo_config(tmp_path, []))
    with patch.object(readiness, "requests") as mock_req, \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_req.get.return_value = _mk_response(200, [])
        readiness.maybe_refresh_relays()
        mock_sub.run.assert_not_called()


def test_rate_limit_blocks_second_call(tmp_path, monkeypatch):
    """A second invocation within RELAY_DRIFT_CHECK_INTERVAL_SEC is a no-op
    — no fetch, no restart, regardless of what Workers would return."""
    on_disk = ["/dns/old.fx.land/tcp/4001/p2p/OLD"]
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", _seed_kubo_config(tmp_path, on_disk))
    workers_response = [
        {"peerId": "NEW", "addr": "/dns/new.fx.land/tcp/4001",
         "multiaddr": "/dns/new.fx.land/tcp/4001/p2p/NEW"},
    ]
    with patch.object(readiness, "requests") as mock_req, \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_req.get.return_value = _mk_response(200, workers_response)
        readiness.maybe_refresh_relays()                # runs, restarts
        mock_req.get.reset_mock()
        mock_sub.run.reset_mock()
        # Second call immediately after — rate limiter blocks it.
        readiness.maybe_refresh_relays()
        mock_req.get.assert_not_called()
        mock_sub.run.assert_not_called()


def test_set_comparison_is_order_insensitive(tmp_path, monkeypatch):
    """If Workers returns the same set in a different order than on-disk,
    no restart — set semantics not list semantics."""
    on_disk = [
        "/dns/a.fx.land/tcp/4001/p2p/A",
        "/dns/b.fx.land/tcp/4001/p2p/B",
    ]
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", _seed_kubo_config(tmp_path, on_disk))
    workers_response = [
        {"peerId": "B", "addr": "/dns/b.fx.land/tcp/4001",
         "multiaddr": "/dns/b.fx.land/tcp/4001/p2p/B"},
        {"peerId": "A", "addr": "/dns/a.fx.land/tcp/4001",
         "multiaddr": "/dns/a.fx.land/tcp/4001/p2p/A"},
    ]
    with patch.object(readiness, "requests") as mock_req, \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_req.get.return_value = _mk_response(200, workers_response)
        readiness.maybe_refresh_relays()
        mock_sub.run.assert_not_called()


def test_no_crash_when_kubo_config_missing(monkeypatch):
    """If kubo config is missing, get_relay_multiaddrs returns the fallback
    multiaddr — and maybe_refresh_relays compares against that. Should not
    raise."""
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", "/no/such/path")
    workers_response = [
        {"peerId": "P", "addr": "/dns/x/tcp/4001", "multiaddr": "/dns/x/tcp/4001/p2p/P"},
    ]
    with patch.object(readiness, "requests") as mock_req, \
         patch.object(readiness, "subprocess") as mock_sub:
        mock_req.get.return_value = _mk_response(200, workers_response)
        # Just ensure it doesn't raise. It MAY restart (lists differ) — that's
        # acceptable; the point is robustness, not behavioral specificity.
        readiness.maybe_refresh_relays()
