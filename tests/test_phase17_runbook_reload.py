"""Phase 17 tests — runbook fast-iteration plumbing.

Phase 17 deliverable (fula-ota side):
1. NEW runbook_frontmatter.py — stdlib-only parser for runbook header.
2. NEW reload_runbook.sh — sanity-validate + docker SIGHUP wrapper.
3. api/README.md adds Phase 17 contract section (SIGHUP handler spec).
4. Existing runbook.md frontmatter parses cleanly via the new parser.

Parser must enforce:
- '---' fence open + close
- required keys: runbook_version, schema_version, last_updated
- versions are positive integers
- schema_version mismatch in is_newer_than() raises (forces full restart)
- runbook_version monotonicity check works (downgrade rejected)

reload_runbook.sh refuses to signal on:
- runbook missing
- runbook unparseable frontmatter

Why these tests: per the plan, the runbook IS the fast iteration loop.
A broken runbook push must NEVER cause the container to load garbage.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_PARSER_PATH = os.path.join(_PLUGIN_DIR, "runbook_frontmatter.py")
_RELOAD_SH = os.path.join(_PLUGIN_DIR, "reload_runbook.sh")
_RUNBOOK = os.path.join(_PLUGIN_DIR, "runbook.md")
_API_README = os.path.join(_PLUGIN_DIR, "api", "README.md")


def _load_parser():
    module_name = "runbook_frontmatter_under_test"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, _PARSER_PATH)
    mod = importlib.util.module_from_spec(spec)
    # Register BEFORE exec_module so dataclass field-type resolution
    # (which looks up cls.__module__ in sys.modules) works.
    sys.modules[module_name] = mod
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------
# runbook_frontmatter.py — parser correctness
# ---------------------------------------------------------------------------

def test_parser_module_imports():
    mod = _load_parser()
    assert hasattr(mod, "parse")
    assert hasattr(mod, "parse_file")
    assert hasattr(mod, "RunbookFrontmatter")
    assert hasattr(mod, "RunbookFrontmatterError")


def test_parser_parses_minimal_valid_runbook():
    mod = _load_parser()
    fm = mod.parse(
        "---\n"
        "runbook_version: 3\n"
        "schema_version: 1\n"
        "last_updated: 2026-05-24\n"
        "---\n"
        "# body content here\n"
    )
    assert fm.runbook_version == 3
    assert fm.schema_version == 1
    assert fm.last_updated == "2026-05-24"


def test_parser_parses_actual_repo_runbook():
    """The committed runbook.md must always parse — it's what the container loads."""
    mod = _load_parser()
    fm = mod.parse_file(_RUNBOOK)
    assert fm.runbook_version >= 1
    assert fm.schema_version >= 1
    assert fm.last_updated


def test_parser_tolerates_quoted_values():
    mod = _load_parser()
    fm = mod.parse(
        "---\n"
        'runbook_version: 1\n'
        'schema_version: 1\n'
        'last_updated: "2026-05-24"\n'
        "---\n"
    )
    assert fm.last_updated == "2026-05-24"


def test_parser_tolerates_crlf_line_endings():
    """OTA push from a Windows author shouldn't break parsing."""
    mod = _load_parser()
    fm = mod.parse(
        "---\r\n"
        "runbook_version: 1\r\n"
        "schema_version: 1\r\n"
        "last_updated: 2026-05-24\r\n"
        "---\r\n"
    )
    assert fm.runbook_version == 1


def test_parser_rejects_missing_opening_fence():
    mod = _load_parser()
    with pytest.raises(mod.RunbookFrontmatterError):
        mod.parse("runbook_version: 1\nschema_version: 1\nlast_updated: x\n")


def test_parser_rejects_missing_closing_fence():
    mod = _load_parser()
    with pytest.raises(mod.RunbookFrontmatterError):
        mod.parse(
            "---\n"
            "runbook_version: 1\n"
            "schema_version: 1\n"
            "last_updated: 2026-05-24\n"
            "# body without closing fence\n"
        )


def test_parser_rejects_empty_frontmatter_block():
    mod = _load_parser()
    with pytest.raises(mod.RunbookFrontmatterError):
        mod.parse("---\n---\n")


def test_parser_rejects_missing_required_key():
    mod = _load_parser()
    with pytest.raises(mod.RunbookFrontmatterError) as exc:
        mod.parse(
            "---\n"
            "runbook_version: 1\n"
            "schema_version: 1\n"
            "---\n"
        )
    assert "last_updated" in str(exc.value)


def test_parser_rejects_non_integer_version():
    mod = _load_parser()
    with pytest.raises(mod.RunbookFrontmatterError):
        mod.parse(
            "---\n"
            "runbook_version: v3\n"
            "schema_version: 1\n"
            "last_updated: 2026-05-24\n"
            "---\n"
        )


def test_parser_rejects_zero_version():
    mod = _load_parser()
    with pytest.raises(mod.RunbookFrontmatterError):
        mod.parse(
            "---\n"
            "runbook_version: 0\n"
            "schema_version: 1\n"
            "last_updated: x\n"
            "---\n"
        )


