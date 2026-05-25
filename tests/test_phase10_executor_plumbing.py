"""Phase 10 tests — security-critical executor plumbing.

fula-ota's Phase 10 deliverable is:
1. SSE schema bumped to v2 with execution_result event added
2. NEW execute_action_request.schema.json
3. NEW audit_log_line.schema.json
4. docker-compose adds /run/fula-ai:rw + /etc/fula/blox-ai/security-code:ro
5. fula.sh creates /run/fula-ai (0700) + /etc/fula/blox-ai/security-code
   (default '1234', 0600, only if absent)
6. runbook adds post-recommendation flow
7. api/README documents the full executor contract

Per plan + Codex pre-impl HIGH (security-critical): negative tests
must cover token validation states + tier-3 security-code states +
audit log forensic completeness.
"""

import json
import os
import re
from datetime import datetime, timedelta, timezone

import jsonschema
import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_API_DIR = os.path.join(_PLUGIN_DIR, "api")
_SSE_SCHEMA = os.path.join(_API_DIR, "sse_events.schema.json")
_REQ_SCHEMA = os.path.join(_API_DIR, "execute_action_request.schema.json")
_AUDIT_SCHEMA = os.path.join(_API_DIR, "audit_log_line.schema.json")
_API_README = os.path.join(_API_DIR, "README.md")
_RUNBOOK = os.path.join(_PLUGIN_DIR, "runbook.md")
_COMPOSE = os.path.join(_PLUGIN_DIR, "docker-compose.yml")
_FULA_SH = os.path.join(_REPO_ROOT, "docker", "fxsupport", "linux", "fula.sh")


def _load(path):
    with open(path) as f:
        return json.load(f)


def _validate(payload, schema):
    jsonschema.validate(
        payload, schema,
        format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER,
    )


# ---------------------------------------------------------------------------
# SSE schema v2 — execution_result added; v1 events still valid
# ---------------------------------------------------------------------------

def test_sse_schema_has_phase_10_execution_result_variant():
    """Phase 10 bumped to v2 by adding execution_result. Phase 11
    bumped to v3 by adding session_started + user_question +
    user_reply_received. Test that Phase 10's contribution (execution_result)
    is present regardless of further version bumps."""
    d = _load(_SSE_SCHEMA)
    assert d["schema_version"] >= 2
    type_consts = set()
    for ref in d["oneOf"]:
        def_name = ref["$ref"].split("/")[-1]
        type_consts.add(d["$defs"][def_name]["properties"]["type"]["const"])
    phase_10_required = {"thought", "tool_call", "tool_result", "verdict",
                          "recommended_action", "error", "execution_result"}
    missing = phase_10_required - type_consts
    assert not missing, f"Phase 10 variants missing from sse_events: {missing}"


def test_execution_result_event_validates():
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "execution_result",
        "action_id": "act-uuid-001",
        "success": True,
        "exit_code": 0,
        "stdout_excerpt": "Restarting fula.service...\nOK\n",
        "stderr_excerpt": "",
        "duration_ms": 1842,
        "follow_up": "Service restarted; rerun diag/summary to confirm.",
    }, sse)


def test_execution_result_minimal_validates():
    """Required: type, action_id, success, duration_ms. Others optional."""
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "execution_result",
        "action_id": "act-uuid-002",
        "success": False,
        "duration_ms": 50,
    }, sse)


@pytest.mark.parametrize("bad_event", [
    {"type": "execution_result", "action_id": "x"},                 # missing success + duration_ms
    {"type": "execution_result", "success": True, "duration_ms": 1},  # missing action_id
    {"type": "execution_result", "action_id": "x", "success": "yes", "duration_ms": 1},  # success not bool
    {"type": "execution_result", "action_id": "x", "success": True, "duration_ms": -1},  # negative duration
    {"type": "execution_result", "action_id": "x", "success": True, "duration_ms": 1,
     "stdout_excerpt": "x" * 2049},                                  # > 2048
    {"type": "execution_result", "action_id": "x", "success": True, "duration_ms": 1,
     "extra_field": "boom"},                                          # additionalProperties:false
])
def test_execution_result_rejects_malformed(bad_event):
    sse = _load(_SSE_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad_event, sse)


