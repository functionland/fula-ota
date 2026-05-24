# Blox AI API contract (Phase 9)

This directory holds the JSON Schema contracts that the cross-repo
`functionland/blox-ai` Docker image MUST satisfy. Bind-mounted into the
container at `/etc/fula/blox-ai/api/` (read-only) by
[../docker-compose.yml](../docker-compose.yml).

## Files

- **`sse_events.schema.json`** — Discriminated union over 6 event types
  emitted by `POST /troubleshoot`'s SSE stream. The container MUST
  validate each event before emit; malformed events leave the LLM
  ungrounded and crash the app's transcript renderer.

- **`diag_responses.schema.json`** — Per-endpoint response shapes for
  the 11 `GET /diag/*` endpoints. The container MUST validate response
  bodies before returning. `diag/summary` is intentionally a ROLL-UP
  (overall + per-subsystem severity) — not a literal union of the other
  diag responses — to keep the LLM's context cost low on the first
  diagnostic turn.

## What the container MUST do

1. **Load both schemas at container start.** Refuse to start if either
   schema fails JSON Schema Draft 2020-12 validation.

2. **Validate every emitted SSE event** against `sse_events.schema.json`
   before sending to the client. Treat validation failure as an
   internal bug (log + emit a synthetic `error` event with
   `code: "SCHEMA_VIOLATION"` and `recoverable: false`).

3. **Validate every `diag/*` response body** against the matching
   `$defs` entry in `diag_responses.schema.json` before returning HTTP
   200. Schema-failing responses become HTTP 500.

4. **Treat `tool_call.payload.tool` enum as the source of truth for
   which `diag/*` tools exist.** Don't introduce new tool names in the
   container without first updating `sse_events.schema.json` +
   `ble_commands.json` in fula-ota.

## What this Phase ships (and what it doesn't)

Phase 9 ships only 6 SSE event types:
`thought`, `tool_call`, `tool_result`, `verdict`, `recommended_action`, `error`.

NOT shipped here (intentionally — separate phases):
- `execution_result` — Phase 10 (`/execute-action` endpoint)
- `user_question`, `user_reply_received` — Phase 11 (conversational
  multi-turn)

If you find yourself wanting to emit one of those in Phase 9 code,
something's wrong with the phase scoping. Surface to fula-ota.

## Cross-repo sync

The schemas are versioned via `$id` URL (`...sse_events.v1.schema.json`)
+ a top-level `schema_version: 1` field. Breaking changes bump both.

For the cross-repo container's CI:
- **Preferred**: vendor the two schema files via a `git submodule` or a
  CI step that `curl`s the raw github URLs from fula-ota's main branch.
  Pin to a fula-ota release tag for reproducibility.
- **Acceptable**: copy-paste with a comment marker linking back to the
  fula-ota source, plus a CI check that detects drift.

The schemas' `$id` is the authoritative identifier — keep it stable
across container restarts so cross-repo validators can pin to it.

## Phase 10 additions (current)

`sse_events.schema.json` bumped to `schema_version: 2` and `$id` to
`...v2.schema.json`. Additions:
- `execution_result` event variant — emitted by `POST /execute-action`
  after the executor finishes (success, failure, or rejection).

New schema files:
- `execute_action_request.schema.json` — request body for
  `POST /execute-action`. Shape: `{action_id, approval_token, security_code?}`.
- `audit_log_line.schema.json` — line shape for
  `/var/log/fula/ai-actions.jsonl`. Container writes one line per
  request (executed OR rejected) for forensic completeness.

### Executor contract (cross-repo container MUST implement)

**1. HMAC approval token, per-container-start rotation.**
- At container start: read 32 bytes from `/dev/urandom`, write hex to
  `/run/fula-ai/approval-secret` mode 0600 root:root.
- When emitting a `recommended_action` event: sign
  `(action_id|expires_at|nonce)` with HMAC-SHA256 of the secret;
  serialize as `base64url(json({action_id, expires_at, nonce, hmac}))`.
