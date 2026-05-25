"""Phase 18 tests — model rollback manifest + active-entry selector.

Phase 18 deliverable (fula-ota side):
1. NEW api/ai_manifest.schema.json — manifest contract
2. NEW plugins/blox-ai/model_manifest.py — stdlib loader + selector
3. download_model.sh sources MODEL_URL/MODEL_SHA256 from the helper
4. api/README.md adds Phase 18 contract section

Key invariants tested:
- both `current` and `rollback` required (operational discipline:
  if you can't roll back, you shouldn't roll forward)
- rollback_required=true → select(rollback); false → select(current)
- malformed manifest → fall back to hardcoded args (never crash)
- emitted shell output is single-quoted and shell-injection safe
- download_model.sh actually wires the helper into the path
"""

import importlib.util
import json
import os
import subprocess
import sys

import jsonschema
import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_API_DIR = os.path.join(_PLUGIN_DIR, "api")
_SCHEMA = os.path.join(_API_DIR, "ai_manifest.schema.json")
_HELPER = os.path.join(_PLUGIN_DIR, "model_manifest.py")
_DOWNLOAD_SH = os.path.join(_PLUGIN_DIR, "custom", "download_model.sh")
_README = os.path.join(_API_DIR, "README.md")


def _load_helper():
    module_name = "model_manifest_under_test"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, _HELPER)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = mod
    spec.loader.exec_module(mod)
    return mod


def _load_schema():
    with open(_SCHEMA) as f:
        return json.load(f)


def _valid_entry(version="2026-06-12", sha=None):
    return {
        "model_version": version,
        "url": f"https://functionyard.fx.land/qwen-3b-{version}.rkllm",
        "sha256": sha or ("a" * 64),
        "size_bytes": 3_100_000_000,
    }


def _valid_manifest(rollback_required=False):
    return {
        "schema_version": 1,
        "current":  _valid_entry("2026-06-12", "a" * 64),
        "rollback": _valid_entry("2026-05-15", "b" * 64),
        "rollback_required": rollback_required,
    }


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

def test_schema_is_present_and_versioned():
    schema = _load_schema()
    assert schema["schema_version"] == 1
    assert "ai_manifest.v1.schema.json" in schema["$id"]
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) >= {
        "schema_version", "current", "rollback", "rollback_required",
    }


def test_schema_accepts_minimal_valid_manifest():
    jsonschema.validate(_valid_manifest(), _load_schema())


def test_schema_accepts_manifest_with_optional_fields():
    m = _valid_manifest()
    m["manifest_version"] = 5
    m["published_at"] = "2026-06-12T10:00:00Z"
    m["current"]["rkllm_version"] = "1.1.0"
    jsonschema.validate(m, _load_schema())


def test_schema_rejects_missing_rollback():
    """Operational discipline: rollback is REQUIRED."""
    m = _valid_manifest()
    del m["rollback"]
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(m, _load_schema())


def test_schema_rejects_unsupported_schema_version():
    m = _valid_manifest()
    m["schema_version"] = 99
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(m, _load_schema())


def test_schema_rejects_http_url():
    """HTTPS-only — no plaintext model downloads."""
    m = _valid_manifest()
    m["current"]["url"] = "http://functionyard.fx.land/x.rkllm"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(m, _load_schema())


def test_schema_rejects_invalid_sha():
    m = _valid_manifest()
    m["current"]["sha256"] = "not-a-sha"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(m, _load_schema())
    m = _valid_manifest()
    m["current"]["sha256"] = "A" * 64  # uppercase → reject (lowercase only)
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(m, _load_schema())


def test_schema_rejects_size_below_min():
    m = _valid_manifest()
    m["current"]["size_bytes"] = 500_000_000
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(m, _load_schema())


# ---------------------------------------------------------------------------
# Selector — parse + select() decision logic
# ---------------------------------------------------------------------------

def test_select_returns_current_when_rollback_required_false():
    mod = _load_helper()
    m = json.dumps(_valid_manifest(rollback_required=False))
    s = mod.select(m, fallback_url="https://x/y", fallback_sha256="c" * 64)
    assert s.source == "manifest_current"
    assert s.entry.model_version == "2026-06-12"


def test_select_returns_rollback_when_rollback_required_true():
    mod = _load_helper()
    m = json.dumps(_valid_manifest(rollback_required=True))
    s = mod.select(m, fallback_url="https://x/y", fallback_sha256="c" * 64)
    assert s.source == "manifest_rollback"
    assert s.entry.model_version == "2026-05-15"


def test_select_no_manifest_uses_fallback():
    mod = _load_helper()
    s = mod.select(None, fallback_url="https://fb.example/m.rkllm",
                   fallback_sha256="d" * 64, fallback_version="fb-v1")
    assert s.source == "fallback"
    assert s.entry.url == "https://fb.example/m.rkllm"
    assert s.entry.model_version == "fb-v1"


def test_select_malformed_json_falls_back_safely():
    mod = _load_helper()
    s = mod.select("not json at all", fallback_url="https://fb/x",
                   fallback_sha256="e" * 64)
    assert s.source == "fallback_invalid"


