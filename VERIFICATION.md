# Verification matrix

Last evidence review: **2026-08-15**.

| Claim | Status | Evidence / boundary |
|---|---|---|
| Telegram webhook intake must be idempotent against duplicate/redelivered updates | VERIFIED design requirement | Bot API update model + durable `(bot_id, update_id)` uniqueness; runtime test exercises dedupe. |
| `sendMessage` text limit is 1–4096 characters after entities parsing | VERIFIED | Current Telegram Bot API documentation. |
| Single-chat sustained sends should stay around <=1 msg/s; groups <=20/min; free bulk around 30/s | VERIFIED as current platform guidance | Current Telegram Bots FAQ; treat as time-sensitive and honor 429 `retry_after`. |
| Paid broadcasts can provide higher bulk throughput | VERIFIED at high level | Current Telegram Bots FAQ; eligibility/cost details are intentionally not hard-coded here. |
| `sendMessageDraft` exists for generated partial-message UX | VERIFIED | Current Telegram Bot API; use is optional and time-sensitive. |
| Historical “Get or create active session” SQL created a session | REJECTED | Previous reference only updated an existing row. Canonical `get_or_create_session()` now inserts when none exists. |
| Canonical schema enforces bot scoping through RLS | VERIFIED_IN_CI when green | `schema/telegram_agent_router.sql` + `tests/runtime.sql` under a non-bypass role. |
| Queue claim uses PostgreSQL `FOR UPDATE SKIP LOCKED` | VERIFIED_IN_CI when green | Canonical function + PostgreSQL 18 runtime test. |
| A specific production bot meets throughput/latency/recovery/privacy requirements | NOT_PROVEN by this repository | Requires target environment, workload, legal policy and end-to-end runtime evidence. |
| An LLM classifier may authorize privileged actions by itself | REJECTED | Routing output selects a bounded agent; runtime policy/human gates authorize sensitive capabilities. |

## Authoritative upstream references

- Telegram Bot API: `https://core.telegram.org/bots/api`
- Telegram Bots FAQ: `https://core.telegram.org/bots/faq`
- PostgreSQL 18 row locking / `SKIP LOCKED`: `https://www.postgresql.org/docs/18/sql-select.html`
- PostgreSQL RLS: `https://www.postgresql.org/docs/18/ddl-rowsecurity.html`

## Re-verification triggers

Re-check time-sensitive facts when:

- Telegram Bot API or FAQ changes;
- message/draft/rate-limit behavior changes;
- PostgreSQL major version changes;
- RLS/session/job schema changes;
- routing confidence thresholds or agent capability boundaries change.

## Proof vocabulary

- `VERIFIED` — authoritative source or direct deterministic evidence supports the exact scoped claim.
- `VERIFIED_IN_CI` — repository runtime/static test proves the scoped invariant when the current run is green.
- `PARTIAL` — evidence exists but a material runtime property is missing.
- `NOT_PROVEN` — do not state target-production behavior as fact.
- `REJECTED` — prior/tempting claim is intentionally disallowed because it is incorrect or unsafe.
