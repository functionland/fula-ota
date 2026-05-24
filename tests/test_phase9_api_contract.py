"""Phase 9 tests — Blox AI HTTP API contract.

Phase 9 fula-ota deliverable: JSON Schemas + runbook protocol section +
docker-compose mount + install.sh copy. The actual /troubleshoot SSE
endpoint + diag/* implementations live in the cross-repo
functionland/blox-ai container.

Per Codex pre-impl HIGH: negative tests must reject malformed envelopes
(bad ok, missing call_id, unknown event types). Per both advisors:
runbook drift guard — the protocol section must reference only event
types defined in the schema.
"""

import json
import os
import re

import jsonschema
import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_API_DIR = os.path.join(_PLUGIN_DIR, "api")
_SSE_SCHEMA_PATH = os.path.join(_API_DIR, "sse_events.schema.json")
_DIAG_SCHEMA_PATH = os.path.join(_API_DIR, "diag_responses.schema.json")
_RUNBOOK_PATH = os.path.join(_PLUGIN_DIR, "runbook.md")
_BLE_MANIFEST_PATH = os.path.join(_PLUGIN_DIR, "ble_commands.json")
_COMPOSE_PATH = os.path.join(_PLUGIN_DIR, "docker-compose.yml")
_INSTALL_PATH = os.path.join(_PLUGIN_DIR, "install.sh")
_WHITELIST_PATH = os.path.join(_PLUGIN_DIR, "action_whitelist.json")


@pytest.fixture
def sse_schema():
    with open(_SSE_SCHEMA_PATH) as f:
        return json.load(f)


@pytest.fixture
def diag_schema():
    with open(_DIAG_SCHEMA_PATH) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Schemas are themselves valid Draft 2020-12 JSON Schema
# ---------------------------------------------------------------------------

def test_sse_schema_file_exists_and_is_valid_json(sse_schema):
    assert sse_schema["$schema"].endswith("/draft/2020-12/schema")
    # Phase 9 shipped v1; Phase 10 bumped to v2 (added execution_result).
    # Accept either; further phase-specific assertions live in
    # tests/test_phase10_executor_plumbing.py.
    assert sse_schema["schema_version"] >= 1
    jsonschema.Draft202012Validator.check_schema(sse_schema)


def test_diag_schema_file_exists_and_is_valid_json(diag_schema):
    assert diag_schema["$schema"].endswith("/draft/2020-12/schema")
    assert diag_schema["schema_version"] == 1
    jsonschema.Draft202012Validator.check_schema(diag_schema)


def test_schemas_have_stable_ids(sse_schema, diag_schema):
    """Codex pre-impl MEDIUM-HIGH: stable $id for cross-repo CI reference."""
    assert sse_schema["$id"].startswith("https://schema.functionland.dev/")
    assert diag_schema["$id"].startswith("https://schema.functionland.dev/")
    # Versioned $id (v1 in Phase 9; v2 in Phase 10). Just confirm versioned.
    assert re.search(r"\.v\d+\.schema\.json$", sse_schema["$id"])
    assert re.search(r"\.v\d+\.schema\.json$", diag_schema["$id"])


# ---------------------------------------------------------------------------
# Positive tests — representative SSE events of each type validate
# ---------------------------------------------------------------------------

def _validate_sse(event, schema):
    # Enable FormatChecker so format:date-time actually rejects bad
    # timestamps (Codex post-review MEDIUM-HIGH: format is annotation-
    # only by default; without an explicit checker, "not-a-date" passes
    # validation silently).
    jsonschema.validate(event, schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)


def test_sse_thought_event_validates(sse_schema):
    _validate_sse({"type": "thought", "payload": "Looking at your connection..."}, sse_schema)


def test_sse_tool_call_event_validates(sse_schema):
    _validate_sse({
        "type": "tool_call",
        "call_id": "abc123",
        "payload": {"tool": "diag/internet", "args": {}},
    }, sse_schema)


