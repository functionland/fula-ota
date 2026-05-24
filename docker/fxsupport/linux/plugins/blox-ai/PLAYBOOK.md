# Blox AI operator playbook

Triage runbook for the things that go wrong with a deployed Blox AI plugin. **Internal-facing**; written for the developer / on-call person, not end users.

When in doubt: check `/var/log/fula/events.jsonl` and `/var/log/fula/ai-actions.jsonl` first. Most operational questions are answered there.

## Canary roll-out

We have two tags on the fxsupport image (and on the blox-ai container image):

- `:test` — the canary tag. Devices opted into the test ring auto-update to this. Typically 5–20 devices.
- `:release` — the GA tag. The rest of the fleet.

**Canary cadence**: ship Cluster B (Phase 6–12) to `:test` first. Watch for 2 weeks. Promote to `:release` only if:

1. No "device went silent after update" reports from canary users (Layer 1 self-supervision regressions).
2. ≥80% of canary support tickets reach a verdict + at least one tier-2 recommendation (not just "AI failed to diagnose").
3. Zero destructive-action mishaps in the audit log on any canary device.
4. No `blox-ai.service` restart loops (`systemctl is-failed blox-ai.service` returns `inactive` on all canaries).

For Cluster C (Phase 13+): same pattern, but the Phase 13 kubo-hang escalation ships behind `KUBO_HANG_ESCALATION=1` env flag — enable on canaries first via a one-line `/etc/default/fula-readiness` (or wherever we wire env vars), watch for 2 weeks, then flip on `:release`.

## Triage scenarios

### A bad fine-tuned model went out and is misbehaving

**Symptoms**: AI confidently proposes wrong actions; verdicts don't match diag/* output; tool-call loop runs >50 calls without converging; users complain "AI told me to reboot for no reason."

**Fix**: publish a new manifest with `rollback_required: true`. Devices switch to the prior model on next plugin restart.

```bash
# Author the rollback manifest
cat > /tmp/ai-manifest-rollback.json <<'EOF'
{
  "schema_version": 1,
  "current":  { "model_version": "BAD-VERSION", "url": "...", "sha256": "...", "size_bytes": 3000000000 },
  "rollback": { "model_version": "KNOWN-GOOD", "url": "...", "sha256": "...", "size_bytes": 3000000000 },
  "rollback_required": true,
  "manifest_version": 5,
  "published_at": "2026-06-01T10:00:00Z"
}
EOF

# Publish to the CDN at the manifest URL (your tooling here).
# Devices pick up the rollback on the next plugin restart cycle.

# Verify on a known device after restart:
ssh pi@<device> "grep 'Phase 18 manifest source' /var/log/fula/install.log | tail -3"
# Expect: Phase 18 manifest source: manifest_rollback
```

Once `current` is replaced with a fixed build: publish another manifest with `rollback_required: false` and the fixed model in `current`. Demote the bad model to `rollback` (or to a new entry).

### A runbook recipe is wrong and the AI keeps citing it

**Symptoms**: model verdict cites a specific runbook section that gives bad advice; users report AI suggested the wrong fix for a specific symptom.

**Fix**: edit `runbook.md` in-repo, bump `runbook_version`, push OTA. After the OTA pushes the new runbook to devices:

```bash
ssh pi@<device> "sudo bash /home/pi/.internal/plugins/blox-ai/reload_runbook.sh"
# Expect: runbook_version=N schema_version=1
#         reload_runbook: sending SIGHUP to blox-ai
```

Check the swap landed:
```bash
ssh pi@<device> "sudo journalctl -u blox-ai.service -n 20 | grep runbook_reload"
# Expect: a runbook_reload event with old + new runbook_version
```

If the SIGHUP swap is refused (refuse_schema for a schema bump, refuse_downgrade for a stale push, refuse_malformed for a broken file): the container keeps the previous runbook. Fix the file and re-push.

### Audit log shows an action that shouldn't have happened

**Symptoms**: `/var/log/fula/ai-actions.jsonl` shows a tier-3 execution that the user denies approving; or executor_busy errors that hint at a race; or an action not in the whitelist that somehow ran.