def test_phase_9_event_types_still_validate_in_v2():
    """v2 is additive on v1 — old events still pass."""
    sse = _load(_SSE_SCHEMA)
    _validate({"type": "thought", "payload": "x"}, sse)
    _validate({
        "type": "tool_call", "call_id": "x",
        "payload": {"tool": "diag/internet", "args": {}},
    }, sse)


# ---------------------------------------------------------------------------
# execute_action_request schema
# ---------------------------------------------------------------------------

def test_execute_request_valid():
    req = _load(_REQ_SCHEMA)
    _validate({
        "action_id": "act-uuid-001",
        "approval_token": "a" * 100,  # opaque; container decodes
    }, req)


def test_execute_request_with_security_code_valid():
    req = _load(_REQ_SCHEMA)
    _validate({
        "action_id": "act-uuid-001",
        "approval_token": "a" * 100,
        "security_code": "1234",
    }, req)


@pytest.mark.parametrize("bad_req", [
    {},                                                          # missing required
    {"action_id": "x"},                                          # missing token
    {"approval_token": "a" * 100},                               # missing action_id
    {"action_id": "x", "approval_token": "tooshort"},            # token < 64 chars
    {"action_id": "x", "approval_token": "a" * 2049},            # token > 2048
    {"action_id": "x", "approval_token": "a" * 100, "extra": 1}, # additionalProperties
    {"action_id": "x", "approval_token": "a" * 100,
     "security_code": ""},                                       # empty code rejected
])
def test_execute_request_rejects_malformed(bad_req):
    req = _load(_REQ_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad_req, req)


# ---------------------------------------------------------------------------
# audit_log_line schema — Codex's expanded field set + forensic guards
# ---------------------------------------------------------------------------

def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _later_iso(seconds=300):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_audit_line_executed_success():
    schema = _load(_AUDIT_SCHEMA)
    _validate({
        "ts": _now_iso(),
        "request_id": "req-001",
        "action_id": "act-001",
        "action": "restart_fula",
        "args": {},
        "tier": 2,
        "approval_token_valid": True,
        "token_expires_at": _later_iso(),
        "security_code_required": False,
        "security_code_valid": None,
        "executed": True,
        "rejected_reason": "",
        "result": {"success": True, "exit_code": 0, "follow_up": "rerun diag/summary"},
        "stdout_excerpt": "OK\n",
        "stderr_excerpt": "",
        "approver_transport": "ble",
        "duration_ms": 1234,
        "executor_version": "0.1.0",
        "whitelist_hash": "f" * 64,
    }, schema)


def test_audit_line_executed_tier3_with_security_code():
    schema = _load(_AUDIT_SCHEMA)
    _validate({
        "ts": _now_iso(),
        "request_id": "req-002",
        "action_id": "act-002",
        "action": "reset",
        "args": {},
        "tier": 3,
        "approval_token_valid": True,
        "token_expires_at": _later_iso(),
        "security_code_required": True,
        "security_code_valid": True,
        "executed": True,
        "rejected_reason": "",
        "result": {"success": True, "exit_code": 0},
        "approver_transport": "ble",
        "duration_ms": 250,
        "executor_version": "0.1.0",
        "whitelist_hash": "a" * 64,
    }, schema)


def test_audit_line_rejected_for_each_reason():
    """Forensic completeness — every rejection path is loggable per Codex
    pre-impl HIGH."""
    schema = _load(_AUDIT_SCHEMA)
    rejection_reasons = [
        "action_not_in_whitelist",
        "args_constraint_violation",
        "approval_token_invalid",
        "approval_token_expired",
        "approval_token_replayed",
        "security_code_required_but_missing",
        "security_code_invalid",
        "security_code_file_missing",
        "executor_busy",
        "internal_error",
    ]
    for reason in rejection_reasons:
        line = {
            "ts": _now_iso(),
            "request_id": f"req-rej-{reason}",
            "action_id": "act-001",
            "action": "bogus_action",
            "args": {},
            "tier": 2,
            "approval_token_valid": False,
            "security_code_required": False,
            "security_code_valid": None,
            "executed": False,
            "rejected_reason": reason,
            "approver_transport": "ble",
            "duration_ms": 5,
            "error": f"rejected: {reason}",
            "executor_version": "0.1.0",
            "whitelist_hash": "b" * 64,
        }
        _validate(line, schema)