def test_sse_tool_result_event_validates(sse_schema):
    _validate_sse({
        "type": "tool_result",
        "call_id": "abc123",
        "ok": True,
        "payload": {"dns_ok": True, "https_google_ok": True, "https_discovery_ok": False},
    }, sse_schema)


def test_sse_tool_result_with_error_validates(sse_schema):
    _validate_sse({
        "type": "tool_result",
        "call_id": "abc123",
        "ok": False,
        "error": "diag/relay timed out",
        "payload": None,
    }, sse_schema)


def test_sse_verdict_event_validates(sse_schema):
    _validate_sse({
        "type": "verdict",
        "payload": {
            "summary": "Your Blox can't reach Fula's discovery server",
            "severity": "red",
            "root_cause": "captive portal",
        },
    }, sse_schema)


def test_sse_recommended_action_event_validates(sse_schema):
    # approval_token bumped to minLength 64 in Phase 10 (Codex post-impl
    # HIGH: token must match execute_action_request schema's 64-2048).
    _validate_sse({
        "type": "recommended_action",
        "action_id": "act-001",
        "action_name": "restart_fula",
        "args": {},
        "reasoning": "Kubo API hung — restart should clear it.",
        "confidence": 0.85,
        "tier": 2,
        "approval_token": "a" * 100,  # opaque; ≥64 chars
    }, sse_schema)


def test_sse_error_event_validates(sse_schema):
    _validate_sse({
        "type": "error",
        "code": "MODEL_UNAVAILABLE",
        "message": "RKLLM runtime returned -1",
        "recoverable": False,
    }, sse_schema)


# ---------------------------------------------------------------------------
# NEGATIVE tests (Codex pre-impl HIGH) — malformed envelopes get REJECTED
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bad_event", [
    # Missing required fields
    {"type": "thought"},                                          # missing payload
    {"type": "tool_call", "call_id": "x"},                        # missing payload
    {"type": "tool_call", "payload": {"tool": "diag/internet", "args": {}}},  # missing call_id
    {"type": "tool_result", "call_id": "x", "ok": True},          # missing payload
    {"type": "tool_result", "call_id": "x", "payload": {}},       # missing ok
    {"type": "verdict", "payload": {"summary": "x"}},             # missing severity
    {"type": "recommended_action", "action_id": "a", "action_name": "x"},  # missing many fields
    # Wrong field types
    {"type": "thought", "payload": 42},                           # payload not string
    {"type": "tool_call", "call_id": "x", "payload": {"tool": "diag/internet"}},  # missing args
    {"type": "tool_result", "call_id": "x", "ok": "true", "payload": {}},  # ok not bool
    {"type": "verdict", "payload": {"summary": "x", "severity": "purple"}},  # bad severity enum
    {"type": "recommended_action", "action_id": "a", "action_name": "x",
     "args": {}, "reasoning": "r", "confidence": 1.5, "tier": 2,
     "approval_token": "thisis16charsmin"},                       # confidence > 1.0
    {"type": "recommended_action", "action_id": "a", "action_name": "x",
     "args": {}, "reasoning": "r", "confidence": 0.5, "tier": 1,
     "approval_token": "thisis16charsmin"},                       # tier 1 not allowed (tier 1 is read, no approval needed)
    {"type": "recommended_action", "action_id": "a", "action_name": "x",
     "args": {}, "reasoning": "r", "confidence": 0.5, "tier": 2,
     "approval_token": "tooshort"},                               # token < 16 chars
    # Unknown event types — schema's oneOf rejects
    {"type": "user_question", "payload": {"question": "x"}},     # Phase 11, not Phase 9
    {"type": "execution_result", "success": True},                # Phase 10, not Phase 9
    {"type": "unknown", "payload": "x"},
    # Tool name not in enum
    {"type": "tool_call", "call_id": "x", "payload": {"tool": "diag/bogus", "args": {}}},
    # Extra properties (additionalProperties: false)
    {"type": "thought", "payload": "hi", "extra_field": "boom"},
])
def test_sse_malformed_events_are_rejected(bad_event, sse_schema):
    """Per Codex pre-impl HIGH: schema is closed (additionalProperties:false)
    and tight enough to catch the typical LLM-emit mistakes."""
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(bad_event, sse_schema)


