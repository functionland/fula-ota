"""Phase 11 tests — conversational state + phone-context plumbing.

fula-ota's Phase 11 deliverable is:
1. SSE schema bumped v2 → v3 with session_started + user_question +
   user_reply_received variants added
2. NEW user_reply_request.schema.json
3. NEW phone_context_request.schema.json
4. NEW phone_context.schema.json
5. runbook.md adds 'Asking clarifying questions' + 'Phone-side context'
   sections
6. api/README.md adds Phase 11 contract section
7. ble_commands.json adds 2 entries (ai/user-reply, ai/phone-context);
   total 17 commands now

Per Codex pre-impl HIGH catches (applied):
- expected_response_type (not _schema; type discriminator not embedded JSON Schema)
- session_started dedicated event (not overload thought.payload string)
- phone_context NOT emitted on SSE (tool_result schema closed; container ingests internally)
- ai/user-reply + ai/phone-context are BLE commands but NOT in tool_call enum
- All phone_context fields tightly capped (maxLength, maxItems, additionalProperties:false)
"""

import json
import os

import jsonschema
import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_API_DIR = os.path.join(_PLUGIN_DIR, "api")
_SSE_SCHEMA = os.path.join(_API_DIR, "sse_events.schema.json")
_USER_REPLY_SCHEMA = os.path.join(_API_DIR, "user_reply_request.schema.json")
_PHONE_CONTEXT_SCHEMA = os.path.join(_API_DIR, "phone_context.schema.json")
_PHONE_CONTEXT_REQ_SCHEMA = os.path.join(_API_DIR, "phone_context_request.schema.json")
_BLE_MANIFEST = os.path.join(_PLUGIN_DIR, "ble_commands.json")
_RUNBOOK = os.path.join(_PLUGIN_DIR, "runbook.md")
_API_README = os.path.join(_API_DIR, "README.md")


def _load(path):
    with open(path) as f:
        return json.load(f)


def _validate(payload, schema):
    jsonschema.validate(
        payload, schema,
        format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER,
    )


# ---------------------------------------------------------------------------
# SSE schema v3 — new variants
# ---------------------------------------------------------------------------

def test_sse_schema_bumped_to_v3():
    d = _load(_SSE_SCHEMA)
    assert d["schema_version"] == 3
    assert d["$id"].endswith("sse_events.v3.schema.json")
    type_consts = set()
    for ref in d["oneOf"]:
        def_name = ref["$ref"].split("/")[-1]
        type_consts.add(d["$defs"][def_name]["properties"]["type"]["const"])
    expected = {
        "session_started", "thought", "tool_call", "tool_result",
        "verdict", "recommended_action", "execution_result",
        "user_question", "user_reply_received", "error",
    }
    assert type_consts == expected, f"Missing: {expected - type_consts}; extra: {type_consts - expected}"


def test_session_started_event_validates():
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "session_started",
        "session_id": "sess-uuid-001",
        "protocol_version": 3,
        "ttl_seconds": 1800,
    }, sse)


def test_session_started_minimal_validates():
    """ttl_seconds is optional; protocol_version + session_id required."""
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "session_started",
        "session_id": "sess-uuid-001",
        "protocol_version": 3,
    }, sse)


def test_session_started_requires_protocol_version():
    """Gemini + Codex post-impl: protocol_version is the natural
    version-discovery point. Required so clients can branch logic
    before the first user_question lands."""
    sse = _load(_SSE_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "type": "session_started",
            "session_id": "sess-001",
            # missing protocol_version
        }, sse)


def test_session_started_rejects_wrong_protocol_version():
    sse = _load(_SSE_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "type": "session_started",
            "session_id": "sess-001",
            "protocol_version": 2,  # v2 doesn't have session_started; v3 does
        }, sse)


def test_user_question_text_validates():
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "user_question",
        "question_id": "q-001",
        "payload": {
            "question": "When did the issue start?",
            "expected_response_type": "text",
        },
    }, sse)


