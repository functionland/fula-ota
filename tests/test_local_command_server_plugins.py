"""Tests for the plugin BLE extension hook in local_command_server.py.

The hook lets plugins register BLE commands by dropping a ble_commands.json
manifest into /home/pi/.internal/plugins/<plugin>/. The server scans those
at startup, registers each declared command into the right dispatch dict
(self.commands for read, self.exec_commands for exec), and proxies BLE
invocations to the plugin's local HTTP endpoint.

These tests use a tmp_path-scoped manifest glob so they don't touch the
real /home/pi tree, and patch requests.post on the loaded module so they
don't hit the network.
"""

import json
from unittest.mock import MagicMock, patch

import pytest
import requests

from conftest import local_command_server


def _write_manifest(plugin_dir, plugin_id, commands):
    """Write a ble_commands.json under plugin_dir/<plugin_id>/ and return
    the full glob pattern caller should pass to LocalCommandServer."""
    plugin_dir.mkdir(parents=True, exist_ok=True)
    pdir = plugin_dir / plugin_id
    pdir.mkdir()
    (pdir / "ble_commands.json").write_text(json.dumps({
        "plugin_id": plugin_id,
        "commands": commands,
    }))


def _make_server(tmp_path):
    return local_command_server.LocalCommandServer(
        plugin_manifest_glob=str(tmp_path / "*" / "ble_commands.json"),
    )


# ---------------------------------------------------------------------------
# Manifest scanner
# ---------------------------------------------------------------------------

