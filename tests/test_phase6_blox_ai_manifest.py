"""Phase 6 tests for the blox-ai plugin BLE manifest.

These tests guard the JSON contract that the Phase 1.9 plugin scanner reads
out of /home/pi/.internal/plugins/blox-ai/ble_commands.json.

The Phase 6 manifest deliberately ships 15 commands. The plan's full 16th
entry — ai/troubleshoot of type "stream" — is held back until Phase 12 adds
stream support to the core scanner; today
local_command_server._VALID_PLUGIN_COMMAND_TYPES is {"read", "exec"} and a
stream entry would be silently dropped, so we don't ship one.
"""

import json
import os
import shutil

import pytest

from conftest import local_command_server

# Resolve the actual repo manifest path so tests catch drift between the
# Phase 6 plan and what ships in the plugin dir.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_MANIFEST_PATH = os.path.join(
    _REPO_ROOT,
    "docker", "fxsupport", "linux", "plugins", "blox-ai", "ble_commands.json",
)


# ---------------------------------------------------------------------------
# Static shape checks — fail loudly if someone hand-edits the manifest
# ---------------------------------------------------------------------------

def test_manifest_file_exists():
    assert os.path.isfile(_MANIFEST_PATH), (
        f"Phase 6 ships ble_commands.json at {_MANIFEST_PATH}"
    )


def test_manifest_is_valid_json():
    with open(_MANIFEST_PATH) as f:
        data = json.load(f)
    assert isinstance(data, dict)
    assert data.get("plugin_id") == "blox-ai"
    assert isinstance(data.get("commands"), list)


def test_manifest_command_count_at_least_15_phase_6_baseline():
    """Phase 6 shipped 15 commands. Later phases may add (Phase 11 added
    ai/user-reply + ai/phone-context → 17). Any future REMOVAL trips this
    test. Phase-specific exact-count assertions live in each phase's
    test file (e.g. test_ble_manifest_has_17_commands_after_phase_11).
    """
    with open(_MANIFEST_PATH) as f:
        data = json.load(f)
    assert len(data["commands"]) >= 15, (
        f"Phase 6 baseline is 15 commands (4 ai/* + 11 diag/*); got "
        f"{len(data['commands'])} — a command was removed?"
    )


def test_manifest_has_no_stream_typed_commands_yet():
    # Per Phase 6 advisor consensus (Codex high-confidence): hold the
    # stream entry until Phase 12 lands stream support in the core scanner.
    with open(_MANIFEST_PATH) as f:
        data = json.load(f)
    types = {c["type"] for c in data["commands"]}
    assert types <= {"read", "exec"}, (
        f"manifest has unsupported types {types - {'read', 'exec'}}; "
        "core scanner only knows read/exec today"
    )


def test_every_command_has_required_fields():
    with open(_MANIFEST_PATH) as f:
        data = json.load(f)
    for cmd in data["commands"]:
        assert "name" in cmd, f"command missing name: {cmd}"
        assert "type" in cmd, f"command missing type: {cmd}"
        assert "proxy_url" in cmd, f"command missing proxy_url: {cmd}"
        assert "timeout_s" in cmd, f"command missing timeout_s: {cmd}"
        # Localhost-only — the scanner's _make_plugin_proxy_handler
        # rejects non-localhost URLs anyway, but catching it here gives a
        # better error message than a runtime registration WARN.
        assert cmd["proxy_url"].startswith("http://127.0.0.1:"), (
            f"non-localhost proxy URL would be rejected: {cmd['proxy_url']}"
        )
        assert isinstance(cmd["timeout_s"], (int, float))
        assert cmd["timeout_s"] > 0