# ---------------------------------------------------------------------------
# diag/* response shapes — positive + negative
# ---------------------------------------------------------------------------

def _validate_diag(payload, diag_schema, def_name):
    sub_schema = {**diag_schema["$defs"][def_name], "$defs": diag_schema["$defs"]}
    jsonschema.validate(payload, sub_schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)


def test_diag_internet_response_validates(diag_schema):
    _validate_diag({
        "dns_ok": True, "https_google_ok": True, "https_discovery_ok": False,
        "latency_ms_avg": 42.3, "captive_portal_likely": True,
        "checked_at": "2026-05-24T07:30:00Z",
    }, diag_schema, "internet")


def test_diag_relay_response_validates(diag_schema):
    _validate_diag({
        "relays": [
            {"addr": "/dns/relay1.fula.network/tcp/4001/p2p/QmABC",
             "dns_name": "relay1.fula.network",
             "swarm_connect_ok": True,
             "has_circuit_reservation": True,
             "latency_ms": 28.5},
        ],
        "reservation_count": 1,
        "checked_at": "2026-05-24T07:30:00Z",
    }, diag_schema, "relay")


def test_diag_summary_response_validates(diag_schema):
    _validate_diag({
        "overall": "yellow",
        "generated_at": "2026-05-24T07:30:00Z",
        "subsystems": {
            "internet":   {"status": "green",  "key_metrics": {"latency_ms_avg": 42}},
            "wireguard":  {"status": "yellow", "key_metrics": {"last_handshake_age_sec": 180}},
            "containers": {"status": "green",  "key_metrics": {"oom_count_24h": 0}},
        },
    }, diag_schema, "summary")


def test_diag_summary_rejects_unknown_subsystem_key(diag_schema):
    """Codex pre-impl HIGH: subsystem keys must be from the enum to
    prevent drift between summary and per-subsystem diag/* responses."""
    with pytest.raises(jsonschema.ValidationError):
        _validate_diag({
            "overall": "green",
            "generated_at": "2026-05-24T07:30:00Z",
            "subsystems": {"made_up_subsystem": {"status": "green"}},
        }, diag_schema, "summary")


def test_diag_summary_rejects_bad_severity(diag_schema):
    with pytest.raises(jsonschema.ValidationError):
        _validate_diag({
            "overall": "purple",  # not in enum
            "generated_at": "2026-05-24T07:30:00Z",
            "subsystems": {},
        }, diag_schema, "summary")


def test_diag_containers_response_validates(diag_schema):
    _validate_diag({
        "containers": [
            {"name": "ipfs_host", "state": "running", "oom_killed": False,
             "restart_count": 0, "image": "ipfs/kubo:latest",
             "started_at": "2026-05-24T05:00:00Z"},
        ],
    }, diag_schema, "containers")


def test_diag_containers_rejects_bad_state_enum(diag_schema):
    with pytest.raises(jsonschema.ValidationError):
        _validate_diag({
            "containers": [{"name": "x", "state": "zombie"}],
        }, diag_schema, "containers")


# ---------------------------------------------------------------------------
# Runbook drift guards — protocol section references only schema-defined types
# ---------------------------------------------------------------------------

def test_runbook_has_phase_9_tool_call_protocol_section(sse_schema):
    with open(_RUNBOOK_PATH, encoding="utf-8") as f:
        body = f.read()
    assert "## Tool-call protocol" in body, (
        "Phase 9 must add the tool-call protocol section to the runbook"
    )
    # The protocol section must reference every event type the model
    # is allowed to emit (per the sse_events schema's oneOf branches)
    valid_types = set()
    for ref in sse_schema["oneOf"]:
        def_name = ref["$ref"].split("/")[-1]
        valid_types.add(sse_schema["$defs"][def_name]["properties"]["type"]["const"])

    # Protocol section excerpt should mention each type the model emits
    # (thought, tool_call, tool_result, verdict, recommended_action, error)
    protocol_idx = body.find("## Tool-call protocol")
    next_section_idx = body.find("---", protocol_idx)
    protocol_text = body[protocol_idx:next_section_idx]
    for t in valid_types:
        assert f'"{t}"' in protocol_text, (
            f"runbook protocol section doesn't show how to emit {t} events"
        )