def test_scanner_registers_read_command_into_commands_dict(tmp_path):
    _write_manifest(tmp_path, "blox-ai", [
        {"name": "diag/internet", "type": "read",
         "proxy_url": "http://127.0.0.1:8083/diag/internet", "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    assert "diag/internet" in s.commands
    assert "diag/internet" not in s.exec_commands
    assert s.plugin_commands["diag/internet"]["plugin_id"] == "blox-ai"


def test_scanner_registers_exec_command_into_exec_commands_dict(tmp_path):
    _write_manifest(tmp_path, "blox-ai", [
        {"name": "ai/execute", "type": "exec",
         "proxy_url": "http://127.0.0.1:8083/execute-action", "timeout_s": 60},
    ])
    s = _make_server(tmp_path)
    assert "ai/execute" in s.exec_commands
    assert "ai/execute" not in s.commands


def test_scanner_skips_malformed_manifest_json(tmp_path):
    (tmp_path / "bad-plugin").mkdir()
    (tmp_path / "bad-plugin" / "ble_commands.json").write_text("{not valid json")
    s = _make_server(tmp_path)
    assert s.plugin_commands == {}


def test_scanner_skips_manifest_missing_plugin_id(tmp_path):
    (tmp_path / "noidplugin").mkdir()
    (tmp_path / "noidplugin" / "ble_commands.json").write_text(json.dumps({
        "commands": [{"name": "x/y", "type": "read", "proxy_url": "http://127.0.0.1:8083/x"}],
    }))
    s = _make_server(tmp_path)
    assert s.plugin_commands == {}


def test_scanner_skips_command_with_invalid_type(tmp_path):
    _write_manifest(tmp_path, "blox-ai", [
        {"name": "diag/fake", "type": "stream",  # stream not supported in this phase
         "proxy_url": "http://127.0.0.1:8083/x", "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    assert "diag/fake" not in s.commands
    assert "diag/fake" not in s.plugin_commands


def test_scanner_rejects_non_localhost_proxy_url(tmp_path):
    _write_manifest(tmp_path, "evil", [
        {"name": "evil/cmd", "type": "read",
         "proxy_url": "http://attacker.example.com/x", "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    assert "evil/cmd" not in s.commands


@pytest.mark.parametrize("evil_url", [
    "http://127.0.0.1.attacker.com/x",   # subdomain prefix bypass
    "http://localhost.attacker.com/x",   # subdomain prefix bypass
    "http://127.0.0.1@attacker.com/x",   # userinfo confusion
    "http://localhost@attacker.com/x",   # userinfo confusion
    "https://127.0.0.1/x",                # https not allowed (only http)
    "file:///etc/passwd",                 # non-http scheme
    "//127.0.0.1/x",                      # missing scheme
    "http://127.0.0.2/x",                 # close-but-not-loopback IP
    "http://0.0.0.0/x",                   # any-interface, not loopback
])
def test_scanner_rejects_localhost_bypass_attempts(tmp_path, evil_url):
    """urlparse-based hostname check must reject these — startswith() would
    have accepted several of them, exposing a real SSRF-style hole where a
    plugin can route BLE proxy traffic to attacker-controlled hosts."""
    _write_manifest(tmp_path, "evil", [
        {"name": "evil/cmd", "type": "read", "proxy_url": evil_url, "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    assert "evil/cmd" not in s.commands, f"bypass via {evil_url!r} was accepted"
    assert "evil/cmd" not in s.exec_commands


@pytest.mark.parametrize("ok_url", [
    "http://127.0.0.1/x",
    "http://127.0.0.1:8083/x",
    "http://localhost/x",
    "http://localhost:8083/diag/internet",
    "http://[::1]/x",
    "http://[::1]:8083/x",
])
def test_scanner_accepts_canonical_localhost_urls(tmp_path, ok_url):
    _write_manifest(tmp_path, "blox-ai", [
        {"name": "diag/test", "type": "read", "proxy_url": ok_url, "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    assert "diag/test" in s.commands, f"valid localhost url {ok_url!r} was rejected"


def test_scanner_handles_no_plugins(tmp_path):
    s = _make_server(tmp_path)
    assert s.plugin_commands == {}
    # Built-ins still present.
    assert "ls" in s.commands
    assert "restart_fula" in s.exec_commands


def test_reload_removes_old_plugin_commands_then_re_registers(tmp_path):
    _write_manifest(tmp_path, "blox-ai", [
        {"name": "diag/one", "type": "read",
         "proxy_url": "http://127.0.0.1:8083/one", "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    assert "diag/one" in s.commands

    # Plugin uninstalled: remove the manifest, reload, command should go away.
    (tmp_path / "blox-ai" / "ble_commands.json").unlink()
    s.reload_plugins()
    assert "diag/one" not in s.commands
    assert "diag/one" not in s.plugin_commands

    # Plugin re-installed with a different command: should register fresh.
    _write_manifest(tmp_path, "blox-ai-v2", [
        {"name": "diag/two", "type": "read",
         "proxy_url": "http://127.0.0.1:8083/two", "timeout_s": 5},
    ])
    s.reload_plugins()
    assert "diag/two" in s.commands


# ---------------------------------------------------------------------------
# HTTP proxy handler
# ---------------------------------------------------------------------------

def _install_plugin_with_proxy(tmp_path, name, url, timeout_s=5, cmd_type="read"):
    _write_manifest(tmp_path, "blox-ai", [
        {"name": name, "type": cmd_type, "proxy_url": url, "timeout_s": timeout_s},
    ])
    return _make_server(tmp_path)


def test_proxy_returns_parsed_json_on_2xx(tmp_path):
    s = _install_plugin_with_proxy(tmp_path, "diag/x", "http://127.0.0.1:8083/x")
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {"ok": True, "value": 42}
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.return_value = resp
        # Reuse the real exception classes so isinstance checks in the handler still work.
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.commands["diag/x"]()
    assert out == {"ok": True, "value": 42}
    # Posted to the configured URL with empty body and a sane User-Agent.
    call = mock_req.post.call_args
    assert call.args[0] == "http://127.0.0.1:8083/x"
    assert call.kwargs["json"] == {}
    assert "User-Agent" in call.kwargs["headers"]
    # CRITICAL: allow_redirects must be False. Per Gemini + Codex review, allowing
    # redirects would let a localhost endpoint 30x us to an arbitrary external
    # host, bypassing the URL-allowlist that's the entire point of the check.
    assert call.kwargs["allow_redirects"] is False, "redirect-following must be disabled"


def test_proxy_does_not_follow_redirect_to_external_host(tmp_path):
    """If the plugin's localhost endpoint returns a 30x to an external host,
    the proxy must NOT follow it. Treat the redirect itself as the response
    (status_code 302 → plugin_http_error since it's not 2xx)."""
    s = _install_plugin_with_proxy(tmp_path, "diag/x", "http://127.0.0.1:8083/x")
    resp = MagicMock()
    resp.status_code = 302
    resp.headers = {"Location": "http://attacker.example.com/leak"}
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.return_value = resp
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.commands["diag/x"]()
    # We get back the 302 as an http_error — proxy did NOT call attacker.example.com.
    assert out["error"] == "plugin_http_error"
    assert out["status_code"] == 302
    # Verify only ONE post happened (to the original localhost URL, not the redirect target).
    assert mock_req.post.call_count == 1
    assert mock_req.post.call_args.args[0] == "http://127.0.0.1:8083/x"


def test_plugin_cannot_shadow_builtin_read_command(tmp_path):
    """A malicious manifest must NOT be able to override built-in `ls`, `df`, etc.
    Collision should fail closed (REJECT), not warn-and-override."""
    _write_manifest(tmp_path, "evil", [
        {"name": "ls", "type": "read",
         "proxy_url": "http://127.0.0.1:8083/evil", "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    # Built-in ls is preserved (it's a method, not a proxy handler).
    assert s.commands["ls"] == s._combine_ls_outputs
    # The plugin's `ls` was rejected — not in plugin_commands.
    assert "ls" not in s.plugin_commands


def test_plugin_cannot_shadow_builtin_exec_command(tmp_path):
    """A malicious manifest must NOT be able to override built-in `restart_fula`,
    `reset`, `wireguard/start`, etc. via the exec dispatch."""
    _write_manifest(tmp_path, "evil", [
        {"name": "restart_fula", "type": "exec",
         "proxy_url": "http://127.0.0.1:8083/evil", "timeout_s": 5},
        {"name": "reset", "type": "exec",
         "proxy_url": "http://127.0.0.1:8083/evil", "timeout_s": 5},
    ])
    s = _make_server(tmp_path)
    assert s.exec_commands["restart_fula"] == 'sudo systemctl restart fula'
    assert "restart_fula" not in s.plugin_commands
    assert "reset" not in s.plugin_commands


def test_plugin_cannot_collide_across_read_and_exec_dispatch(tmp_path):
    """If plugin A registers read 'x' and plugin B registers exec 'x', the
    second registration must be rejected — they'd otherwise both exist (in
    different dispatch dicts) but plugin_commands could only track one,
    making reload/unregister behavior unsound."""
    (tmp_path / "plugin-a").mkdir()
    (tmp_path / "plugin-a" / "ble_commands.json").write_text(json.dumps({
        "plugin_id": "plugin-a",
        "commands": [{"name": "x/shared", "type": "read",
                      "proxy_url": "http://127.0.0.1:8083/a", "timeout_s": 5}],
    }))
    (tmp_path / "plugin-b").mkdir()
    (tmp_path / "plugin-b" / "ble_commands.json").write_text(json.dumps({
        "plugin_id": "plugin-b",
        "commands": [{"name": "x/shared", "type": "exec",
                      "proxy_url": "http://127.0.0.1:8083/b", "timeout_s": 5}],
    }))
    s = _make_server(tmp_path)
    # First plugin (alphabetical sort: plugin-a < plugin-b) registers normally.
    assert "x/shared" in s.commands
    assert s.plugin_commands["x/shared"]["plugin_id"] == "plugin-a"
    # Second plugin's collision is rejected, NOT silently slipped into exec_commands.
    assert "x/shared" not in s.exec_commands


def test_proxy_returns_error_on_timeout(tmp_path):
    s = _install_plugin_with_proxy(tmp_path, "diag/x", "http://127.0.0.1:8083/x")
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.side_effect = requests.Timeout()
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.commands["diag/x"]()
    assert out["error"] == "plugin_timeout"
    assert out["plugin"] == "blox-ai"
    assert out["command"] == "diag/x"


def test_proxy_returns_error_on_connection_refused(tmp_path):
    s = _install_plugin_with_proxy(tmp_path, "diag/x", "http://127.0.0.1:8083/x")
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.side_effect = requests.ConnectionError()
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.commands["diag/x"]()
    assert out["error"] == "plugin_unreachable"


def test_proxy_returns_error_on_non_2xx_status(tmp_path):
    s = _install_plugin_with_proxy(tmp_path, "diag/x", "http://127.0.0.1:8083/x")
    resp = MagicMock()
    resp.status_code = 500
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.return_value = resp
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.commands["diag/x"]()
    assert out["error"] == "plugin_http_error"
    assert out["status_code"] == 500


def test_proxy_returns_error_on_invalid_json_response(tmp_path):
    s = _install_plugin_with_proxy(tmp_path, "diag/x", "http://127.0.0.1:8083/x")
    resp = MagicMock()
    resp.status_code = 200
    resp.json.side_effect = ValueError("not json")
    resp.text = "<html>oops</html>"
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.return_value = resp
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.commands["diag/x"]()
    assert out["error"] == "plugin_invalid_json"
    assert "body_preview" in out


# ---------------------------------------------------------------------------
# Integration with the existing get_logs dispatch
# ---------------------------------------------------------------------------

def test_plugin_read_command_dispatches_via_get_logs_system(tmp_path):
    s = _install_plugin_with_proxy(tmp_path, "diag/sample", "http://127.0.0.1:8083/sample")
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {"sample": "ok"}
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.return_value = resp
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.get_logs(json.dumps({"system": ["diag/sample"]}))
    assert out["system"]["diag/sample"] == {"sample": "ok"}


def test_plugin_exec_command_dispatches_via_get_logs_exec(tmp_path):
    s = _install_plugin_with_proxy(
        tmp_path, "ai/execute", "http://127.0.0.1:8083/execute-action", cmd_type="exec",
    )
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {"executed": True}
    with patch.object(local_command_server, "requests") as mock_req:
        mock_req.post.return_value = resp
        mock_req.Timeout = requests.Timeout
        mock_req.ConnectionError = requests.ConnectionError
        mock_req.RequestException = requests.RequestException
        out = s.get_logs(json.dumps({"exec": ["ai/execute"]}))
    assert out["exec"]["ai/execute"] == {"executed": True}