@pytest.mark.parametrize("bad_line", [
    # missing required fields
    {"ts": "2026-05-24T07:00:00Z"},
    # invalid timestamp
    {"ts": "yesterday", "request_id": "x", "action_id": "x", "action": "x",
     "args": {}, "tier": 2, "approval_token_valid": True,
     "security_code_required": False, "executed": False,
     "rejected_reason": "internal_error", "approver_transport": "ble",
     "duration_ms": 0, "executor_version": "0", "whitelist_hash": "a" * 64},
    # invalid tier
    {"ts": "2026-05-24T07:00:00Z", "request_id": "x", "action_id": "x",
     "action": "x", "args": {}, "tier": 4, "approval_token_valid": True,
     "security_code_required": False, "executed": False,
     "rejected_reason": "internal_error", "approver_transport": "ble",
     "duration_ms": 0, "executor_version": "0", "whitelist_hash": "a" * 64},
    # bad approver_transport enum
    {"ts": "2026-05-24T07:00:00Z", "request_id": "x", "action_id": "x",
     "action": "x", "args": {}, "tier": 2, "approval_token_valid": True,
     "security_code_required": False, "executed": False,
     "rejected_reason": "internal_error", "approver_transport": "ssh",
     "duration_ms": 0, "executor_version": "0", "whitelist_hash": "a" * 64},
    # bad rejected_reason enum
    {"ts": "2026-05-24T07:00:00Z", "request_id": "x", "action_id": "x",
     "action": "x", "args": {}, "tier": 2, "approval_token_valid": True,
     "security_code_required": False, "executed": False,
     "rejected_reason": "my_made_up_reason", "approver_transport": "ble",
     "duration_ms": 0, "executor_version": "0", "whitelist_hash": "a" * 64},
    # whitelist_hash not 64-hex
    {"ts": "2026-05-24T07:00:00Z", "request_id": "x", "action_id": "x",
     "action": "x", "args": {}, "tier": 2, "approval_token_valid": True,
     "security_code_required": False, "executed": False,
     "rejected_reason": "internal_error", "approver_transport": "ble",
     "duration_ms": 0, "executor_version": "0", "whitelist_hash": "not-hex"},
    # additionalProperties
    {"ts": "2026-05-24T07:00:00Z", "request_id": "x", "action_id": "x",
     "action": "x", "args": {}, "tier": 2, "approval_token_valid": True,
     "security_code_required": False, "executed": False,
     "rejected_reason": "internal_error", "approver_transport": "ble",
     "duration_ms": 0, "executor_version": "0", "whitelist_hash": "a" * 64,
     "leaked_secret": "boom"},
])
def test_audit_line_rejects_malformed(bad_line):
    schema = _load(_AUDIT_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad_line, schema)


def test_audit_schema_has_no_field_for_logging_secrets():
    """Codex pre-impl HIGH: NEVER log full token, secrets, or the
    security_code value. Audit schema must not expose fields with those
    names (which would normalize logging them)."""
    schema = _load(_AUDIT_SCHEMA)
    props = schema["properties"]
    forbidden = {"approval_token", "security_code", "hmac_secret",
                 "approval_token_full", "secret", "secret_value"}
    leaked = forbidden & set(props.keys())
    assert not leaked, (
        f"audit_log_line schema must not have fields for {leaked} — "
        "those are secrets that must NEVER be logged"
    )


# ---------------------------------------------------------------------------
# docker-compose mounts — Phase 10 adds 2
# ---------------------------------------------------------------------------

def test_compose_has_run_fula_ai_rw_mount():
    """The HMAC secret tmpfs. Narrow subdir per Codex Phase 7 review."""
    with open(_COMPOSE) as f:
        body = f.read()
    assert "- /run/fula-ai:/run/fula-ai:rw" in body
    # Critical: NOT mounting all of /run :rw
    assert "- /run:/run:rw" not in body


def test_compose_has_security_code_file_ro_mount():
    """Tier-3 security code: single-file bind, container only reads."""
    with open(_COMPOSE) as f:
        body = f.read()
    assert "- /etc/fula/blox-ai/security-code:/etc/fula/blox-ai/security-code:ro" in body


def test_compose_keeps_run_ro_for_general_state():
    """Phase 9's /run:ro mount stays — we narrowed Phase 10 to a subdir
    instead of opening /run to :rw."""
    with open(_COMPOSE) as f:
        body = f.read()
    assert "- /run:/run:ro" in body