**Triage steps**:
1. `executed: false` lines with `rejected_reason: action_not_in_whitelist` are GOOD — they prove the whitelist is firing. The model proposed something off-list; executor rejected.
2. `executed: true` lines: cross-reference `request_id` against container logs (`journalctl -u blox-ai.service | grep <request_id>`) to find the original `/execute-action` POST. Verify `approver_transport` (`ble` / `libp2p` / `isolated_stage`) matches what the user remembers.
3. `approval_token_invalid` repeated for the same `action_id`: usually a replay attempt or a buggy client. Note the source.
4. `whitelist_hash` per line ties the line to the EXACT whitelist that was active. If `whitelist_hash` differs across two lines for the same action, someone edited the whitelist in between.
5. Tier-3 executed lines: `security_code_valid: true` confirms the user supplied the right code. If it's `true` but the user claims they didn't approve, suspect shoulder-surfing or compromised pairing.

### Device stuck in reboot loop after Phase 1.1 recovery fires

**Symptoms**: `journalctl -b -1 -u fula-readiness-check-recover.service` shows it ran, then the device rebooted, and the device is unhealthy after reboot.

**Triage**:
1. `cat /run/fula-recover-rebooted` — if present, the sentinel-capped reboot already happened this boot. The recover unit will NOT trigger another reboot until next manual reset.
2. `journalctl -u fula-readiness-check.service -b 0 -n 200` — what's killing readiness-check.py NOW? Deterministic config error vs flaky external dep?
3. If deterministic config error (bad `/etc/fula/...` after OTA): fix the file, `rm /run/fula-recover-rebooted`, `systemctl reset-failed fula-readiness-check.service`, `systemctl start fula-readiness-check.service`.

### Container OOM killing blox-ai during a session

**Symptoms**: `/run/fula-containers.state` shows `blox-ai` with `OOMKilled: true` and rising `RestartCount`.

**Diagnosis**: RK3588 has 7.7 GB RAM. With kubo + cluster + go-fula + AI model resident: tight. The 3 GB Qwen budget leaves ~700 MB headroom; concurrent large tool-call outputs can push past.

**Mitigations**:
- Short term: `docker update --memory-swap=-1 blox-ai` to allow swap.
- Longer term: the runbook should be teaching the model to cap tool-call output size. If it isn't, add a recipe explicitly telling it not to dump full container logs.
- Last resort: instruct the user to uninstall the plugin and use manual `diag/*` panels until we ship a smaller-RAM-footprint model variant.

### Isolation-mode timer firing too often / not enough

**Symptoms**: `journalctl -u blox-ai-isolation.timer` shows fires every 15 min OR not at all over a day on an offline device.

**Diagnosis**: timer is `OnBootSec=15min, OnUnitActiveSec=6h, Persistent=true`. Fires once 15 min after boot, then every 6h. If `Persistent=true` is firing repeatedly after long downtime, it's catching up missed runs.

**Tuning**: if the 15 min initial delay is too noisy on a freshly-installed device, edit the `.timer` file and bump `OnBootSec` to `1h`. Don't lower below 15 min — the device needs time to settle after boot.

### Transcript upload server (Phase 20) flooded with rejections

**Symptoms**: `fula-ai-training` server logs show a wave of `anonymization_check_failed scanner=<X>` lines.

**Triage**:
1. Group by `scanner=` to see which PII category. `ipv4_literal` after a recent app release ⇒ the on-device anonymizer regex for IPv4 regressed.
2. Group by `anonymizer_version=` — the version is logged with every accepted AND rejected request. Wave of rejections from a single version ⇒ ship a fix for THAT version's anonymizer; don't yank the whole intake.
3. The fixture `server/tests/fixtures/canonical_js_anonymizer_output.json` is the byte-for-byte contract; if changes need to land, update BOTH halves of the cross-runtime drift gate (apps/box jest + Python pytest) in lockstep.

## What's NOT in this playbook

- Container-internal debugging (RKLLM toolkit version mismatches, NPU driver gaps, model load failures): see `functionland/blox-ai` repo. We track its version in `info.json`.
- Fula stack debugging not specific to AI (kubo cluster pebble corruption, WG handshake drift, etc.): see the parent `docker/fxsupport/linux/README.md` and `readiness-check.py` source comments.
- LoRA fine-tune pipeline issues: see the Phase 19 sub-plan at `~/.claude/plans/fula-ai-training-pipeline.md` and the `fula-ai-training` repo.

## When to escalate

If you've gone through this playbook and you're still stuck after 15–30 min of triage:

1. Capture the device's `/var/log/fula/` directory + the last 1000 lines of `journalctl -u blox-ai.service` + the last 1000 lines of `journalctl -u fula-readiness-check.service`. Tar it.
2. File an issue on `functionland/fula-ota` with the `blox-ai-plugin` label, attach the tar, link to the manifest version + image SHA from `info.json`.
3. If it's a user-facing destructive-action incident (not a stability bug): also email the ops team. Audit log line + request_id is enough to start.
