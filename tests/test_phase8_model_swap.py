"""Phase 8 tests — Qwen 2.5-3B-Instruct RKLLM model swap.

Covers (per Codex + Gemini pre-impl consensus):
- Placeholder fail-fast guards (both URL and SHA, not just SHA — Codex)
- SHA verification on cached AND post-download paths (Codex catch — the
  prior size-only check let a corrupt cache survive forever)
- RAM gate threshold accepts 4 GB-spec devices and rejects 2 GB
- Model filename consistency across info.json + download_model.sh +
  start.sh + docker-compose.yml
- No Deepseek strings remain in active code paths including the pgrep
  pattern (Codex post-review catch from Phase 6 lab)
- Existing Deepseek file is NOT deleted by download_model.sh (Codex HIGH
  vs Gemini MEDIUM — we follow Codex's "preserve rollback path" stance)
"""

import os
import re

import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_INFO_PATH = os.path.join(_PLUGIN_DIR, "info.json")
_INSTALL_PATH = os.path.join(_PLUGIN_DIR, "install.sh")
_START_PATH = os.path.join(_PLUGIN_DIR, "start.sh")
_DOWNLOAD_PATH = os.path.join(_PLUGIN_DIR, "custom", "download_model.sh")
_COMPOSE_PATH = os.path.join(_PLUGIN_DIR, "docker-compose.yml")

QWEN_FILENAME = "qwen2.5-3b-instruct-rk3588-w8a8.rkllm"


# ---------------------------------------------------------------------------
# info.json — describes new model + new RAM budget
# ---------------------------------------------------------------------------

def test_info_json_describes_qwen_3b():
    import json
    with open(_INFO_PATH) as f:
        d = json.load(f)
    assert d["version"] == "201", "Phase 8 bumps version to 201"
    assert "Qwen" in d["description"] or "qwen" in d["description"].lower()
    assert any("3b" in d["description"].lower() or "3 b" in d["description"].lower() for _ in [1])
    # Required input default matches the actual file we'll download
    inputs = {i["name"]: i for i in d["requiredInputs"]}
    assert inputs["ai-model"]["default"] == QWEN_FILENAME
    # RAM hint in user-facing instructions reflects the new 4 GB threshold
    instr_text = " ".join(i["description"] for i in d["instructions"])
    assert "4 GB" in instr_text


# ---------------------------------------------------------------------------
# RAM gate — KB precision, accepts 4 GB-spec devices (Phase 6 lab lesson)
# ---------------------------------------------------------------------------

def test_install_sh_ram_gate_is_3460032_kb():
    """3460032 KB ≈ 3.3 GB. Accepts 4 GB-spec devices (which measure
    ~3.7 GB MemTotal); rejects 2 GB devices (~1.8 GB measured)."""
    with open(_INSTALL_PATH) as f:
        body = f.read()
    assert "RAM_MIN_KB=3460032" in body, (
        "Phase 8 lowers gate to ~3.3 GB in KB to accept 4 GB-spec devices"
    )
    # Comparison must still be against RAM_KB in KB, not RAM_GB
    assert 'RAM_KB" -lt "$RAM_MIN_KB"' in body
    # Old 8 GB threshold must be gone
    assert "RAM_MIN_KB=7340032" not in body
    # User-facing message updated to 4 GB-spec
    assert "4 GB-spec device required" in body
    assert "8 GB-spec device required" not in body


def test_install_sh_ram_gate_simulated_thresholds():
    """Read the threshold from the file and simulate the comparison
    against representative MemTotal values for 2/4/8/16 GB-spec devices.
    Catches off-by-one if someone tweaks the number."""
    with open(_INSTALL_PATH) as f:
        body = f.read()
    m = re.search(r"RAM_MIN_KB=(\d+)", body)
    assert m, "RAM_MIN_KB not found in install.sh"
    threshold = int(m.group(1))
    # Representative MemTotal values seen on RK3588 devices of each spec
    # (after firmware + kernel CMA + GPU carveout):
    spec_2gb_kb = 1800 * 1024      # ~1.8 GB measured
    spec_4gb_kb = 3700 * 1024      # ~3.7 GB measured (typical RK3588 4 GB board)
    spec_8gb_kb_lab = 8117616      # exact value measured on pi@192.168.68.107 Phase 6 lab
    spec_16gb_kb = 16 * 1024 * 1024
    assert spec_2gb_kb < threshold, "2 GB-spec device should be REJECTED"
    assert spec_4gb_kb >= threshold, "4 GB-spec device should be ACCEPTED"
    assert spec_8gb_kb_lab >= threshold, "Phase 6 lab 8 GB-spec device should still pass"
    assert spec_16gb_kb >= threshold, "16 GB device should still pass"