- `expires_at` is iso8601 UTC = now + 300 s (5-minute window).
- `nonce` is a fresh `secrets.token_urlsafe(16)` per token.

**2. Token validation on /execute-action.**
- Decode the base64url JSON.
- Reject if `expires_at < now` → `rejected_reason: approval_token_expired`.
- Reject if nonce was previously seen this container-lifetime (in-memory
  LRU keyed by nonce, TTL = 5 min) → `rejected_reason: approval_token_replayed`.
- Reject if HMAC verification fails →
  `rejected_reason: approval_token_invalid`.
- Reject if `action_id` in token doesn't match request →
  `rejected_reason: approval_token_invalid`.

**3. Whitelist enforcement.**
- Load `/etc/fula/action_whitelist.json` at container start (NOT `/etc/fula/blox-ai/action_whitelist.json` — that path is a Phase 10 documentation error caught by Codex post-impl HIGH; the actual `docker-compose.yml` mount target is `/etc/fula/action_whitelist.json` since Phase 7).
- Reject if `action` not in tier_1 / tier_2 / tier_3 lists →
  `rejected_reason: action_not_in_whitelist`.
- Reject if `args` violate `argument_constraints` →
  `rejected_reason: args_constraint_violation`.
- Tier-3 actions: require `security_code` field, compare against
  contents of `/etc/fula/blox-ai/security-code` (read on each request,
  no caching, strip trailing whitespace). Missing/empty file →
  `rejected_reason: security_code_file_missing`. Mismatch →
  `rejected_reason: security_code_invalid`.

**4. Serialize execution.**
- Global asyncio.Lock (or equivalent) — one action at a time per
  container. If another execution is in flight, return
  `rejected_reason: executor_busy` with HTTP 429.

**5. Append-only audit log.**
- Open `/var/log/fula/ai-actions.jsonl` with `O_APPEND`. Never truncate
  or seek.
- Write one line per request (executed OR rejected) per
  `audit_log_line.schema.json`.
- Truncate stdout/stderr to 2048 bytes each before logging (Gemini HIGH
  — log injection + disk exhaustion mitigation).
- NEVER log: the secret, the full approval_token, secrets in args,
  the security_code value.