def test_command_names_are_namespaced():
    # Plugins must namespace their commands so they don't collide with
    # core or other plugins. The scanner ALSO enforces this fail-closed,
    # but a manifest-level check catches typos before deploy.
    with open(_MANIFEST_PATH) as f:
        data = json.load(f)
    for cmd in data["commands"]:
        assert "/" in cmd["name"], (
            f"command {cmd['name']!r} is not namespaced (e.g. ai/X or diag/X)"
        )
        ns = cmd["name"].split("/", 1)[0]
        assert ns in ("ai", "diag"), (
            f"unexpected namespace {ns!r} in {cmd['name']!r}; "
            "Phase 6 ships only ai/* and diag/*"
        )


def test_exec_commands_with_destructive_side_effects_require_approval():
    # ai/execute hits the action_executor (Phase 10) and must always
    # require user approval. ai/cancel is also exec but is non-destructive
    # (just stops an in-flight LLM session) so no approval flag needed.
    with open(_MANIFEST_PATH) as f:
        data = json.load(f)
    by_name = {c["name"]: c for c in data["commands"]}
    assert by_name["ai/execute"].get("require_approval") is True, (
        "ai/execute must set require_approval:true — it runs whitelisted "
        "destructive actions on the device"
    )


def test_ai_troubleshoot_is_NOT_present():
    # If someone reintroduces it before Phase 12 they'd silently lose it
    # to the scanner's type validation. Better to fail the test.
    with open(_MANIFEST_PATH) as f:
        data = json.load(f)
    names = {c["name"] for c in data["commands"]}
    assert "ai/troubleshoot" not in names, (
        "ai/troubleshoot is held back until Phase 12; today the scanner "
        "would silently drop it (type='stream' not in _VALID_PLUGIN_COMMAND_TYPES)"
    )


# ---------------------------------------------------------------------------
# Integration with the real Phase 1.9 scanner
# ---------------------------------------------------------------------------

def _stage_manifest(tmp_path, manifest_src):
    """Copy the real ble_commands.json into a tmp plugin dir so we can
    point LocalCommandServer's glob at it without touching /home/pi."""
    pdir = tmp_path / "blox-ai"
    pdir.mkdir()
    shutil.copy(manifest_src, pdir / "ble_commands.json")
    return str(tmp_path / "*" / "ble_commands.json")


def test_scanner_registers_every_manifest_command(tmp_path):
    glob = _stage_manifest(tmp_path, _MANIFEST_PATH)
    s = local_command_server.LocalCommandServer(plugin_manifest_glob=glob)

    with open(_MANIFEST_PATH) as f:
        manifest = json.load(f)

    # Every command landed in either the read or exec dispatch dict.
    for cmd in manifest["commands"]:
        target = s.commands if cmd["type"] == "read" else s.exec_commands
        assert cmd["name"] in target, (
            f"{cmd['name']} ({cmd['type']}) did not register"
        )
        # And the plugin_commands index tracks it.
        assert cmd["name"] in s.plugin_commands
        assert s.plugin_commands[cmd["name"]]["plugin_id"] == "blox-ai"


def test_scanner_registers_all_diag_namespace_as_reads(tmp_path):
    glob = _stage_manifest(tmp_path, _MANIFEST_PATH)
    s = local_command_server.LocalCommandServer(plugin_manifest_glob=glob)

    diag_names = [n for n in s.plugin_commands if n.startswith("diag/")]
    # Phase 6 shipped 11 diag/* probes; Phase 0.5 grew the palette (now 22,
    # incl. diag/bundle). The palette is additive, so assert the floor here —
    # the exact AI-tool set is pinned in test_phase9 (tool enum == diag/* minus
    # bundle). What matters in THIS test is that every diag/* is a read below.
    assert len(diag_names) >= 11, f"expected >=11 diag/* commands, got {diag_names}"
    for n in diag_names:
        # diag/* must be in the read dispatch dict — they're side-effect-free
        # probes. If a diag/* slipped into exec_commands it would silently
        # become a security-prompted command in the BLE UX.
        assert n in s.commands, f"{n} should be a read command"
        assert n not in s.exec_commands, f"{n} should not be an exec command"