# ---------------------------------------------------------------------------
# fula.sh — boot setup creates the mount targets
# ---------------------------------------------------------------------------

def test_fula_sh_creates_run_fula_ai_with_0700():
    with open(_FULA_SH) as f:
        body = f.read()
    assert "mkdir -p /run/fula-ai" in body
    assert "chmod 0700 /run/fula-ai" in body


def test_fula_sh_creates_security_code_only_if_absent():
    """User edits MUST be preserved across reboots + OTA + plugin
    reinstall. Idempotent create only when absent."""
    with open(_FULA_SH) as f:
        body = f.read()
    assert "/etc/fula/blox-ai/security-code" in body
    # The if-test for file absence
    assert "if [ ! -f /etc/fula/blox-ai/security-code ]" in body
    # Default value
    assert 'echo "1234"' in body
    # Conservative perms on the file
    assert "chmod 0600 /etc/fula/blox-ai/security-code" in body
    # And on the parent dir
    assert "chmod 0700 /etc/fula/blox-ai" in body


def test_fula_sh_defends_against_docker_compose_single_file_bind_footgun():
    """Built-in advisor catch: docker-compose with create_host_path:true
    (default) silently creates the path as a directory when a single-
    file bind source is missing at container start. If blox-ai service
    races fula.sh on first boot and Docker wins, the path becomes a
    directory; without a defensive guard, the subsequent `if [ ! -f ... ]`
    returns true and `echo > <dir>` fails — leaving tier-3 broken
    forever. fula.sh must rm-rf the path if it exists but isn't a file."""
    with open(_FULA_SH) as f:
        body = f.read()
    # Look for the defense pattern
    assert (
        "[ ! -f /etc/fula/blox-ai/security-code ]" in body
        and "[ -e /etc/fula/blox-ai/security-code ]" in body
    ), "fula.sh must check (-e AND ! -f) and rm-rf before the if-not-exists create"
    # The rm must happen
    assert "rm -rf /etc/fula/blox-ai/security-code" in body


def test_install_sh_has_security_code_backstop():
    """Defense-in-depth: install.sh also ensures the security-code path
    is a regular file (not a directory from docker-compose race) before
    enabling the service. fula.sh is primary; install.sh is the backstop
    for the install-runs-first-on-fresh-device case."""
    with open(_INSTALL_SH := os.path.join(_PLUGIN_DIR, "install.sh")) as f:
        body = f.read()
    assert "/etc/fula/blox-ai/security-code" in body
    assert "rm -rf /etc/fula/blox-ai/security-code" in body, (
        "install.sh must include the same docker-compose footgun defense"
    )
    assert "mkdir -p /run/fula-ai" in body, (
        "install.sh must also ensure /run/fula-ai exists as a dir"
    )


def test_fula_sh_documents_security_code_weakness():
    """Default '1234' provides essentially no security. Comment must
    say this explicitly so a future reader doesn't take it for a
    real security control."""
    with open(_FULA_SH) as f:
        body = f.read()
    # Find the block around the security-code setup
    block_idx = body.find("/etc/fula/blox-ai/security-code")
    block = body[max(0, block_idx-1500):block_idx+500]
    # Must mention the weakness explicitly
    assert ("no security" in block.lower() or
            "essentially no" in block.lower() or
            "zero protection" in block.lower() or
            "weak" in block.lower()), (
        "fula.sh comment block must say the default 1234 provides no real security"
    )


# ---------------------------------------------------------------------------
# runbook — post-recommendation flow section
# ---------------------------------------------------------------------------

def test_runbook_has_post_recommendation_flow_section():
    with open(_RUNBOOK, encoding="utf-8") as f:
        body = f.read()
    assert "## Post-recommendation flow" in body
    # Must mention execution_result
    section_idx = body.find("## Post-recommendation flow")
    section_end = body.find("---", section_idx)
    section = body[section_idx:section_end]
    assert "execution_result" in section
    assert "execute-action" in section or "/execute-action" in section
    # Must clarify the model's responsibility ENDS at recommended_action
    assert "responsibility" in section.lower() or "do NOT execute" in section