- Rotate at 50 MB (matches Phase 1's events.jsonl convention).

**6. Execution.**
- For `maps_to_core: true` actions (`reset`, `partition`, `node_delete`,
  `ipfs_delete`, `force_update`, `restart_fula`, `restart_uniondrive`):
  touch the flag file at `/home/pi/commands/.command_<name>` via the
  docker.sock bind-mounted into a tiny exec helper, OR use the existing
  BLE command server's protocol. See container implementation notes.
- For `docker.restart` / `systemctl.restart` / `systemctl.reset-failed`
  / `wireguard.bounce` / `ntp.resync`: run the corresponding command
  via `docker exec` (for docker.restart) or `nsenter --target 1`
  (for systemctl on host). Strict regex validation on every arg
  before shell composition (Gemini HIGH — nsenter is the ultimate
  privilege escalation surface).

### HTTP status mapping (Codex post-impl MEDIUM-HIGH)

Every `/execute-action` request MUST be audited BEFORE returning a
response. The HTTP status conveys the outcome category:

| Status | When |
|---|---|
| `200` | Request was authorized + action subprocess ran. SSE `execution_result` carries `success: bool` (true even if exit_code != 0 — that's an action failure, not a request failure). |
| `400` | Schema validation failed (malformed request body, missing fields). |
| `401` | `approval_token` invalid (HMAC mismatch) OR expired OR replayed. Audit logs the specific `rejected_reason`. |
| `403` | Action not in whitelist OR args violate constraints OR tier-3 security_code missing/invalid OR security-code file missing. |
| `429` | Another action in flight (`executor_busy`). Client should retry after the in-flight action's `expected_duration_s`. |
| `500` | Internal error in the executor itself (e.g. failed to write audit log). |

Nonce consumption ordering: consume the nonce ONLY after HMAC + expiry pass.
Otherwise an attacker who knows the action_id format can pre-burn legitimate nonces.

### Trust boundary (explicit)

`docker.sock` mounted into this container ALREADY implies host-root-
equivalent capability. The HMAC approval-token scheme is NOT defense-
in-depth against a compromised container — anyone who compromises the
container can spawn privileged containers via docker.sock anyway. The
HMAC is defense against the **confused deputy**: a malicious or buggy
phone client (or a poisoned LLM session) sending `/execute-action`
calls the user never approved. The token must originate from a
`recommended_action` event THIS container emitted in this lifetime.

### Tier-3 security code: what it protects + what it doesn't

`/etc/fula/blox-ai/security-code` is a confirmation gate, NOT a
cryptographic lock. Default value `1234` provides essentially zero
protection against a motivated attacker who has bypassed BLE pairing.
It protects against:
- Accidental destructive taps in the app UI.
- A buggy or malicious phone client that knows the BLE protocol but
  doesn't know the device's specific code (after rotation).

It does NOT protect against:
- A motivated attacker with the rotated code (e.g. shoulder-surfing).
- A compromised container (which can read the file directly).
- A compromised phone client paired with the device.

**Users SHOULD rotate the code**: `sudo nano /etc/fula/blox-ai/security-code`
on the device, restart the blox-ai container (or just edit and let the
next tier-3 read pick it up). The phone app's tier-3 confirmation
dialog accepts any 4-digit code, so the user sets a code they remember.

## Phase 11 additions (current)

`sse_events.schema.json` bumped to `schema_version: 3` and `$id` to
`...v3.schema.json`. Additions:
- `session_started` event variant — ALWAYS the first event on a new
  /troubleshoot SSE stream when no session_id was provided. Carries
  `session_id` + `ttl_seconds`.
- `user_question` event variant — model asks user a clarifying
  question. SSE stream PAUSES until /troubleshoot/user-reply lands.
- `user_reply_received` event variant — container acks the reply.

New schema files:
- `user_reply_request.schema.json` — request body for
  `POST /troubleshoot/user-reply`. `{session_id, question_id, reply_text}`.
- `phone_context_request.schema.json` — request body for
  `POST /troubleshoot/phone-context`. `{session_id, phone_context}`.
- `phone_context.schema.json` — the phone-context envelope itself
  (shared with the Phase 12 app-layer `phoneLogger.ts`).

### Phase 11 executor / session contract

**1. Session state (in-memory only).**
- Container holds a dict keyed by `session_id`. Each entry: model
  context, pending question_id (if any), TTL deadline, last activity
  timestamp.
- Max 50 concurrent sessions (memory-bounded for 7.7 GB device with
  3 GB Qwen model already resident).
- TTL: 30 min, SLIDING — refreshed on each valid /user-reply or
  /phone-context call (Codex pre-impl HIGH).
- LRU eviction when at cap.
- LOST on container restart — matches Phase 10's per-container-start
  approval-token rotation discipline. Client UX: 404 on next call →
  "session expired; start over" prompt.

**2. POST /troubleshoot.**
- If no session_id in request: generate new UUID, emit
  `session_started` event as first SSE message.
- If session_id provided: look up; 404 if expired/unknown; resume
  context.
- Stream continues until model emits final `verdict` + zero-or-more
  `recommended_action` events, OR until a `user_question` pauses it.

**3. POST /troubleshoot/user-reply.**
- 404 if session_id expired/unknown.
- Validates question_id matches the most recent unanswered
  user_question for that session. Mismatch → 400.
- Appends reply_text to model context. Refreshes TTL.
- Emits `user_reply_received` event on the open SSE stream.
- Resumes model reasoning. Returns 200 + empty body.

**3a. Consecutive user_question events (built-in advisor post-impl catch).**
If the model emits a second `user_question` while the FIRST is still
unanswered (despite the runbook telling it not to), the container MUST
**reject the second event** at emit time — drop it from the SSE stream
and log a warning. Do NOT replace the pending question: the app's
chat-bubble state machine is built around one-pending-question-per-
session and would break on a swap. Two pending questions in the
session_state dict would also create ambiguity about which question_id
a /user-reply call answers.

**3b. Lifecycle edge cases (Codex post-impl MED-HIGH).**
- **Repeated /user-reply with same question_id**: idempotent. Container
  returns 200 + emits a second `user_reply_received` event (matches
  the first). Reply text is appended only on first call; subsequent
  calls are no-ops. Reason: BLE retries are real; client may resend
  the same reply if the SSE ack didn't reach them.
- **/user-reply with a question_id that doesn't match the pending one**:
  400 `question_id_mismatch`. Could be a stale reply from a long-
  ago question, or a buggy client.
- **/user-reply when no question is pending**: 400
  `question_id_mismatch` (same code; the spec is "must match the
  currently-pending question_id" which is empty if none pending).
- **/phone-context arriving while a user_question is pending**: accept
  it. phone-context is orthogonal context data — not an answer to the
  question. Container ingests it, refreshes TTL, returns 200. Model
  still waits for the actual reply via /user-reply before resuming.
- **Repeated /phone-context calls in the same session**: each call
  REPLACES the previous phone_context (the model only reasons over
  the most recent snapshot — phone state changes fast).

**4. POST /troubleshoot/phone-context.**
- 404 if session_id expired/unknown.
- Validates phone_context against phone_context.schema.json. 400 if
  invalid.
- Ingests as virtual tool result in model context. **phone_context is
  NOT emitted on SSE** — Codex pre-impl Q8 catch: `tool_result` has
  no `tool` field and `additionalProperties: false`, so the plan's
  wording "virtual tool_result with tool: 'phone_context'" can't go
  on the wire. Internally the container stuffs `[Phone context
  attached: ...]` into the next prompt segment.
- Refreshes TTL. Returns 200.

### Phase 11 error body shape

For 4xx responses from /troubleshoot, /troubleshoot/user-reply, and
/troubleshoot/phone-context, return:
```json
{"error": "<code>", "detail": "<short human-readable>"}
```
Codes: `session_not_found` (404), `question_id_mismatch` (400),
`phone_context_invalid` (400), `body_invalid` (400),
`session_cap_reached` (503 — 50 concurrent slots full).

### Phase 11 PRIVACY contract

phone_context contains wifi_ssid, BSSIDs (in recent_network_changes),
IP-bearing error strings (in recent_connection_attempts). Per plan
+ Codex pre-impl MEDIUM-HIGH:

- phone_context NEVER leaves the blox. No central upload channel.
- Container MUST NOT log raw phone_context to `/var/log/fula/`
  (ai-actions.jsonl, events.jsonl, or container stdout/stderr).
- Validation errors that echo input fields MUST sanitize SSID, BSSID,
  IP addresses before emit (e.g. log `phone_context.netinfo.wifi_ssid:
  <redacted>` not the actual value).
- phone_context discarded on session end (in-memory only — when the
  session entry is evicted from the dict, the data is gone).
- The audit log line schema deliberately has NO field for
  phone_context (test enforces).

This is a UX/privacy contract, not a security boundary — a compromised
container can still read the file via the running process. The contract
prevents accidental disclosure via logs + central channels.

## Phase 12+ extensions

Phase 12 will wire the app-side `phoneLogger.ts` + Diagnostics screen
UX to actually call `/troubleshoot/phone-context` and render
`user_question` events as chat bubbles with inputs. Same versioning
treatment if new events land (schema_version + $id bump per the
closed-schema discipline).