def test_scanner_does_not_clobber_existing_built_in_commands(tmp_path):
    """Sanity guard: blox-ai commands all use ai/ or diag/ namespaces and
    must not shadow any built-in. The scanner enforces this fail-closed
    (collision → REJECT) — this test confirms the manifest as-written
    doesn't trip that path."""
    glob = _stage_manifest(tmp_path, _MANIFEST_PATH)
    # Pre-scan with an unmatchable glob — passing None would fall back to
    # the production /home/pi glob, which on a dev machine that happens to
    # have a blox-ai install would taint this baseline.
    empty_dir = tmp_path / "_empty"
    empty_dir.mkdir()
    pre = local_command_server.LocalCommandServer(
        plugin_manifest_glob=str(empty_dir / "no-match" / "ble_commands.json"),
    )
    pre_read_names = set(pre.commands.keys())
    pre_exec_names = set(pre.exec_commands.keys())

    post = local_command_server.LocalCommandServer(plugin_manifest_glob=glob)

    with open(_MANIFEST_PATH) as f:
        manifest = json.load(f)
    manifest_names = {c["name"] for c in manifest["commands"]}

    # No manifest command shadows a built-in.
    assert manifest_names.isdisjoint(pre_read_names), (
        f"manifest commands collide with built-ins: "
        f"{manifest_names & pre_read_names}"
    )
    assert manifest_names.isdisjoint(pre_exec_names)

    # Every built-in is still present after scan.
    assert pre_read_names <= set(post.commands.keys())
    assert pre_exec_names <= set(post.exec_commands.keys())


def test_reload_plugins_is_idempotent(tmp_path):
    """install.sh touches /home/pi/commands/.command_plugin_reload after a
    successful install. The scanner reloads on that flag. Loading the same
    manifest twice must not leave duplicate or stale entries — important
    because Phase 6's uninstall.sh ALSO touches the flag after removing
    the manifest, and we never want a stale entry to keep proxying."""
    glob = _stage_manifest(tmp_path, _MANIFEST_PATH)
    s = local_command_server.LocalCommandServer(plugin_manifest_glob=glob)
    snapshot_a = sorted(s.plugin_commands.keys())

    # Second scan from the same manifest.
    count = s.reload_plugins()
    snapshot_b = sorted(s.plugin_commands.keys())

    assert snapshot_a == snapshot_b, "reload diverged from initial scan"
    # Count should match actual manifest size — additive across phases
    # (Phase 6: 15; Phase 11: 17). Compare against the manifest length
    # rather than a hardcoded number.
    with open(_MANIFEST_PATH) as f:
        manifest_count = len(json.load(f)["commands"])
    assert count == manifest_count

    # Now simulate the uninstall: remove the manifest, reload, every
    # blox-ai command must be gone.
    shutil.rmtree(tmp_path / "blox-ai")
    s.reload_plugins()
    assert s.plugin_commands == {}
    # And neither dispatch dict still has stale entries.
    for cmd in [c["name"] for c in json.load(open(_MANIFEST_PATH))["commands"]]:
        assert cmd not in s.commands
        assert cmd not in s.exec_commands


# ---------------------------------------------------------------------------
# active-plugins.txt rename migration (Phase 6 post-advisor fix)
# ---------------------------------------------------------------------------

def test_plugins_sh_contains_active_plugins_rename_migration():
    """plugins.sh must rewrite `loyal-agent` to `blox-ai` in
    active-plugins.txt at startup so users who had the prior slot enabled
    keep that opt-in across the rename. Both Gemini and Codex flagged the
    absence of this migration as high-confidence-must-fix in post-review."""
    plugins_sh = os.path.join(
        _REPO_ROOT, "docker", "fxsupport", "linux", "plugins.sh",
    )
    with open(plugins_sh) as f:
        body = f.read()
    # The exact sed pattern (anchored line) is what makes the migration
    # idempotent and safe — guard against future edits weakening it.
    assert "sed -i 's/^loyal-agent$/blox-ai/'" in body, (
        "plugins.sh must contain the anchored sed rewrite of "
        "loyal-agent -> blox-ai in active-plugins.txt"
    )
    # And it must run against both the active and update files, because
    # both can carry the legacy name on canary devices.
    assert "${ACTIVE_PLUGINS_FILE}" in body
    assert "${UPDATE_PLUGIN_FILE}" in body