def test_parser_rejects_unparseable_line():
    mod = _load_parser()
    with pytest.raises(mod.RunbookFrontmatterError):
        mod.parse(
            "---\n"
            "runbook_version: 1\n"
            "schema_version: 1\n"
            "last_updated: 2026-05-24\n"
            "this is not a key: value pair line\n"
            ": orphan colon\n"
            "---\n"
        )


def test_parser_tolerates_blank_lines_in_frontmatter():
    mod = _load_parser()
    fm = mod.parse(
        "---\n"
        "runbook_version: 1\n"
        "\n"
        "schema_version: 1\n"
        "\n"
        "last_updated: 2026-05-24\n"
        "---\n"
    )
    assert fm.runbook_version == 1


# ---------------------------------------------------------------------------
# is_newer_than — replay + schema-bump protection
# ---------------------------------------------------------------------------

def test_is_newer_than_first_runbook_is_always_newer():
    mod = _load_parser()
    fm = mod.RunbookFrontmatter(runbook_version=1, schema_version=1, last_updated="x")
    assert fm.is_newer_than(None) is True


def test_is_newer_than_higher_version_is_newer():
    mod = _load_parser()
    old = mod.RunbookFrontmatter(runbook_version=2, schema_version=1, last_updated="x")
    new = mod.RunbookFrontmatter(runbook_version=3, schema_version=1, last_updated="x")
    assert new.is_newer_than(old) is True


def test_is_newer_than_same_version_not_newer():
    """Replay-protection: re-pushing the same version must not re-load."""
    mod = _load_parser()
    a = mod.RunbookFrontmatter(runbook_version=2, schema_version=1, last_updated="x")
    b = mod.RunbookFrontmatter(runbook_version=2, schema_version=1, last_updated="y")
    assert b.is_newer_than(a) is False


def test_is_newer_than_lower_version_not_newer():
    """Downgrade-protection."""
    mod = _load_parser()
    old = mod.RunbookFrontmatter(runbook_version=5, schema_version=1, last_updated="x")
    downgrade = mod.RunbookFrontmatter(runbook_version=3, schema_version=1, last_updated="x")
    assert downgrade.is_newer_than(old) is False


def test_is_newer_than_schema_bump_raises():
    """Schema version change is BREAKING — must force full container restart,
    not silent SIGHUP swap."""
    mod = _load_parser()
    old = mod.RunbookFrontmatter(runbook_version=1, schema_version=1, last_updated="x")
    breaking = mod.RunbookFrontmatter(runbook_version=2, schema_version=2, last_updated="x")
    with pytest.raises(mod.RunbookFrontmatterError):
        breaking.is_newer_than(old)


# ---------------------------------------------------------------------------
# reload_runbook.sh — validation behaviour (host script smoke)
# ---------------------------------------------------------------------------

def test_reload_script_exists_and_executable_flagged_in_shebang():
    assert os.path.isfile(_RELOAD_SH)
    with open(_RELOAD_SH) as f:
        first = f.readline()
    assert first.startswith("#!"), "reload_runbook.sh needs a shebang"


def test_reload_script_documents_signal_and_refuse_path():
    """Script behaviour is verified at the source level (Windows CI can't
    chmod+exec shell + docker). The contract that matters:
    - it calls 'docker kill --signal=SIGHUP'
    - it has an early-exit / refuse path for malformed runbook
    - it doesn't fall back to a full container restart on parse failure
    """
    with open(_RELOAD_SH) as f:
        text = f.read()
    assert "docker kill --signal=SIGHUP" in text
    assert "refusing to signal" in text
    # Must NOT silently restart on parse failure
    assert "docker restart" not in text
    assert "systemctl restart blox-ai" not in text


def test_reload_script_uses_shared_parser():
    """Source-of-truth check: reload_runbook.sh must defer to
    runbook_frontmatter.py rather than re-implementing the parser
    in bash (which would drift)."""
    with open(_RELOAD_SH) as f:
        text = f.read()
    assert "runbook_frontmatter" in text


# ---------------------------------------------------------------------------
# api/README.md — Phase 17 contract section
# ---------------------------------------------------------------------------

def test_readme_has_phase_17_section():
    with open(_API_README) as f:
        text = f.read()
    assert "Phase 17 additions" in text
    assert "SIGHUP" in text
    assert "runbook_frontmatter.py" in text
    assert "reload_runbook.sh" in text


def test_readme_documents_schema_bump_force_restart():
    with open(_API_README) as f:
        text = f.read()
    assert "schema_version" in text
    # Container author must know schema bumps require full restart
    assert "refuse" in text.lower() and "restart" in text.lower()


def test_readme_documents_runbook_reload_event():
    """Container must log to events.jsonl so the developer can see whether
    the OTA reload landed (via diag/events)."""
    with open(_API_README) as f:
        text = f.read()
    assert "events.jsonl" in text
    assert "runbook_reload" in text
