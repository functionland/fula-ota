"""Lab-device smoke test for Phase 1 (Layers 1.8 + 1.9).

Run this on the lab device after staging the modified files to /tmp/:
  python3 /tmp/lab_smoke_test_phase1.py

It imports the modified files via importlib and exercises:
- _atomic_write_state (Layer 1.8)
- _append_event with rotation off (Layer 1.8)
- _write_heartbeat_state (Layer 1.8)
- LocalCommandServer plugin extension hook (Layer 1.9)
- Plugin proxy returns typed error dicts on unreachable endpoint

All scratch state lands under /tmp/ so the running services are unaffected.
Prints "ALL SMOKE TESTS PASSED" on success; any exception bubbles up and
makes the script exit non-zero.
"""

import importlib.util
import json
import os
import shutil
import sys
import tempfile


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


print(">> loading modified readiness-check.py and local_command_server.py from /tmp/")
r = _load("readiness_check_new", "/tmp/readiness-check-NEW.py")
lcs = _load("local_command_server_new", "/tmp/local_command_server-NEW.py")

# ----- Layer 1.8: _atomic_write_state ---------------------------------------
test_state = "/tmp/fula-smoke-test.state"
r._atomic_write_state(test_state, {"smoke": True, "n": 42})
with open(test_state) as f:
    state = json.load(f)
assert state == {"smoke": True, "n": 42}, f"unexpected state: {state}"
print("OK: _atomic_write_state writes correct JSON")
os.unlink(test_state)

# ----- Layer 1.8: _append_event ---------------------------------------------
events_path = "/tmp/fula-smoke-events.jsonl"
old_log = r.EVENTS_LOG_PATH
r.EVENTS_LOG_PATH = events_path
try:
    r._append_event("smoke-test", {"hello": "world"})
    r._append_event("smoke-test", {"hello": "again", "n": 2})
    with open(events_path) as f:
        lines = f.read().strip().split("\n")
    assert len(lines) == 2, f"expected 2 lines, got {len(lines)}"
    rec0 = json.loads(lines[0])
    assert rec0["category"] == "smoke-test"
    assert rec0["detail"] == {"hello": "world"}
    assert rec0["ts"].endswith("Z")
    print("OK: _append_event creates and appends JSONL")
finally:
    if os.path.exists(events_path):
        os.unlink(events_path)
    r.EVENTS_LOG_PATH = old_log

# ----- Layer 1.8: _write_heartbeat_state ------------------------------------
hb_path = "/tmp/fula-smoke-hb.state"
old_hb = r.HEARTBEAT_STATE_PATH
r.HEARTBEAT_STATE_PATH = hb_path
try:
    r._write_heartbeat_state(http_status=200, error=None, circuit_count=3, reserved_on=["a.fx.land"])
    with open(hb_path) as f:
        hb = json.load(f)
    assert hb["http_status"] == 200
    assert hb["error"] is None
    assert hb["last_circuit_count"] == 3
    assert hb["last_reserved_on"] == ["a.fx.land"]
    assert hb["last_attempt_ts"].endswith("Z")
    print("OK: _write_heartbeat_state captures all fields")
finally:
    if os.path.exists(hb_path):
        os.unlink(hb_path)
    r.HEARTBEAT_STATE_PATH = old_hb

# ----- Layer 1.9: plugin extension hook -------------------------------------
tmpdir = tempfile.mkdtemp(prefix="fula-smoke-plugins-")
try:
    pdir = os.path.join(tmpdir, "smoke-plugin")
    os.makedirs(pdir)
    with open(os.path.join(pdir, "ble_commands.json"), "w") as f:
        json.dump({
            "plugin_id": "smoke",
            "commands": [
                {"name": "smoke/read", "type": "read",
                 "proxy_url": "http://127.0.0.1:65535/nope", "timeout_s": 1},
                {"name": "smoke/exec", "type": "exec",
                 "proxy_url": "http://127.0.0.1:65535/nope", "timeout_s": 1},
                {"name": "smoke/evil", "type": "read",
                 "proxy_url": "http://attacker.example.com/x", "timeout_s": 1},
                {"name": "smoke/bad_type", "type": "stream",
                 "proxy_url": "http://127.0.0.1:65535/nope", "timeout_s": 1},
            ],
        }, f)

    server = lcs.LocalCommandServer(
        plugin_manifest_glob=os.path.join(tmpdir, "*", "ble_commands.json"),
    )
    assert "smoke/read" in server.commands, f"read cmd missing: {list(server.commands.keys())}"
    assert "smoke/exec" in server.exec_commands, f"exec cmd missing: {list(server.exec_commands.keys())}"
    assert "smoke/evil" not in server.commands, "non-localhost URL must be rejected"
    assert "smoke/bad_type" not in server.commands, "stream type unsupported in Phase 1"
    print("OK: plugin scanner registers valid commands; rejects evil and bad-type")

    # Invoking should return a typed error dict (port 65535 closed).
    result = server.commands["smoke/read"]()
    assert isinstance(result, dict) and "error" in result, f"expected error dict, got: {result}"
    assert result["error"] in ("plugin_unreachable", "plugin_timeout", "plugin_request_failed"), \
        f"unexpected error type: {result}"
    print(f"OK: plugin proxy returns typed error dict ({result['error']})")

    # Reload after removing manifest should drop the commands cleanly.
    os.unlink(os.path.join(pdir, "ble_commands.json"))
    server.reload_plugins()
    assert "smoke/read" not in server.commands, "command should be unregistered after reload"
    assert "smoke/exec" not in server.exec_commands
    # Built-ins still intact.
    assert "ls" in server.commands
    assert "restart_fula" in server.exec_commands
    print("OK: reload_plugins removes plugin commands and preserves built-ins")
finally:
    shutil.rmtree(tmpdir)

print()
print("ALL SMOKE TESTS PASSED")