def test_runbook_does_not_reference_phase_11_event_types_in_phase_9_section():
    """Phase 9 ships 6 event types. Phase 10 adds execution_result (in
    its own '## Post-recommendation flow' section). Phase 11 adds
    user_question / user_reply_received. Don't leak Phase 11 events into
    EITHER section — would mislead the model. (Phase 10's execution_result
    is now permitted in the Post-recommendation section per Phase 10
    implementation.)"""
    with open(_RUNBOOK_PATH, encoding="utf-8") as f:
        body = f.read()
    # Bound the Tool-call protocol section by the NEXT ## heading, since
    # consecutive ## sections (Tool-call → Post-recommendation) share
    # the same horizontal rule below them.
    protocol_idx = body.find("## Tool-call protocol")
    next_heading_idx = body.find("\n## ", protocol_idx + 1)
    protocol_text = body[protocol_idx:next_heading_idx]
    # Phase 11 events forbidden anywhere in the runbook
    for forbidden in ("user_question", "user_reply_received"):
        assert forbidden not in body, (
            f"runbook mentions {forbidden} which is a Phase 11 event"
        )
    # Phase 10's execution_result is allowed in its own section but
    # should NOT leak into the Phase 9 Tool-call protocol section.
    assert "execution_result" not in protocol_text, (
        "execution_result belongs in the Phase 10 Post-recommendation flow "
        "section, not the Phase 9 Tool-call protocol section"
    )


def test_runbook_protocol_tool_list_matches_ble_manifest():
    """The tool-call protocol implies the model knows which tools exist.
    Tools enumerated in the runbook + the schema's tool enum + the
    ble_commands.json manifest must agree (no drift)."""
    with open(_BLE_MANIFEST_PATH) as f:
        manifest = json.load(f)
    manifest_diag = sorted(
        c["name"] for c in manifest["commands"] if c["name"].startswith("diag/")
    )
    with open(_SSE_SCHEMA_PATH) as f:
        sse = json.load(f)
    schema_tools = sorted(
        sse["$defs"]["tool_call"]["properties"]["payload"]["properties"]["tool"]["enum"]
    )
    assert schema_tools == manifest_diag, (
        f"sse_events.schema tool enum {schema_tools} != ble_commands manifest "
        f"diag/* {manifest_diag} — drift between Phase 6 and Phase 9"
    )


# ---------------------------------------------------------------------------
# docker-compose + install.sh wiring
# ---------------------------------------------------------------------------

def test_compose_mounts_api_dir():
    with open(_COMPOSE_PATH) as f:
        body = f.read()
    assert "./api:/etc/fula/blox-ai/api:ro" in body, (
        "docker-compose must mount the schemas dir read-only into the container"
    )


def test_install_sh_copies_api_dir():
    with open(_INSTALL_PATH) as f:
        body = f.read()
    assert 'cp -r "${PLUGIN_EXEC_DIR}/api" "$BLOX_AI_DIR/"' in body, (
        "install.sh must copy the api/ dir into the WorkingDirectory so the "
        "compose `./api` bind-mount source exists"
    )


def test_no_orphan_schema_files_in_api_dir():
    """Guard against leaving abandoned schema files behind during iteration.
    Phase 9 shipped 2 schemas + 1 README. Phase 10 adds 2 more schemas
    (execute_action_request, audit_log_line). Phase-specific orphan
    guards live in each phase's test file."""
    files = sorted(os.listdir(_API_DIR))
    expected_files_after_phase_10 = sorted([
        "README.md",
        "diag_responses.schema.json",
        "sse_events.schema.json",
        "execute_action_request.schema.json",
        "audit_log_line.schema.json",
    ])
    assert files == expected_files_after_phase_10, (
        f"Unexpected files in api/ dir: {files}; expected: {expected_files_after_phase_10}"
    )


