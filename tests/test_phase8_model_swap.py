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


def test_download_model_has_real_sha256():
    """v1 release: the placeholder has been replaced with the verified
    SHA-256 of the assembled chunks. The exact value is the SHA of the
    c01zaut/Qwen2.5-3B-Instruct-rk3588-1.1.1 W8A8 RKLLM as it lives on
    the lab device (verified against the chunked upload on
    functionland/blox-ai release tag `model-qwen-2.5-3b-w8a8-v1`).

    Update this expected value only when bumping to a new base model."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    assert 'MODEL_SHA256="__SET_BEFORE_RELEASE__"' not in body, (
        "Placeholder must NOT survive into release — fill in real SHA"
    )
    # The assembled-chunk SHA pinned in the file
    assert ('MODEL_SHA256="b7cf8b1c10140ac380535a52602d2ecc862aa9'
            '6a84e3cf5d8267b6e54cca2607"') in body, (
        "MODEL_SHA256 must match the SHA of the assembled chunks "
        "published on functionland/blox-ai release "
        "`model-qwen-2.5-3b-w8a8-v1`"
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
    paths EXCEPT the user-mandated cleanup rm (which targets the file by
    glob, intentionally). Comments explaining the swap are fine; a
    Deepseek MODEL_FILE / DOWNLOAD_URL / pgrep pattern is a bug."""
    # The cleanup glob is the only legitimate Deepseek reference in
    # active code — the rm fires only after Qwen verifies (test_download
    # _model_deletes_old_deepseek_after_qwen_verified guards placement).
    allowed_active_pattern = 'rm -f "$MODEL_DIR"/deepseek-*.rkllm'
    for path in (_DOWNLOAD_PATH, _START_PATH):
        with open(path) as f:
            body = f.read()
        # Strip comments + the user-mandated rm cleanup line
        non_comment = "\n".join(
            line for line in body.splitlines()
            if not re.match(r"^\s*#", line)
               and allowed_active_pattern not in line
        )
        assert "deepseek" not in non_comment.lower(), (
            f"{os.path.basename(path)} has unexpected 'deepseek' in active "
            f"code (other than the cleanup rm): check MODEL_FILE / "
            f"DOWNLOAD_URL / pgrep pattern"
        )


def test_no_hardcoded_deepseek_wget_pattern():
    """v1 release: the model is now downloaded in chunks (assembled +
    SHA-verified) via foreground wget per chunk, so the prior
    background-wget + pgrep wait pattern is gone. The original Codex
    catch — avoid hardcoded "wget.*deepseek" patterns that leave stale
    grep references after a model swap — still applies; assert the old
    Deepseek pattern is not lurking anywhere in the script."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    assert "wget.*deepseek" not in body
    # New design: a CHUNK_URLS array drives the per-chunk wget loop.
    assert "CHUNK_URLS=(" in body, (
        "v1 chunked download must declare a CHUNK_URLS bash array"
    )
    # And the loop iterates the array (foreground wget, not background).
    assert 'for url in "${CHUNK_URLS[@]}"' in body


# ---------------------------------------------------------------------------
# Old Deepseek file is NOT auto-deleted (Codex HIGH > Gemini MEDIUM)
# ---------------------------------------------------------------------------

def test_download_model_deletes_old_deepseek_after_qwen_verified():
    """USER OVERRIDE of Codex HIGH / Gemini MEDIUM: practical disk
    reclamation matters more than a theoretical rollback path that
    doesn't exist until Phase 18. Most devices never installed loyal-
    agent so the rm is a no-op; the few that did benefit from freeing
    ~7 GB.

    The rm must happen ONLY after Qwen is verified — a failed Qwen
    download must never delete the working Deepseek file."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # Glob-scoped rm targeting the model dir, not the whole filesystem
    assert 'rm -f "$MODEL_DIR"/deepseek-*.rkllm' in body, (
        "download_model.sh must rm deepseek-*.rkllm after Qwen verified"
    )
    # Must not appear BEFORE the verification success — otherwise a failed
    # Qwen download would delete the Deepseek file too. Check that the rm
    # call appears after the "SHA verified" success marker.
    rm_idx = body.find('rm -f "$MODEL_DIR"/deepseek-')
    verified_idx = body.find('SHA verified')
    assert rm_idx > verified_idx, (
        "Deepseek rm must come AFTER 'SHA verified' success marker so a "
        "failed Qwen download doesn't wipe the working Deepseek file."
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


def test_download_model_deletes_corrupt_post_download():
    """USER OVERRIDE: a corrupt .rkllm has no forensic value (opaque
    tensor file; can't introspect). Just delete and free the disk.
    Next install re-downloads from CDN."""
    with open(_DOWNLOAD_PATH) as f:
        body = f.read()
    # Post-download mismatch path must rm $MODEL_FILE
    assert 'SHA mismatch after download' in body
    # No `.corrupt.<ts>` rename pattern should remain
    assert "${MODEL_FILE}.corrupt." not in body, (
        "Post-download mismatch must rm, not rename to .corrupt.<ts> (user override)"
    )
    assert "CORRUPT_PATH" not in body, (
        "Quarantine pattern fully removed; user override prefers rm"
    )
    # The rm of the bad file must be on the mismatch path. Find the
    # mismatch echo and confirm rm $MODEL_FILE follows it.
    mismatch_idx = body.find("SHA mismatch after download")
    rm_idx = body.find('rm -f "$MODEL_FILE"', mismatch_idx)
    assert rm_idx > mismatch_idx, (
        "rm of $MODEL_FILE must follow the post-download mismatch branch"
    )


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
    manifest_path = os.path.join(_PLUGIN_DIR, "ble_commands.json")
    assert os.path.isfile(manifest_path)
    import json
    with open(manifest_path) as f:
        d = json.load(f)
    assert d["plugin_id"] == "blox-ai"
    # Phase 6 baseline ≥ 15; Phase 11 took it to 17.
    assert len(d["commands"]) >= 15
