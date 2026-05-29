"""Phase 7 tests for the AI plugin data files:
- action_whitelist.json (the trust boundary; Phase 10 enforces)
- runbook.md (RAG-style grounding the model loads at session start)
- docker-compose.yml mount surface for the container

Whitelist names align to actual local_command_server.py dispatch keys
wherever possible (per Gemini + Codex post-review consensus) so Phase 10's
executor doesn't need a translation table.
"""

import json
import os
import re

import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_WHITELIST_PATH = os.path.join(_PLUGIN_DIR, "action_whitelist.json")
_RUNBOOK_PATH = os.path.join(_PLUGIN_DIR, "runbook.md")
_COMPOSE_PATH = os.path.join(_PLUGIN_DIR, "docker-compose.yml")
_INSTALL_SH_PATH = os.path.join(_PLUGIN_DIR, "install.sh")
_FULA_SH_PATH = os.path.join(_REPO_ROOT, "docker", "fxsupport", "linux", "fula.sh")
_CORE_LCS_PATH = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "local_command_server.py",
)


# ---------------------------------------------------------------------------
# action_whitelist.json — schema + integrity
# ---------------------------------------------------------------------------

def test_whitelist_file_exists_and_is_valid_json():
    assert os.path.isfile(_WHITELIST_PATH)
    with open(_WHITELIST_PATH) as f:
        data = json.load(f)
    assert isinstance(data, dict)
    assert data.get("schema_version") == 1


def test_whitelist_has_required_top_level_keys():
    with open(_WHITELIST_PATH) as f:
        d = json.load(f)
    assert "tier_1_read" in d
    assert "tier_2_idempotent" in d
    assert "tier_3_destructive" in d
    assert "argument_constraints" in d


def test_whitelist_tier_3_actions_align_to_core_dispatch():
    """Per Gemini + Codex post-review (HIGH confidence): tier_3 entries
    that map_to_core MUST exist as keys in local_command_server.py's
    exec_commands dict so the Phase 10 executor can dispatch without a
    translation layer."""
    with open(_WHITELIST_PATH) as f:
        d = json.load(f)
    with open(_CORE_LCS_PATH) as f:
        lcs_body = f.read()
    tier_3 = d["tier_3_destructive"]["actions"]
    for action_name, meta in tier_3.items():
        if meta.get("maps_to_core") is True:
            # core has it in either commands or exec_commands as a string key
            pattern = rf"['\"]{re.escape(action_name)}['\"]\s*:"
            assert re.search(pattern, lcs_body), (
                f"tier_3 action {action_name!r} marked maps_to_core:true but "
                f"not found in local_command_server.py dispatch"
            )


def test_whitelist_tier_2_maps_to_core_actions_align():
    """Same as tier_3 but for the maps_to_core entries in tier_2."""
    with open(_WHITELIST_PATH) as f:
        d = json.load(f)
    with open(_CORE_LCS_PATH) as f:
        lcs_body = f.read()
    for action_name, meta in d["tier_2_idempotent"]["actions"].items():
        if meta.get("maps_to_core") is True:
            pattern = rf"['\"]{re.escape(action_name)}['\"]\s*:"
            assert re.search(pattern, lcs_body), (
                f"tier_2 action {action_name!r} marked maps_to_core:true but "
                f"not found in local_command_server.py dispatch"
            )


def test_whitelist_docker_restart_constraints_are_real_containers():
    """Every container in argument_constraints.docker.restart.container
    must actually exist in the fula stack docker-compose.yml (per Codex
    post-review HIGH: constraint list mustn't reference imaginary names)."""
    with open(_WHITELIST_PATH) as f:
        d = json.load(f)
    core_compose = os.path.join(
        _REPO_ROOT, "docker", "fxsupport", "linux", "docker-compose.yml",
    )
    with open(core_compose) as f:
        body = f.read()
    actual_containers = set(re.findall(r"container_name:\s*(\S+)", body))
    constrained = set(d["argument_constraints"]["docker.restart"]["container"])
    missing = constrained - actual_containers
    assert not missing, (
        f"docker.restart constraints reference non-existent containers: {missing}. "
        f"Stack has: {actual_containers}"
    )


def test_whitelist_systemctl_restart_constraints_are_real_units():
    """Per Codex post-review HIGH: every unit constrained must exist
    as a .service file under docker/fxsupport/linux/ (the canonical fula
    service set the runbook can recommend restarting)."""
    with open(_WHITELIST_PATH) as f:
        d = json.load(f)
    linux_dir = os.path.join(_REPO_ROOT, "docker", "fxsupport", "linux")
    found_units = set()
    for dirpath, _, filenames in os.walk(linux_dir):
        for fname in filenames:
            if fname.endswith(".service"):
                found_units.add(fname)
    for action_key in ("systemctl.restart", "systemctl.reset-failed"):
        constrained_units = set(
            d["argument_constraints"][action_key]["unit"]
        )
        missing = constrained_units - found_units
        assert not missing, (
            f"{action_key} constraints reference non-existent units: {missing}. "
            f"Available units in linux/ subtree: {sorted(found_units)}"
        )