def test_user_question_boolean_validates():
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "user_question",
        "question_id": "q-002",
        "payload": {
            "question": "Is the device LED on?",
            "expected_response_type": "boolean",
        },
    }, sse)


def test_user_question_choice_validates():
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "user_question",
        "question_id": "q-003",
        "payload": {
            "question": "Which best describes the symptom?",
            "expected_response_type": "choice",
            "options": ["Slow", "Disconnected", "Restarting", "Other"],
        },
    }, sse)


def test_user_question_choice_without_options_rejected():
    """Codex HIGH: if expected_response_type=choice, options required."""
    sse = _load(_SSE_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "type": "user_question",
            "question_id": "q-bad",
            "payload": {
                "question": "Which?",
                "expected_response_type": "choice",
                # missing options
            },
        }, sse)


def test_user_question_boolean_with_options_rejected():
    """Built-in advisor post-impl catch: inverse rule — when
    expected_response_type=boolean, options must NOT be present
    (app renders Yes/No automatically; supplying options is
    inconsistent UI)."""
    sse = _load(_SSE_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "type": "user_question",
            "question_id": "q-bad",
            "payload": {
                "question": "LED on?",
                "expected_response_type": "boolean",
                "options": ["yes", "no"],
            },
        }, sse)


def test_api_readme_documents_lifecycle_edge_cases():
    """Codex post-impl MED-HIGH: document the lifecycle edges so
    cross-repo container + app agree."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    # Repeated /user-reply with same question_id
    assert "Repeated /user-reply" in body
    assert "idempotent" in body.lower()
    # /phone-context during pending question
    assert "/phone-context arriving while" in body or "phone-context arriving" in body.lower()
    # phone-context replaces previous
    assert "REPLACES" in body or "replaces" in body.lower()


def test_runbook_warns_against_overruling_user_with_stale_phone_context():
    """Codex post-impl MED-HIGH: phone context is evidence not intent;
    don't overrule explicit user statements from stale ring-buffer entries."""
    with open(_RUNBOOK, encoding="utf-8") as f:
        body = f.read()
    section_idx = body.find("## Phone-side context")
    section_end = body.find("\n## ", section_idx + 1)
    section = body[section_idx:section_end]
    assert "evidence" in section.lower() and "intent" in section.lower()


def test_runbook_warns_against_context_request_looping():
    """Gemini post-impl MED-HIGH: model shouldn't ask for context,
    receive it, then ask again."""
    with open(_RUNBOOK, encoding="utf-8") as f:
        body = f.read()
    section_idx = body.find("## Phone-side context")
    section_end = body.find("\n## ", section_idx + 1)
    section = body[section_idx:section_end]
    assert ("Do NOT loop" in section or "do not loop" in section.lower() or
            "move toward a verdict" in section.lower())


