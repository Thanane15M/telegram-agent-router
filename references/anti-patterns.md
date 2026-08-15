# Anti-patterns — failure modes to test

These are architecture failure modes, not claims that one deployment choice is universally correct.

## 1. Slow work before durable dedupe

**Failure:** webhook handling calls an LLM/tool before recording `update_id`; retry can repeat cost/side effects.

**Correction:** validate → durable insert with unique `(bot_id, update_id)` → acknowledge → worker.

**Regression test:** deliver the same update twice and prove only one durable job/side-effect idempotency key is accepted.

## 2. Process-local deduplication

**Failure:** an in-memory set works until restart/horizontal scaling.

**Correction:** durable unique constraint or another shared idempotency authority.

## 3. Indefinite session/flow lock

**Failure:** a crashed/abandoned flow traps future messages.

**Correction:** explicit cancel/reset path, idle/expiry policy, and validation that the locked agent/flow still exists.

## 4. Unbounded conversation context

**Failure:** every message is sent to every agent forever, increasing cost and privacy exposure.

**Correction:** count/time/token bounded recent history, task-specific retrieval, deliberate summaries with provenance, and retention.

Do not use a universal “last N messages” as a magic constant; evaluate context sufficiency for each task class.

## 5. Prompt as access control

**Failure:** a prompt says “never refund without approval” but the model still has an unrestricted refund tool.

**Correction:** runtime permission/policy gate, idempotency, amount/role bounds and human approval where required.

## 6. Sensitive memory without purpose/expiry

**Failure:** secrets or highly sensitive personal data become persistent “memory.”

**Correction:** never store credentials/payment secrets in conversational memory; minimize data, record source/purpose, expire where appropriate.

## 7. Transport dogma

**Failure:** “webhook always” or “long polling always” is treated as a production law.

Telegram supports both webhook and long polling. Choose based on deployment/runtime requirements. For webhooks, dedupe and prompt acknowledgement are critical; for polling, correctly advance offsets and ensure one logical consumer model.

## 8. Omnipotent fallback

**Failure:** classification failure routes to a generic agent that has every tool.

**Correction:** fallback is intentionally low-authority: clarify, answer low-risk general questions, present capabilities, or escalate.

## 9. Holding DB resources across model/network latency

**Failure:** a worker keeps a transaction/connection open while waiting seconds for LLMs or external APIs, increasing lock/pool pressure.

**Correction:** short database transactions around durable state; release scarce resources before long external waits unless an explicit consistency pattern requires otherwise.

## 10. Classifier confidence as authorization

**Failure:** a numeric model confidence directly triggers a privileged action.

**Correction:** confidence helps routing/clarification; policy and approval authorize capabilities. Calibrate thresholds using evals, not generic example values.

## 11. Raw user text as permanent audit log

**Failure:** observability stores full conversations indefinitely when metadata would suffice.

**Correction:** log route reason, agent, timing, success/error class and minimal identifiers; store raw content only when necessary and under retention/access policy.

## 12. RLS tested as superuser

**Failure:** policies parse and owner queries pass, then isolation is declared verified.

**Correction:** positive/negative tests through non-owner, non-`BYPASSRLS` roles with missing and cross-bot context.

## 13. Telegram fixed-limit folklore

**Failure:** one hard-coded global 30 msg/s limiter is assumed correct forever.

**Correction:** separate traffic classes, honor 429 `retry_after`, keep current platform facts in a versioned verification file, and re-check upstream changes.

## 14. Duplicate downstream effects

**Failure:** webhook job is deduped, but retries create two invoices/emails/payments.

**Correction:** propagate stable idempotency keys to each external effect or use a transactional outbox/consumer contract appropriate to that service.

The pre-2026-08-15 anti-patterns are preserved at `anti-patterns.pre-2026-08-15.md`.