# ---------------------------------------------------------------------------
# Model filename consistency across files
# ---------------------------------------------------------------------------

def test_model_filename_matches_across_files():
    """info.json default, start.sh MODEL_FILE, download_model.sh MODEL_FILE,
    and docker-compose RKLLM_MODEL_PATH must all reference the same
    Qwen filename. Mismatch = service starts but loads the wrong file."""
    for path in (_START_PATH, _DOWNLOAD_PATH):
        with open(path) as f:
            body = f.read()
        assert QWEN_FILENAME in body, (
            f"{os.path.basename(path)} doesn't reference {QWEN_FILENAME}"
        )
    with open(_COMPOSE_PATH) as f:
        body = f.read()
    assert QWEN_FILENAME in body, (
        f"docker-compose.yml RKLLM_MODEL_PATH doesn't reference {QWEN_FILENAME}"
    )


# ---------------------------------------------------------------------------
# Placeholder fail-fast (Codex post-review HIGH: both URL and SHA)
# ---------------------------------------------------------------------------

def test_download_model_has_placeholder_guard_for_both_url_and_sha():
    """A real release fills in both DOWNLOAD_URL and MODEL_SHA256. The
    guard must reject if EITHER is still the placeholder — Codex's catch
    that a real SHA with a stale URL is also a bad release state."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # Both variables must be checked for the placeholder
    assert '"$DOWNLOAD_URL" == *"__SET_BEFORE_RELEASE__"*' in body
    assert '"$MODEL_SHA256" == *"__SET_BEFORE_RELEASE__"*' in body
    # Must exit 1 if placeholder remains
    assert 'exit 1' in body


def test_install_sh_hoists_placeholder_check_before_service_enable():
    """Built-in advisor catch (Phase 8 post-review): install.sh launches
    download_model.sh via `nohup ... &` without redirect, so any error
    from it lands in nohup.out — not journalctl / fula.sh.log. Without
    this hoisted check, a release tag with unresolved placeholders would
    leave devices in the worst state: service enabled, BLE manifest
    registered, model never downloads, error invisible to support.

    The hoisted check must run BEFORE `systemctl enable blox-ai.service`
    so install.sh exits 1 synchronously and plugins.sh logs it normally."""
    with open(_INSTALL_PATH) as f:
        body = f.read()
    # The check must reference both vars
    assert "DOWNLOAD_URL" in body and "MODEL_SHA256" in body, (
        "install.sh must check both URL and SHA placeholders"
    )
    assert "__SET_BEFORE_RELEASE__" in body, (
        "install.sh must check for the placeholder string"
    )
    # Must source vars from download_model.sh — single source of truth
    assert "download_model.sh" in body, (
        "install.sh check must source vars from download_model.sh"
    )
    # The check must come BEFORE systemctl enable
    placeholder_check_idx = body.find("__SET_BEFORE_RELEASE__")
    enable_idx = body.find("systemctl enable blox-ai.service")
    assert placeholder_check_idx >= 0 and enable_idx >= 0, (
        "Can't locate either placeholder check or systemctl enable"
    )
    assert placeholder_check_idx < enable_idx, (
        "Placeholder check must be BEFORE systemctl enable so install.sh "
        "fails synchronously, not after the service is registered"
    )


def test_download_model_currently_has_placeholder_sha():
    """Phase 8 ships with placeholders pending the sibling
    functionland/blox-ai PR. CI MUST catch and reject any release tag
    that hasn't replaced these. A separate release-gate check should
    grep for __SET_BEFORE_RELEASE__ across the repo."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # This is INTENTIONAL — Phase 8 ships unresolved; release gate fills.
    assert 'MODEL_SHA256="__SET_BEFORE_RELEASE__"' in body, (
        "Phase 8 ships SHA placeholder until cross-repo model upload lands"
    )