def test_api_readme_documents_phase_boundary():
    """README must tell the cross-repo author what's IN Phase 9 vs
    deferred to Phase 10/11. Without this, the sibling PR author would
    discover Phase 10's `execution_result` event type by trying to emit
    it + getting schema rejection."""
    readme_path = os.path.join(_API_DIR, "README.md")
    with open(readme_path, encoding="utf-8") as f:
        body = f.read()
    # Must mention which events are in this phase
    for required_event in ("thought", "tool_call", "tool_result",
                           "verdict", "recommended_action", "error"):
        assert required_event in body, f"README missing {required_event}"
    # Must call out deferred events
    assert "Phase 10" in body
    assert "Phase 11" in body
    assert "execution_result" in body
    assert "user_question" in body
    # Must point to the mount target
    assert "/etc/fula/blox-ai/api" in body


# ---------------------------------------------------------------------------
# Cross-phase consistency
# ---------------------------------------------------------------------------

def test_schema_action_name_pattern_is_flexible_for_whitelist_keys():
    """The recommended_action schema doesn't enum action_name (would
    require regenerating the schema every time the whitelist changes).
    Phase 10's executor enforces the actual whitelist check. The schema
    just enforces the basic string shape."""
    with open(_SSE_SCHEMA_PATH) as f:
        sse = json.load(f)
    action_name_schema = sse["$defs"]["recommended_action"]["properties"]["action_name"]
    # Should be a string, NOT an enum (defer enum check to Phase 10's executor)
    assert action_name_schema["type"] == "string"
    assert "enum" not in action_name_schema, (
        "Don't enum action_name in the schema — Phase 10 executor enforces "
        "via action_whitelist.json. Enumming here couples schema iteration "
        "to whitelist iteration."
    )


def test_tool_result_ok_true_forbids_error_field(sse_schema):
    """Codex post-impl MEDIUM-HIGH: success path must not carry an error."""
    bad = {
        "type": "tool_result",
        "call_id": "x",
        "ok": True,
        "payload": {"data": 1},
        "error": "should not be here",
    }
    with pytest.raises(jsonschema.ValidationError):
        _validate_sse(bad, sse_schema)


def test_tool_result_ok_false_requires_error_field(sse_schema):
    """Codex post-impl MEDIUM-HIGH: failure path must carry an error."""
    bad = {
        "type": "tool_result",
        "call_id": "x",
        "ok": False,
        "payload": None,
        # missing "error"
    }
    with pytest.raises(jsonschema.ValidationError):
        _validate_sse(bad, sse_schema)


def test_diag_internet_rejects_invalid_date_time(diag_schema):
    """Codex post-impl MEDIUM-HIGH: format:date-time is annotation-only
    by default; FORMAT_CHECKER must be enabled. _validate_diag enables
    it; this test confirms the rejection actually fires."""
    with pytest.raises(jsonschema.ValidationError):
        _validate_diag({
            "dns_ok": True, "https_google_ok": True, "https_discovery_ok": True,
            "checked_at": "definitely not a date",
        }, diag_schema, "internet")


def test_schema_tool_enum_does_not_include_ai_or_action_endpoints():
    """tool_call.payload.tool should only enum the read-only diag/*
    endpoints. ai/* and action endpoints aren't called via tool_call —
    they have their own SSE event types (recommended_action) or are
    client-initiated."""
    with open(_SSE_SCHEMA_PATH) as f:
        sse = json.load(f)
    enum = sse["$defs"]["tool_call"]["properties"]["payload"]["properties"]["tool"]["enum"]
    for name in enum:
        assert name.startswith("diag/"), (
            f"tool_call enum should be diag/* only; found {name}"
        )