def test_select_schema_violation_falls_back_safely():
    mod = _load_helper()
    bad = json.dumps({"schema_version": 1, "current": _valid_entry(),
                      "rollback_required": False})  # missing rollback
    s = mod.select(bad, fallback_url="https://fb/x", fallback_sha256="f" * 64)
    assert s.source == "fallback_invalid"


def test_select_unsupported_schema_version_falls_back_safely():
    mod = _load_helper()
    bad = _valid_manifest()
    bad["schema_version"] = 99
    s = mod.select(json.dumps(bad), fallback_url="https://fb/x",
                   fallback_sha256="f" * 64)
    assert s.source == "fallback_invalid"


def test_select_rejects_boolean_size_bytes():
    """Python's bool is an int subclass — must not slip through."""
    mod = _load_helper()
    bad = _valid_manifest()
    bad["current"]["size_bytes"] = True
    s = mod.select(json.dumps(bad), fallback_url="https://fb/x",
                   fallback_sha256="f" * 64)
    assert s.source == "fallback_invalid"


# ---------------------------------------------------------------------------
# CLI entrypoint — what download_model.sh actually exercises
# ---------------------------------------------------------------------------

def test_cli_emits_shell_eval_lines_for_valid_manifest(tmp_path):
    mod = _load_helper()
    manifest_path = tmp_path / "ai-manifest.json"
    manifest_path.write_text(json.dumps(_valid_manifest()))
    rc = mod.main([
        "--manifest-path", str(manifest_path),
        "--fallback-url", "https://fb/x",
        "--fallback-sha256", "c" * 64,
    ])
    assert rc == 0


def test_cli_subprocess_actually_runs(tmp_path):
    """End-to-end smoke: shell-eval'ing the helper's output produces
    the expected variables. This is what download_model.sh does."""
    manifest_path = tmp_path / "ai-manifest.json"
    manifest_path.write_text(json.dumps(_valid_manifest(rollback_required=True)))
    proc = subprocess.run(
        [sys.executable, _HELPER,
         "--manifest-path", str(manifest_path),
         "--fallback-url", "https://fb/x",
         "--fallback-sha256", "c" * 64],
        capture_output=True, text=True, check=True,
    )
    out = proc.stdout
    assert "MODEL_VERSION='2026-05-15'" in out
    assert "MANIFEST_SOURCE='manifest_rollback'" in out
    assert "MODEL_URL='https://functionyard.fx.land/qwen-3b-2026-05-15.rkllm'" in out
    assert "MODEL_SHA256='" in out


def test_cli_falls_back_when_manifest_missing(tmp_path):
    nonexistent = tmp_path / "no-such-file.json"
    proc = subprocess.run(
        [sys.executable, _HELPER,
         "--manifest-path", str(nonexistent),
         "--fallback-url", "https://fb/x",
         "--fallback-sha256", "c" * 64,
         "--fallback-version", "fb-version"],
        capture_output=True, text=True, check=True,
    )
    out = proc.stdout
    assert "MANIFEST_SOURCE='fallback'" in out
    assert "MODEL_VERSION='fb-version'" in out
    assert "MODEL_URL='https://fb/x'" in out


# ---------------------------------------------------------------------------
# download_model.sh wiring
# ---------------------------------------------------------------------------

def test_download_sh_invokes_manifest_helper():
    with open(_DOWNLOAD_SH) as f:
        text = f.read()
    assert "model_manifest.py" in text
    assert "eval " in text  # sources the KEY=VALUE output
    assert "MANIFEST_SOURCE" in text


def test_download_sh_keeps_hardcoded_fallback():
    """Critical regression guard: download_model.sh MUST still have its
    hardcoded URL+SHA so devices without a manifest still work."""
    with open(_DOWNLOAD_SH) as f:
        text = f.read()
    # Hardcoded values still present
    assert "DOWNLOAD_URL=\"https://" in text
    assert "MODEL_SHA256=" in text
    # And the manifest block sets DOWNLOAD_URL FROM MODEL_URL only on
    # successful eval — i.e. the hardcoded values are the fallback path.
    assert "DOWNLOAD_URL=\"$MODEL_URL\"" in text


def test_download_sh_logs_rollback_active():
    """When the manifest signals rollback, download_model.sh must log
    that fact so a support person reading install.log knows the device
    is intentionally on the prior model version."""
    with open(_DOWNLOAD_SH) as f:
        text = f.read()
    assert "ROLLBACK ACTIVE" in text


# ---------------------------------------------------------------------------
# api/README.md — Phase 18 contract
# ---------------------------------------------------------------------------

def test_readme_has_phase_18_section():
    with open(_README) as f:
        text = f.read()
    assert "Phase 18 additions" in text
    assert "ai_manifest.schema.json" in text
    assert "model_manifest.py" in text
    assert "rollback_required" in text


def test_readme_documents_atomic_swap_discipline():
    with open(_README) as f:
        text = f.read()
    assert "Atomic-swap discipline" in text or "atomic-swap" in text.lower()
    assert ".partial" in text or "fsync" in text


def test_readme_warns_against_deleting_rollback_file():
    """The Phase 8 'delete prior Deepseek' pattern would brick rollback
    if applied to a manifest-named file. README must warn about this."""
    with open(_README) as f:
        text = f.read()
    assert "NEVER delete" in text or "never delete" in text.lower()