def test_api_readme_documents_consecutive_user_question_handling():
    """Built-in advisor post-impl catch: schema can't enforce that the
    model emit only one pending user_question at a time. Container must
    enforce. README must document the canonical behavior so cross-repo
    container author + app-side chat state machine agree."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    assert "Consecutive user_question events" in body or "consecutive user_question" in body.lower()
    # Must say container REJECTS second pending, not replaces
    assert "reject" in body.lower()
    # Must mention the rationale (app state machine, ambiguity)
    assert ("chat-bubble" in body.lower() or "state machine" in body.lower() or "ambiguity" in body.lower())


def test_user_question_text_without_expected_response_type_allowed():
    """expected_response_type is optional; defaults to freeform text UX."""
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "user_question",
        "question_id": "q-004",
        "payload": {"question": "What were you doing when this happened?"},
    }, sse)


@pytest.mark.parametrize("bad", [
    {"type": "user_question", "question_id": "q"},                          # missing payload
    {"type": "user_question", "payload": {"question": "x"}},                # missing question_id
    {"type": "user_question", "question_id": "q", "payload": {}},           # missing question
    {"type": "user_question", "question_id": "q",
     "payload": {"question": "x", "expected_response_type": "longform"}},   # bad enum
    {"type": "user_question", "question_id": "q",
     "payload": {"question": "x", "expected_response_type": "choice",
                 "options": ["one"]}},                                       # < minItems 2
    {"type": "user_question", "question_id": "q",
     "payload": {"question": "x", "extra": "y"}},                           # additionalProperties
])
def test_user_question_rejects_malformed(bad):
    sse = _load(_SSE_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad, sse)


def test_user_reply_received_validates():
    sse = _load(_SSE_SCHEMA)
    _validate({
        "type": "user_reply_received",
        "question_id": "q-001",
        "session_id": "sess-001",
    }, sse)


def test_user_reply_received_requires_session_id():
    """Codex pre-impl MEDIUM: include session_id explicitly."""
    sse = _load(_SSE_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "type": "user_reply_received",
            "question_id": "q-001",
            # missing session_id
        }, sse)


def test_phase_9_10_events_still_validate_in_v3():
    """v3 is additive on v2 — old events still pass."""
    sse = _load(_SSE_SCHEMA)
    _validate({"type": "thought", "payload": "x"}, sse)
    _validate({
        "type": "tool_call", "call_id": "x",
        "payload": {"tool": "diag/internet", "args": {}},
    }, sse)
    _validate({
        "type": "execution_result",
        "action_id": "x", "success": True, "duration_ms": 1,
    }, sse)


# ---------------------------------------------------------------------------
# Codex Q8 catch: phone_context NOT in tool_call enum (model can't call it)
# ---------------------------------------------------------------------------

def test_tool_call_enum_does_NOT_include_phone_context_or_user_reply():
    """Codex pre-impl Q8 HIGH: ai/user-reply and ai/phone-context are
    BLE commands user-initiated through the chat UI; they are NOT
    model-callable tools. Must stay OUT of tool_call.payload.tool enum."""
    sse = _load(_SSE_SCHEMA)
    enum = sse["$defs"]["tool_call"]["properties"]["payload"]["properties"]["tool"]["enum"]
    forbidden = {"phone_context", "phone-context", "ai/phone-context",
                 "user_reply", "user-reply", "ai/user-reply"}
    leaked = forbidden & set(enum)
    assert not leaked, (
        f"tool_call enum leaked Phase 11 commands {leaked} — these are "
        "user-initiated BLE commands, NOT model-callable tools"
    )


def test_tool_result_schema_unchanged_by_phase_11():
    """Codex pre-impl Q8 catch: the plan said 'phone_context lands as
    virtual tool_result with tool: phone_context' — but tool_result has
    no `tool` field and additionalProperties:false. Phase 11 resolves
    by keeping the phone_context ingest INTERNAL (container only) and
    NOT emitting on SSE. The tool_result schema MUST stay closed +
    must NOT gain a `tool` field."""
    sse = _load(_SSE_SCHEMA)
    tr = sse["$defs"]["tool_result"]
    assert tr["additionalProperties"] is False
    assert "tool" not in tr["properties"], (
        "tool_result must NOT have a `tool` field — phone_context is "
        "ingested into model context internally, not emitted on SSE"
    )


# ---------------------------------------------------------------------------
# user_reply_request schema
# ---------------------------------------------------------------------------

def test_user_reply_request_valid():
    schema = _load(_USER_REPLY_SCHEMA)
    _validate({
        "session_id": "sess-001",
        "question_id": "q-001",
        "reply_text": "It started about 2 hours ago after I rebooted the router.",
    }, schema)


@pytest.mark.parametrize("bad", [
    {},                                                                  # missing required
    {"session_id": "x", "question_id": "y"},                             # missing reply_text
    {"session_id": "x", "question_id": "y", "reply_text": ""},           # empty reply
    {"session_id": "x", "question_id": "y", "reply_text": "z" * 4001},   # > 4000 chars
    {"session_id": "x", "question_id": "y", "reply_text": "z",
     "extra": "boom"},                                                    # additionalProperties
])
def test_user_reply_request_rejects_malformed(bad):
    schema = _load(_USER_REPLY_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad, schema)


# ---------------------------------------------------------------------------
# phone_context schema — privacy + size caps
# ---------------------------------------------------------------------------

def test_phone_context_minimal_valid():
    schema = _load(_PHONE_CONTEXT_SCHEMA)
    _validate({
        "app_version": "3.1.0",
        "os": "android",
        "os_version": "14",
    }, schema)


def test_phone_context_full_valid():
    schema = _load(_PHONE_CONTEXT_SCHEMA)
    _validate({
        "app_version": "3.1.0",
        "os": "ios",
        "os_version": "17.4",
        "device_model": "iPhone 15 Pro",
        "netinfo": {
            "is_connected": True,
            "is_internet_reachable": False,
            "type": "wifi",
            "wifi_ssid": "Home-5G",
            "wifi_strength": -67,
        },
        "recent_connection_attempts": [
            {"ts": "2026-05-24T14:23:00Z", "transport": "libp2p",
             "target_blox_id": "12D3KooW...", "success": False,
             "error": "dial timeout", "duration_ms": 10000},
        ],
        "last_successful_blox_interaction_ts": "2026-05-24T08:15:00Z",
        "recent_network_changes": [
            {"ts": "2026-05-24T14:22:30Z", "from": "Office-Wifi", "to": "Home-5G"},
        ],
        "recent_app_errors": [
            {"ts": "2026-05-24T14:25:00Z", "screen": "Blox.screen",
             "error_summary": "BLE write failed: device disconnected"},
        ],
    }, schema)


def test_phone_context_caps_all_arrays():
    """Codex pre-impl MEDIUM-HIGH: cap all arrays to bound payload size +
    log-injection mitigation."""
    schema = _load(_PHONE_CONTEXT_SCHEMA)
    assert schema["properties"]["recent_connection_attempts"]["maxItems"] == 20
    assert schema["properties"]["recent_network_changes"]["maxItems"] == 10
    assert schema["properties"]["recent_app_errors"]["maxItems"] == 10


def test_phone_context_rejects_oversized_arrays():
    schema = _load(_PHONE_CONTEXT_SCHEMA)
    # 21 attempts > maxItems 20
    bad = {
        "app_version": "1", "os": "android", "os_version": "14",
        "recent_connection_attempts": [
            {"ts": "2026-05-24T14:23:00Z", "transport": "libp2p", "success": False}
            for _ in range(21)
        ],
    }
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad, schema)


def test_phone_context_rejects_overlong_strings():
    schema = _load(_PHONE_CONTEXT_SCHEMA)
    # wifi_ssid > maxLength 64
    bad = {
        "app_version": "1", "os": "android", "os_version": "14",
        "netinfo": {"is_connected": True, "type": "wifi", "wifi_ssid": "x" * 65},
    }
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad, schema)


def test_phone_context_rejects_additional_top_level_properties():
    schema = _load(_PHONE_CONTEXT_SCHEMA)
    bad = {
        "app_version": "1", "os": "android", "os_version": "14",
        "extra_field": "boom",
    }
    with pytest.raises(jsonschema.ValidationError):
        _validate(bad, schema)


def test_phone_context_rejects_bad_os_enum():
    schema = _load(_PHONE_CONTEXT_SCHEMA)
    with pytest.raises(jsonschema.ValidationError):
        _validate({"app_version": "1", "os": "windowsphone", "os_version": "8"}, schema)


def _build_phone_context_request_validator():
    """The phone_context_request schema $refs phone_context.v1.schema.json.
    Build a referencing.Registry so the resolver can find it."""
    from referencing import Registry, Resource
    from referencing.jsonschema import DRAFT202012
    pc_schema = _load(_PHONE_CONTEXT_SCHEMA)
    req_schema = _load(_PHONE_CONTEXT_REQ_SCHEMA)
    registry = Registry().with_resource(
        "phone_context.v1.schema.json",
        Resource(contents=pc_schema, specification=DRAFT202012),
    )
    return jsonschema.Draft202012Validator(
        req_schema, registry=registry,
        format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER,
    )


def test_phone_context_request_wraps_phone_context():
    validator = _build_phone_context_request_validator()
    validator.validate({
        "session_id": "sess-001",
        "phone_context": {
            "app_version": "3.1.0", "os": "android", "os_version": "14",
        },
    })


@pytest.mark.parametrize("bad", [
    {},
    {"session_id": "x"},                                  # missing phone_context
    {"phone_context": {"app_version": "1", "os": "android", "os_version": "14"}},  # missing session_id
    {"session_id": "x",
     "phone_context": {"app_version": "1", "os": "android", "os_version": "14"},
     "extra": 1},                                         # additionalProperties
])
def test_phone_context_request_rejects_malformed(bad):
    validator = _build_phone_context_request_validator()
    with pytest.raises(jsonschema.ValidationError):
        validator.validate(bad)


# ---------------------------------------------------------------------------
# ble_commands.json — Phase 11 adds 2 entries, total 17
# ---------------------------------------------------------------------------

def test_ble_manifest_has_17_commands_after_phase_11():
    d = _load(_BLE_MANIFEST)
    # Phase 11 added 2 commands (ai/user-reply, ai/phone-context) → ≥17.
    # Later phases may add more (Phase 16 adds ai/feedback → 18). Relaxed
    # from == to >= so per-phase additions don't break this earlier check.
    assert len(d["commands"]) >= 17, (
        f"Expected ≥17 commands (15 Phase 6 + 2 Phase 11); got {len(d['commands'])}"
    )


def test_ble_manifest_has_user_reply_command():
    d = _load(_BLE_MANIFEST)
    by_name = {c["name"]: c for c in d["commands"]}
    assert "ai/user-reply" in by_name
    cmd = by_name["ai/user-reply"]
    assert cmd["type"] == "exec"
    assert cmd["proxy_url"].endswith("/troubleshoot/user-reply")
    # Should NOT require approval (user-initiated through chat UI)
    assert cmd.get("require_approval", False) is False


def test_ble_manifest_has_phone_context_command():
    d = _load(_BLE_MANIFEST)
    by_name = {c["name"]: c for c in d["commands"]}
    assert "ai/phone-context" in by_name
    cmd = by_name["ai/phone-context"]
    assert cmd["type"] == "exec"
    assert cmd["proxy_url"].endswith("/troubleshoot/phone-context")
    assert cmd.get("require_approval", False) is False


# ---------------------------------------------------------------------------
# Runbook drift guards
# ---------------------------------------------------------------------------

def test_runbook_has_clarifying_questions_section():
    with open(_RUNBOOK, encoding="utf-8") as f:
        body = f.read()
    assert "## Asking clarifying questions" in body
    # Must mention expected_response_type discriminator values
    section_idx = body.find("## Asking clarifying questions")
    section_end = body.find("\n## ", section_idx + 1)
    section = body[section_idx:section_end]
    for variant in ('"text"', '"boolean"', '"choice"'):
        assert variant in section, f"clarifying-questions section missing {variant}"
    # Tells model when NOT to ask
    assert "should NOT" in section or "ONLY when" in section


def test_runbook_has_phone_context_section():
    with open(_RUNBOOK, encoding="utf-8") as f:
        body = f.read()
    assert "## Phone-side context" in body
    section_idx = body.find("## Phone-side context")
    section_end = body.find("\n## ", section_idx + 1)
    section = body[section_idx:section_end]
    # Tells model to check phone-side first
    assert "FIRST" in section or "first" in section
    # Mentions netinfo + recent_connection_attempts (specific field references)
    assert "netinfo" in section
    assert "recent_connection_attempts" in section


def test_runbook_does_not_leak_phone_context_as_sse_event_type():
    """Plan said 'phone_context lands as virtual tool_result' — Codex
    Q8 caught this can't go on SSE (tool_result is closed without
    `tool` field). Runbook MUST tell model phone_context arrives in
    its context, NOT as an SSE event the model emits or consumes."""
    with open(_RUNBOOK, encoding="utf-8") as f:
        body = f.read()
    section_idx = body.find("## Phone-side context")
    section_end = body.find("\n## ", section_idx + 1)
    section = body[section_idx:section_end]
    # Must NOT instruct the model to emit any event for phone_context
    forbidden_emit_patterns = [
        '"type": "phone_context"',
        '"type":"phone_context"',
        "emit `phone_context`",
        "emit a `phone_context`",
    ]
    for pat in forbidden_emit_patterns:
        assert pat not in section, f"runbook tells model to emit {pat!r} — wrong; phone_context is container-ingested"


# ---------------------------------------------------------------------------
# API README — Phase 11 contract
# ---------------------------------------------------------------------------

def test_api_readme_documents_phase_11_additions():
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    assert "Phase 11" in body
    # Schemas
    assert "user_reply_request.schema.json" in body
    assert "phone_context.schema.json" in body
    # Events
    assert "session_started" in body
    assert "user_question" in body
    assert "user_reply_received" in body


def test_api_readme_documents_session_lifecycle():
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    # Sliding TTL
    assert ("SLIDING" in body or "sliding" in body)
    # 30 min mentioned
    assert ("30 min" in body or "1800" in body)
    # In-memory only
    assert "in-memory" in body.lower()
    # 50 concurrent cap
    assert "50" in body and "concurrent" in body.lower()


def test_api_readme_documents_phone_context_privacy_contract():
    """Codex pre-impl MEDIUM-HIGH: README must explicitly say
    container never logs raw phone_context + sanitizes validation
    errors that echo PII fields."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    assert "PRIVACY" in body or "privacy" in body.lower()
    # Never log raw
    assert "MUST NOT log raw phone_context" in body or "never log raw" in body.lower()
    # Sanitize SSID/BSSID/IPs in errors
    assert ("sanitize" in body.lower() or "redact" in body.lower())
    assert "SSID" in body or "ssid" in body.lower()