# ---------------------------------------------------------------------------
# SHA verification on both cached AND post-download paths (Codex catch)
# ---------------------------------------------------------------------------

def test_download_model_verifies_sha_on_cached_file():
    """The pre-Phase-8 logic accepted any existing file above SIZE_LIMIT.
    A corrupt or maliciously-modified cache file would survive forever.
    Phase 8 must SHA-verify cached files before accepting."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # The cached-file branch must call verify_sha (or sha256sum)
    assert "verify_sha" in body
    # And the function must use sha256sum
    assert "sha256sum" in body
    # The cache acceptance path must guard on the verify result
    # (i.e., we should see verify_sha being used as a conditional somewhere
    # near a `restart` or `cached` branch).
    assert re.search(r"verify_sha.+MODEL_FILE.+MODEL_SHA256", body), (
        "verify_sha must be called with MODEL_FILE + MODEL_SHA256 args"
    )


def test_download_model_verifies_sha_after_download():
    """Even fresh download must verify — protects against CDN
    corruption + truncated downloads that happen to land above SIZE_LIMIT."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # Look for the post-download verify block
    assert "Verifying SHA-256" in body or "SHA verified" in body
    # And the mismatch path must exit 1 (not silently start the service)
    assert "SHA mismatch after download" in body
    assert "refusing to start service" in body


# ---------------------------------------------------------------------------
# No Deepseek strings in active paths (Codex catch from pre-review)
# ---------------------------------------------------------------------------

def test_no_deepseek_references_in_active_paths():
    """Phase 8 must remove all Deepseek references from the active code
    paths. Mentioning Deepseek in a comment explaining the swap is fine;
    a Deepseek path in a `pgrep`, MODEL_FILE, or DOWNLOAD_URL is a bug
    waiting to happen."""
    for path in (_DOWNLOAD_PATH, _START_PATH):
        with open(path) as f:
            body = f.read()
        # Strip comment-only lines before checking
        non_comment = "\n".join(
            line for line in body.splitlines()
            if not re.match(r"^\s*#", line)
        )
        # No deepseek substring in non-comment code
        assert "deepseek" not in non_comment.lower(), (
            f"{os.path.basename(path)} still has 'deepseek' in active code: "
            f"check MODEL_FILE / DOWNLOAD_URL / pgrep pattern"
        )


def test_pgrep_pattern_uses_model_basename_not_hardcoded_name():
    """Codex's specific catch from pre-review: avoid `pgrep -f
    "wget.*deepseek..."` because swapping models leaves a stale grep
    pattern. Use $MODEL_BASENAME instead."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    assert "pgrep -f \"wget.*${MODEL_BASENAME}\"" in body, (
        "pgrep pattern must be derived from MODEL_BASENAME, not hardcoded"
    )
    # The OLD hardcoded pattern must be gone
    assert "wget.*deepseek" not in body


# ---------------------------------------------------------------------------
# Old Deepseek file is NOT auto-deleted (Codex HIGH > Gemini MEDIUM)
# ---------------------------------------------------------------------------

def test_download_model_does_not_delete_old_deepseek_file():
    """Codex post-review HIGH: leave the old Deepseek file alone before
    Phase 18 formalizes rollback. Gemini MEDIUM disagreed (delete-after-
    success). We follow Codex — safer default, matches the plan's
    existing 'preserve /uniondrive/loyal-agent model data' stance."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # No `rm` line targeting the Deepseek filename
    deepseek_rm = re.search(r"rm.*deepseek", body, re.IGNORECASE)
    assert deepseek_rm is None, (
        f"download_model.sh tries to delete Deepseek file: {deepseek_rm.group()}. "
        "Phase 8 preserves the old model for rollback (Codex post-review)."
    )


# ---------------------------------------------------------------------------
# Size limits consistent across start.sh and download_model.sh
# ---------------------------------------------------------------------------

