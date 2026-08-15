# Privacy and security model

A multi-agent Telegram router processes identifiers, message content, inferred intent and potentially long-term memory. Treat these as sensitive application data.

## Trust boundaries

```text
Telegram
→ webhook boundary
→ durable intake
→ router/classifier
→ selected agent
→ bounded tools
→ external services
→ response
```

No boundary automatically inherits trust from the previous one.

## Webhook authenticity

- validate Telegram's configured webhook secret header;
- enforce request body size and JSON shape limits;
- reject unsupported update types;
- deduplicate `update_id` before expensive work;
- never log bot tokens or webhook secrets.

## Agent isolation

The routing decision chooses *which agent may handle the message*. It must not grant new capabilities.

Each agent should have:

- explicit tool allowlist;
- explicit data scope;
- bounded external side effects;
- human approval for sensitive actions where required;
- auditable route reason and agent identity.

A handoff does not transfer unrestricted authority.

## Prompt injection

Messages and content retrieved by agents are untrusted. They may ask the system to ignore policy, reveal secrets or call tools.

- system/developer policy outranks user/retrieved content;
- tool calls are authorized by runtime policy, not by text in a message;
- validate arguments before side effects;
- keep high-impact operations behind explicit approval/policy gates.

## RLS and bot scoping

The canonical SQL scopes rows by `bot_id` and uses the request-local setting `app.bot_id`. Missing context fails closed.

RLS proof requires a non-owner, non-superuser, non-`BYPASSRLS` application role. A query run as database owner is not tenant-isolation evidence.

## Memory policy

Separate:

- **session context** — short-lived conversational continuity;
- **explicit memory** — user-stated durable preference/fact;
- **inferred memory** — lower-confidence derived fact with source/confidence;
- **transactional truth** — authoritative business state that belongs in domain tables/services, not conversational memory.

Do not automatically convert every message into long-term memory.

Memory writes should carry:

- purpose/key;
- source (`explicit`, `inferred`, `system`);
- confidence for inferred facts;
- timestamp;
- optional expiry;
- agent/source provenance.

## Retention

Define product-specific retention for:

- raw update payloads;
- conversation messages;
- memory;
- failed jobs/errors;
- dispatch telemetry.

The schema provides `expires_at` on sensitive/operational tables so indefinite retention is not the default architectural assumption.

## Logging

Prefer structured metadata over raw content:

```text
update_id
bot_id
route_reason
target_agent
latency_ms
success
error_class
```

Avoid logging full message bodies, tokens, cookies, authorization headers or tool secrets unless a narrowly scoped debugging policy explicitly requires sanitized content.

## Deletion/export

If the product/jurisdiction requires user deletion or export, design it across messages, memory and derived data. Cascades and retention jobs should be tested before claiming compliance.

## Failure mode: duplicate side effects

Webhook dedupe protects intake, not every downstream action. External payments, emails, tickets or other actions need their own idempotency key/transaction boundary.

## Failure mode: classifier overreach

An intent classifier must not be allowed to convert low-confidence text directly into a privileged operation. Route to clarification/fallback when confidence or policy is insufficient.
