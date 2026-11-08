# Verification matrix

Last evidence review: **2026-11-08**. Reviewed latest Telegram release: **Bot API 10.3 (2026-08-24)**.

| Claim | Status | Evidence / boundary |
|---|---|---|
| Telegram webhook intake must be idempotent against duplicate/redelivered updates | VERIFIED design requirement | Bot API update model + durable `(bot_id, update_id)` uniqueness; runtime test exercises dedupe. |
| `sendMessage` text limit is 1–4096 characters after entities parsing | VERIFIED | Current Telegram Bot API documentation. |
| Single-chat sustained sends should stay around <=1 msg/s; groups <=20/min; free bulk around 30/s | VERIFIED as current platform guidance | Current Telegram Bots FAQ; treat as time-sensitive and honor 429 `retry_after`. |
| Paid broadcasts can provide higher bulk throughput | VERIFIED at high level | Current Telegram Bots FAQ; eligibility/cost details are intentionally not hard-coded here. |
| `sendMessageDraft` exists for generated partial-message UX | VERIFIED | Current Telegram Bot API; use is optional and time-sensitive. |
| Bot API 10.0 (2026-05-08) introduced bot-to-bot messaging by username when both bots enable bot-to-bot communication | VERIFIED upstream; target deployment NOT_PROVEN | Official Telegram Bot API 10.0 changelog; peer allowlists, loop control and target runtime remain untested. A target deployment's peer allowlist, loop budget and runtime behavior remain NOT_PROVEN here. |
| Bot API 10.2 (2026-07-14) introduced ephemeral messages, `ephemeral_message_id` and separate edit/delete/reply methods | VERIFIED upstream; identity separation VERIFIED_IN_CI when green | Official Telegram Bot API changelog + `tests/ephemeral_identity.sql`. Webhook `update_id` remains the intake dedupe key. This repository proves distinct storage identity only; target-bot ephemeral behavior remains NOT_PROVEN. |
| Bot API 10.3 (2026-08-24) replaced the original `receiver_user_id`/`callback_query_id` send parameters with `ephemeral_message_parameters` | VERIFIED upstream; storage identity VERIFIED_IN_CI when green | Official Telegram Bot API changelog + additive `schema/ephemeral_messages_10_2.sql`. Send/edit/delete/reply API behavior for a target bot remains NOT_PROVEN. |
| Historical “Get or create active session” SQL created a session | REJECTED | Previous reference only updated an existing row. Canonical `get_or_create_session()` now inserts when none exists. |
| Canonical schema enforces bot scoping through RLS | VERIFIED_IN_CI when green | `schema/telegram_agent_router.sql` + `tests/runtime.sql` under a non-bypass role. |
| Queue claim uses PostgreSQL `FOR UPDATE SKIP LOCKED` | VERIFIED_IN_CI when green | Canonical function + PostgreSQL 18 runtime test. |
| Expired processing leases are reaped to `retrying` or terminal `failed`, and a reaped job can be reclaimed by a new worker | VERIFIED_IN_CI when green | `schema/durable_coordination.sql` + `tests/durable_coordination.sql` on PostgreSQL 18. |
| Agent-to-agent message retries are payload-aware idempotent; reservations/redelivery preserve first delivery; ACK is idempotent and stale executions are rejected | VERIFIED_IN_CI when green | `tests/durable_coordination.sql`; scope is the PostgreSQL coordination contract, not network transport delivery. |
| Reply-linked, proactive and scheduled provenance are represented separately | VERIFIED_IN_CI when green | Schema check + runtime reply correlation test; application routing policy still determines which outbound actions are permitted. |
| A specific production bot meets throughput/latency/recovery/privacy requirements | NOT_PROVEN by this repository | Requires target environment, workload, legal policy and end-to-end runtime evidence. |
| An LLM classifier may authorize privileged actions by itself | REJECTED | Routing output selects a bounded agent; runtime policy/human gates authorize sensitive capabilities. |

## Authoritative upstream references

- Telegram Bot API: `https://core.telegram.org/bots/api`
- Telegram Bot API changelog: `https://core.telegram.org/bots/api-changelog`
- Telegram Bots FAQ: `https://core.telegram.org/bots/faq`
- PostgreSQL 18 row locking / `SKIP LOCKED`: `https://www.postgresql.org/docs/18/sql-select.html`
- PostgreSQL RLS: `https://www.postgresql.org/docs/18/ddl-rowsecurity.html`
- Comparative durable coordination design input reviewed 2026-10-02: `https://github.com/october-dev/october-bus` (design evidence only; no runtime dependency or copied implementation)

## Re-verification triggers

Re-check time-sensitive facts when:

- `UPSTREAM_BOT_API_VERSION` differs from the newest version advertised by the official Telegram changelog;
- Telegram Bot API or FAQ changes a marker used by `scripts/check_upstream_drift.py`;
- message/draft/rate-limit or bot-to-bot behavior changes;
- PostgreSQL major version changes;
- RLS/session/job schema changes;
- routing confidence thresholds or agent capability boundaries change.

## Proof vocabulary

- `VERIFIED` — authoritative source or direct deterministic evidence supports the exact scoped claim.
- `VERIFIED_IN_CI` — repository runtime/static test proves the scoped invariant when the current run is green.
- `PARTIAL` — evidence exists but a material runtime property is missing.
- `NOT_PROVEN` — do not state target-production behavior as fact.
- `REJECTED` — prior/tempting claim is intentionally disallowed because it is incorrect or unsafe.