def test_size_limit_consistent_between_start_and_download():
    """If start.sh's SIZE_LIMIT is greater than download_model.sh's,
    start.sh will refuse to start a model that download_model.sh
    considered complete. Both must agree."""
    def _extract(path):
        with open(path) as f:
            for line in f:
                m = re.match(r"^SIZE_LIMIT=(\d+)", line)
                if m:
                    return int(m.group(1))
        return None
    s = _extract(_START_PATH)
    d = _extract(_DOWNLOAD_PATH)
    assert s is not None, "start.sh missing SIZE_LIMIT"
    assert d is not None, "download_model.sh missing SIZE_LIMIT"
    assert s == d, (
        f"SIZE_LIMIT differs: start.sh={s}, download_model.sh={d}. "
        "They must match or start.sh will reject valid downloads."
    )
    # Sanity: Phase 8 lower bound is 2.5 GB
    assert s == 2500000000


# ---------------------------------------------------------------------------
# Pre-existing Phase 6/7 tests must still pass after the swap
# ---------------------------------------------------------------------------

def test_start_sh_verifies_sha_not_only_size():
    """Codex post-impl review HIGH: manual `start.sh` invocation could
    boot a corrupt same-size model if start.sh trusts size-only
    validation. start.sh must source MODEL_SHA256 from download_model.sh
    (single source of truth) and refuse to start on mismatch."""
    with open(_START_PATH) as f:
        body = f.read()
    # Sources from download_model.sh
    assert "download_model.sh" in body
    assert "MODEL_SHA256" in body
    # Uses sha256sum
    assert "sha256sum" in body
    # Mismatch path exits 1, doesn't fall through to systemctl start
    assert "SHA mismatch" in body
    assert "exit 1" in body
    # Empty / placeholder SHA is handled (don't refuse to start on a
    # fresh PR build that hasn't filled the SHA yet — that path is
    # already guarded by install.sh's hoisted check)
    assert "__SET_BEFORE_RELEASE__" in body or 'MODEL_SHA256=""' in body or '-n "$MODEL_SHA256"' in body


def test_download_model_renames_corrupt_post_download_to_quarantine():
    """Codex Q2 compromise (between Gemini delete-both-paths HIGH and
    Codex original keep-as-is MEDIUM-HIGH): rename post-download
    mismatch to `.corrupt.<ts>` so the file is out of the cache-
    acceptance path AND preserved for forensic analysis. A later
    admin cleanup can sweep .corrupt.* files."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # The .corrupt.<timestamp> rename pattern
    assert "${MODEL_FILE}.corrupt." in body or 'MODEL_FILE}.corrupt.' in body or 'corrupt.${TS}' in body
    # Uses mv to rename (not just rm); falls back to rm if mv fails
    assert "mv -f" in body
    # Generates a timestamp
    assert 'date -u +' in body or 'date -u "+' in body


def test_release_placeholder_gate_workflow_exists():
    """Codex + Gemini both flagged: tests assert the placeholder EXISTS
    (intentional Phase 8 state); nothing in CI blocks a release tag
    from shipping with it. The release-placeholder-gate workflow grep-
    fails the build if __SET_BEFORE_RELEASE__ survives into a release."""
    gate_path = os.path.join(
        _REPO_ROOT, ".github", "workflows", "release-placeholder-gate.yml",
    )
    assert os.path.isfile(gate_path), (
        "release-placeholder-gate.yml workflow must exist to block "
        "release tags that ship Phase 8 placeholders"
    )
    with open(gate_path) as f:
        body = f.read()
    assert "__SET_BEFORE_RELEASE__" in body
    assert "exit 1" in body
    assert "docker/fxsupport/linux/plugins/blox-ai" in body
    # Triggers on release events + push to main/release branches
    assert "release:" in body
    assert "main" in body


def test_phase_6_manifest_still_valid_after_phase_8_swap():
    """Phase 8 doesn't touch ble_commands.json but the test suite must
    keep passing. Sanity-import the Phase 6 test file."""
    # Just check the file exists and is the same Phase 6 manifest
    manifest_path = os.path.join(_PLUGIN_DIR, "ble_commands.json")
    assert os.path.isfile(manifest_path)
    import json
    with open(manifest_path) as f:
        d = json.load(f)
    assert d["plugin_id"] == "blox-ai"
    assert len(d["commands"]) == 15
