"""Lab-device smoke test for Phase 3 — HTTPS reachability + NTP sync.

Run on device: python3 /tmp/lab_smoke_test_phase3.py

Loads the modified readiness-check.py from /tmp/readiness-check-NEW.py (so
we test the staged version, not the deployed one) and exercises both new
checks in three modes:

  1. Healthy path — discovery should be reachable, NTP should be synced
  2. State file inspection — verify the schema we'll surface via diag/*
  3. Failure mode hints — print what an injected failure SHOULD look like

It does NOT inject failures (those need iptables/date as root, handled in
a separate plink call). Just proves the functions execute on real systemd
without crashing and write the documented state file shapes.
"""
import importlib.util
import json
import os
import sys
import tempfile


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


print(">> loading modified readiness-check.py from /tmp/readiness-check-NEW.py")
r = _load("readiness_check_new", "/tmp/readiness-check-NEW.py")

# Redirect state files into /tmp so the running daemon's files are untouched.
r.DISCOVERY_STATE_PATH = "/tmp/fula-discovery.state.smoke"
r.TIME_STATE_PATH = "/tmp/fula-time.state.smoke"

# Reset rate-limit so check_ntp_sync attempts remediation if needed
r._last_ntp_correct_attempt = 0.0

print()
print("=== TEST 1: check_discovery_https_reachable() ===")
ok = r.check_discovery_https_reachable()
print(f"returned: {ok}")
with open(r.DISCOVERY_STATE_PATH) as f:
    state = json.load(f)
print(f"state file ({r.DISCOVERY_STATE_PATH}):")
print(json.dumps(state, indent=2))
assert "last_check_ts" in state and state["last_check_ts"].endswith("Z"), \
    "missing or wrong format last_check_ts"
assert "url" in state and state["url"].endswith("/relays"), \
    f"unexpected URL: {state.get('url')!r}"
assert "ok" in state and isinstance(state["ok"], bool), "ok must be bool"
assert "status_code" in state, "missing status_code field"
assert "latency_ms" in state, "missing latency_ms field"
assert "error" in state, "missing error field"
print("OK: discovery state schema verified")
os.unlink(r.DISCOVERY_STATE_PATH)

print()
print("=== TEST 2: check_ntp_sync() ===")
ok = r.check_ntp_sync()
print(f"returned: {ok}")
with open(r.TIME_STATE_PATH) as f:
    state = json.load(f)
print(f"state file ({r.TIME_STATE_PATH}):")
print(json.dumps(state, indent=2))
assert "last_check_ts" in state and state["last_check_ts"].endswith("Z")
assert "synced" in state
assert "service" in state
assert "offset_ms" in state
assert "remediation" in state
assert "remediation_ok" in state
assert "error" in state
print("OK: time state schema verified")
print(f"detected NTP daemon: {state['service']!r}")
print(f"NTP offset reported: {state['offset_ms']!r} ms (None means daemon's tool didn't expose one)")
os.unlink(r.TIME_STATE_PATH)

print()
print("ALL PHASE 3 SMOKE TESTS PASSED")