def test_api_readme_documents_phone_context_internal_ingestion():
    """Codex Q8 HIGH: README must explain phone_context is internal
    (not emitted on SSE) — otherwise the cross-repo author would try
    to emit a fake tool_result and fail schema validation."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    # Must say NOT emitted on SSE
    assert ("NOT emitted on SSE" in body or "not emitted on SSE" in body), (
        "README must explicitly say phone_context is NOT emitted on SSE — "
        "Codex Q8 catch"
    )


def test_api_readme_documents_error_body_shape():
    """Codex pre-impl MEDIUM-HIGH: define error body shape so app handling
    is deterministic across container implementations."""
    with open(_API_README, encoding="utf-8") as f:
        body = f.read()
    assert "session_not_found" in body
    assert "404" in body
    # The shape itself
    assert '{"error":' in body or '"error":' in body


# ---------------------------------------------------------------------------
# Cross-phase consistency
# ---------------------------------------------------------------------------

def test_no_orphan_files_in_api_dir_after_phase_11():
    """Phase 9: 2 schemas + README. Phase 10: +2 schemas. Phase 11: +3
    schemas (user_reply_request, phone_context_request, phone_context).

    Later phases may add more schemas (Phase 16 adds feedback_request +
    feedback_log_line). Relaxed to ⊇ instead of == so per-phase additions
    don't break this earlier check.
    """
    files = set(os.listdir(_API_DIR))
    required_post_phase_11 = {
        "README.md",
        "audit_log_line.schema.json",
        "diag_responses.schema.json",
        "execute_action_request.schema.json",
        "phone_context.schema.json",
        "phone_context_request.schema.json",
        "sse_events.schema.json",
        "user_reply_request.schema.json",
    }
    missing = required_post_phase_11 - files
    assert not missing, f"Missing post-Phase-11 files: {missing}"