def test_whitelist_namespacing_no_destructive_in_tier_2():
    """Sanity guard: nothing tier-3-shaped should leak into tier-2.
    tier-2 is single-tap-approval; destructive actions need security code."""
    with open(_WHITELIST_PATH) as f:
        d = json.load(f)
    tier_2_actions = set(d["tier_2_idempotent"]["actions"].keys())
    # These specific names mean DATA LOSS or DESTRUCTIVE RESET
    forbidden_in_tier_2 = {
        "reset", "node_delete", "ipfs_delete", "partition",
        "force_update", "system.reboot", "fula.reset",
    }
    leaked = tier_2_actions & forbidden_in_tier_2
    assert not leaked, (
        f"Destructive actions leaked into tier_2_idempotent: {leaked}. "
        "These must stay in tier_3_destructive (security code required)."
    )


# ---------------------------------------------------------------------------
# runbook.md — frontmatter + structure
# ---------------------------------------------------------------------------

def test_runbook_file_exists():
    assert os.path.isfile(_RUNBOOK_PATH)


def test_runbook_has_required_frontmatter():
    with open(_RUNBOOK_PATH, encoding="utf-8") as f:
        body = f.read()
    # YAML frontmatter between two --- fences at start of file
    m = re.match(r"^---\n([\s\S]+?)\n---", body)
    assert m, "runbook must open with --- frontmatter fence"
    frontmatter = m.group(1)
    assert re.search(r"runbook_version:\s*\d+", frontmatter)
    assert re.search(r"schema_version:\s*\d+", frontmatter)
    assert re.search(r"last_updated:\s*\d{4}-\d{2}-\d{2}", frontmatter)
    # Codex post-review: drop schema:phase-X-vN couples runtime data to
    # project history. Assert it's gone.
    assert "phase-" not in frontmatter, (
        "Runbook frontmatter must not reference Phase numbers (Codex review): "
        "schema_version is enough"
    )


def test_runbook_has_at_least_9_diagnostic_sections():
    """Plan section 3.2 commits to 9 top-level fault categories."""
    with open(_RUNBOOK_PATH, encoding="utf-8") as f:
        body = f.read()
    sections = re.findall(r"^## Section: ", body, re.MULTILINE)
    assert len(sections) >= 9, (
        f"runbook must have at least 9 ## Section: entries; found {len(sections)}"
    )


def test_runbook_cites_only_real_diag_commands():
    """Every `diag/<name>` referenced in the runbook must exist in the
    Phase 6 ble_commands.json — no hallucinated tool names."""
    with open(_RUNBOOK_PATH, encoding="utf-8") as f:
        body = f.read()
    referenced = set(re.findall(r"\b(diag/[a-z_]+)\b", body))
    ble_manifest = os.path.join(_PLUGIN_DIR, "ble_commands.json")
    with open(ble_manifest) as f:
        manifest = json.load(f)
    manifest_diag = {c["name"] for c in manifest["commands"] if c["name"].startswith("diag/")}
    # diag/* is a glob, allowed
    referenced -= {"diag/*"}
    bogus = referenced - manifest_diag
    assert not bogus, (
        f"runbook references diag/* commands that don't exist in manifest: {bogus}. "
        f"Manifest has: {sorted(manifest_diag)}"
    )


def test_runbook_cites_only_whitelisted_actions():
    """Per Codex post-review: tighten so EVERY action recommendation in the
    runbook is in the whitelist. Catches hallucinated names + drift between
    runbook content and whitelist. The recommendation lines have a fixed
    shape — `- Tier 2: `action_name` ...` or `- Tier 3: `action_name` ...`
    — so we can parse them strictly."""
    with open(_RUNBOOK_PATH, encoding="utf-8") as f:
        body = f.read()
    with open(_WHITELIST_PATH) as f:
        wl = json.load(f)
    all_whitelisted = set()
    for tier in ("tier_2_idempotent", "tier_3_destructive"):
        all_whitelisted |= set(wl[tier]["actions"].keys())

    # Find recommendation lines: `- Tier N: \`action_name\` ...` or
    # `- Tier N (...): \`action_name\` ...`
    recommendation_lines = re.findall(
        r"^- Tier [23][^`]*`([^`]+)`", body, re.MULTILINE,
    )
    referenced_actions = set(recommendation_lines)

    bogus = referenced_actions - all_whitelisted
    assert not bogus, (
        f"runbook recommends actions NOT in action_whitelist.json: {bogus}. "
        f"Whitelist has: {sorted(all_whitelisted)}"
    )

    # Also keep the old-name regression guard.
    old_draft_names = {
        "fula.reset", "system.reboot", "cluster.pebble_purge", "partition.expand",
    }
    quoted_anywhere = set(re.findall(r"`([a-z_][a-z_.]*)`", body))
    leaked = old_draft_names & quoted_anywhere
    assert not leaked, (
        f"runbook references the OLD draft action names: {leaked}. "
        f"These were renamed to align with local_command_server.py dispatch keys."
    )