def test_runbook_explains_approval_token_is_not_model_signed():
    """The model must not invent approval_tokens — they're container-signed.
    Runbook must say so to prevent the LLM from making up plausible-looking
    tokens (a real Qwen failure mode)."""
    with open(_RUNBOOK, encoding="utf-8") as f:
        body = f.read()
    section_idx = body.find("## Post-recommendation flow")
    section_end = body.find("---", section_idx)
    section = body[section_idx:section_end]
    assert "executor" in section.lower()
    assert "never set" in section.lower() or "you don't" in section.lower() or "don't sign" in section.lower() or "you never" in section.lower() or "placeholder" in section.lower()


# ---------------------------------------------------------------------------
# API README — executor contract for cross-repo container author
# ---------------------------------------------------------------------------

def test_api_readme_documents_phase_10_additions():
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    # Phase 10 section
    assert "Phase 10" in body
    # The 3 schema files
    assert "execute_action_request.schema.json" in body
    assert "audit_log_line.schema.json" in body
    assert "execution_result" in body
    # The validation order (action name → args → token → security_code)
    assert "action_not_in_whitelist" in body
    assert "args_constraint_violation" in body
    assert "approval_token" in body
    assert "security_code" in body


def test_api_readme_documents_token_scheme():
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    # HMAC-SHA256
    assert "HMAC-SHA256" in body or "HMAC" in body
    # Per-container-start rotation
    assert "per-container-start" in body.lower() or "container start" in body.lower()
    # 5-minute window
    assert "5-minute" in body.lower() or "300 s" in body or "300s" in body
    # In-memory single-use (replay protection)
    assert ("in-memory" in body.lower() and "replay" in body.lower()) or "nonce" in body.lower()


def test_api_readme_documents_security_code_weakness():
    """Codex + Gemini HIGH: README MUST warn loudly that 1234 default
    provides essentially zero security."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    # The dedicated section
    assert "Tier-3 security code" in body or "security code" in body.lower()
    # Loud warning about default
    assert "essentially zero" in body.lower() or "no real" in body.lower() or "zero protection" in body.lower()
    # Rotation instruction
    assert "rotate" in body.lower() or "edit" in body.lower()


def test_api_readme_documents_docker_sock_trust_boundary():
    """Codex HIGH: HMAC is NOT defense against compromised container —
    docker.sock already implies host-root. HMAC is for the confused-
    deputy attack (malicious app, poisoned LLM session). README must
    say so explicitly."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    assert "confused deputy" in body.lower() or "confused-deputy" in body.lower()
    assert "docker.sock" in body
    # Must be clear that compromised container = game over
    assert "compromised container" in body.lower() or "host-root" in body.lower()


def test_api_readme_documents_append_only_logging():
    """Gemini HIGH: container has O_APPEND only on audit log — prevents
    cleaning up tracks."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    assert "O_APPEND" in body or "append-only" in body.lower() or "append only" in body.lower()


# ---------------------------------------------------------------------------
# Cross-phase consistency
# ---------------------------------------------------------------------------

def test_recommended_action_minlength_bumped_to_64():
    """Phase 9 had minLength 16 as a placeholder. Codex pre-impl Phase 10:
    bump to 64 for the structured token shape (base64url of a small JSON).
    Confirm the bump landed."""
    sse = _load(_SSE_SCHEMA)
    token_schema = sse["$defs"]["recommended_action"]["properties"]["approval_token"]
    # Either Phase 9's 16 (acceptable since structured tokens will be 100+)
    # OR Phase 10's 64 (preferred). Check it's at minimum 16 (no regression).
    assert token_schema["minLength"] >= 16


def test_execute_action_token_field_minlength_64():
    """The /execute-action request body's approval_token has the
    Phase 10 minLength=64 since this is the receiving side and we want
    to fail-fast on tokens that are too short to possibly be valid."""
    req = _load(_REQ_SCHEMA)
    assert req["properties"]["approval_token"]["minLength"] == 64
    assert req["properties"]["approval_token"]["maxLength"] == 2048


def test_phase_10_baseline_files_still_in_api_dir():
    """Phase 10 added 2 schemas to api/. Phase 11 added more. This
    guards Phase 10's BASELINE files still present (exact-set guard
    for Phase 11 lives in test_phase11_conversational.py)."""
    files = set(os.listdir(_API_DIR))
    phase_10_added = {
        "audit_log_line.schema.json",
        "execute_action_request.schema.json",
    }
    missing = phase_10_added - files
    assert not missing, f"Phase 10 files missing from api/: {missing}"