def test_install_sh_uses_kb_precision_ram_gate_principle_preserved():
    """The KB-precision RAM gate (not integer-GB) is a lab-caught lesson
    that survives across phases. Phase 6 introduced the principle at 7 GB
    threshold (for 8 GB-spec devices); Phase 8 lowered to 3.3 GB
    (for 4 GB-spec devices, with the smaller Qwen 3B model). Either way,
    the COMPARISON must be `RAM_KB -lt $RAM_MIN_KB` with the threshold
    in KB — never `RAM_GB -lt N` integer math. See
    test_install_sh_ram_gate_is_3460032_kb in test_phase8_model_swap.py
    for the current-phase threshold."""
    install_sh = os.path.join(
        _REPO_ROOT,
        "docker", "fxsupport", "linux", "plugins", "blox-ai", "install.sh",
    )
    with open(install_sh) as f:
        body = f.read()
    import re
    # Some RAM_MIN_KB must be defined (specific value owned by Phase 8 test)
    m = re.search(r"RAM_MIN_KB=(\d+)", body)
    assert m, "install.sh must define RAM_MIN_KB (KB-precision threshold)"
    # Comparison must be in KB, not GB
    assert 'RAM_KB" -lt "$RAM_MIN_KB"' in body, (
        "Comparison must be against RAM_KB in KB, not RAM_GB in GB."
    )
    # Old integer-GB checks must be GONE — they're the bug Phase 6 lab caught
    assert 'RAM_GB" -lt 8' not in body, "Old 8 GB integer-GB check forbidden"
    assert 'RAM_GB" -lt 4' not in body, (
        "Don't reintroduce integer-GB math at 4 GB either — use KB threshold "
        "(see test_install_sh_ram_gate_is_3460032_kb)."
    )


def test_migration_shim_uses_timeout_around_docker_compose_down():
    """`docker-compose down` can hang indefinitely; `|| true` only handles
    non-zero exit. Direct install.sh has no outer wrapper. Wrap with
    `timeout 60` so a hang doesn't block the install path
    (Codex post-review high-confidence)."""
    for relpath in ("plugins/blox-ai/install.sh", "plugins/blox-ai/uninstall.sh"):
        p = os.path.join(_REPO_ROOT, "docker", "fxsupport", "linux", relpath)
        with open(p) as f:
            body = f.read()
        assert "timeout 60 docker-compose" in body, (
            f"{relpath}: migration shim must wrap `docker-compose down` in "
            "`timeout 60` to avoid indefinite hangs"
        )


def test_uninstall_sh_drops_global_docker_system_prune():
    """The prior loyal-agent uninstall.sh ran `docker system prune -f`,
    which removes unrelated stopped containers and dangling images from
    other plugins / user workloads. Phase 6 drops it per Codex
    post-review; the explicit `docker rm`/`docker rmi` we run is the
    scoped cleanup we actually need."""
    p = os.path.join(
        _REPO_ROOT,
        "docker", "fxsupport", "linux", "plugins", "blox-ai", "uninstall.sh",
    )
    with open(p) as f:
        body = f.read()
    # Allow the word in a comment that explains why it was removed, but
    # forbid an actual invocation (e.g. a fresh `docker system prune -f`
    # line at the start of a statement).
    import re
    invocations = re.findall(r"^\s*docker system prune", body, re.MULTILINE)
    assert invocations == [], (
        f"uninstall.sh still invokes `docker system prune`: {invocations}; "
        "remove it (the prior loyal-agent script's wide blast radius is "
        "what Codex flagged)"
    )