def test_runbook_size_under_35kb():
    """Per Codex + Gemini post-review HIGH: keep runbook ≤ 35 KB so the
    model has headroom for user prompt, diag tool traces, and conversation."""
    size = os.path.getsize(_RUNBOOK_PATH)
    assert size < 35000, (
        f"runbook is {size} bytes; advisor consensus is keep < 35000"
    )


# ---------------------------------------------------------------------------
# docker-compose.yml mount surface
# ---------------------------------------------------------------------------

def test_compose_has_all_5_phase_7_mounts():
    with open(_COMPOSE_PATH, encoding="utf-8") as f:
        body = f.read()
    required_mounts = [
        "/uniondrive/blox-ai:/uniondrive",
        "/run:/run:ro",
        "/var/log/fula:/var/log/fula",
        "/var/run/docker.sock:/var/run/docker.sock",
        "./runbook.md:/usr/bin/fula/ai/runbook.md:ro",
        "./action_whitelist.json:/etc/fula/action_whitelist.json:ro",
    ]
    for m in required_mounts:
        assert m in body, f"docker-compose.yml missing required mount: {m}"


def test_compose_has_security_note_for_docker_sock():
    """Codex post-review HIGH: explicit comment that :ro on a unix socket
    is NOT a meaningful security boundary; Phase 10 is the real guard."""
    with open(_COMPOSE_PATH, encoding="utf-8") as f:
        body = f.read()
    assert "SECURITY NOTE" in body
    assert "docker.sock" in body or "docker-sock" in body
    assert "Phase 10" in body


def test_compose_keeps_no_new_privileges():
    """Codex: confirm container is not privileged + retains no-new-privileges."""
    with open(_COMPOSE_PATH, encoding="utf-8") as f:
        body = f.read()
    assert "no-new-privileges:true" in body
    assert "privileged: true" not in body


# ---------------------------------------------------------------------------
# install.sh: stages the new data files before container start
# ---------------------------------------------------------------------------

def test_install_sh_stages_runbook_and_whitelist():
    """The compose ./runbook.md and ./action_whitelist.json references
    resolve against $BLOX_AI_DIR (the systemd WorkingDirectory). install.sh
    must copy both into place — otherwise container start fails on missing
    mount source."""
    with open(_INSTALL_SH_PATH) as f:
        body = f.read()
    assert 'cp "${PLUGIN_EXEC_DIR}/runbook.md" "$BLOX_AI_DIR/"' in body
    assert 'cp "${PLUGIN_EXEC_DIR}/action_whitelist.json" "$BLOX_AI_DIR/"' in body


def test_install_sh_stages_trees():
    """Bug 2026-05-29: the docker-compose `./trees:...:ro` mount resolves
    against $BLOX_AI_DIR (systemd WorkingDirectory), but install.sh never
    copied trees/ there -> the container kept mounting the stale trees that
    first landed on the device, so shipped tree fixes (kubo docker.restart ->
    restart_fula) never reached the running container. install.sh re-runs every
    boot, so this copy is the only propagation path for tree edits."""
    with open(_INSTALL_SH_PATH) as f:
        body = f.read()
    assert 'mkdir -p "$BLOX_AI_DIR/trees"' in body
    assert 'cp -r "${PLUGIN_EXEC_DIR}/trees/." "$BLOX_AI_DIR/trees/"' in body


def test_compose_mounts_trees_readonly():
    """The trees the install copies are consumed via this read-only bind
    mount; keep the staging path and the mount target in lockstep."""
    with open(_COMPOSE_PATH, encoding="utf-8") as f:
        body = f.read()
    assert "./trees:/etc/fula/blox-ai/trees:ro" in body


def test_install_sh_ensures_var_log_fula_exists():
    """Container mounts /var/log/fula host-side. install.sh ensures it
    exists with 0775 perms (Codex: conservative perms, not 0777)."""
    with open(_INSTALL_SH_PATH) as f:
        body = f.read()
    assert "mkdir -p /var/log/fula" in body
    assert "chmod 0775 /var/log/fula" in body


# ---------------------------------------------------------------------------
# fula.sh: ensures /var/log/fula exists at boot (belt + suspenders)
# ---------------------------------------------------------------------------

def test_fula_sh_creates_var_log_fula_dir():
    """Both advisors (HIGH): /var/log/fula must be created at boot so the
    container's bind-mount target resolves cleanly."""
    with open(_FULA_SH_PATH) as f:
        body = f.read()
    assert "mkdir -p /var/log/fula" in body
    assert "chmod 0775 /var/log/fula" in body
