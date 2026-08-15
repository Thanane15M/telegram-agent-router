---
name: telegram-agent-router
description: >
  Designs and reviews durable Telegram multi-agent routing with idempotent webhook
  intake, fast-path intent routing, bounded agent contracts, PostgreSQL-backed
  sessions/memory/jobs, rate-limit handling, and privacy-aware auditability. Use
  when building or debugging Telegram bots that coordinate multiple specialized
  agents, persistent conversation state, handoffs, callbacks, or background work.
---

# Telegram Agent Router

A Telegram bot with multiple specialists should be designed as a **message router with durable state**, not as one giant prompt.

The architecture in this repository optimizes for:

- idempotent webhook intake;
- prompt response to Telegram while slow work continues asynchronously;
- deterministic fast paths before LLM routing;
- explicit agent contracts and bounded permissions;
- durable PostgreSQL state where it fits the workload;
- privacy-aware memory and audit data;
- measurable routing quality and failure recovery.

## Core architecture

```text
Telegram update
→ webhook authenticity + update validation
→ durable dedupe/enqueue
→ successful acknowledgment
→ worker
→ active-session lookup/create
→ command/callback/session-lock fast path
→ bounded intent classification only if needed
→ agent contract
→ response validation
→ Telegram send with Retry-After handling
→ memory/audit writes under retention policy
```

Do not run a slow LLM call as the only work inside the webhook request path. Telegram can retry unsuccessful/interrupted deliveries; deduplicate using `update_id` before executing expensive work.

## Routing order

Prefer deterministic routing before an LLM classifier:

1. known command;
2. callback prefix owned by a registered handler;
3. active flow/session lock;
4. high-confidence deterministic intent hints;
5. bounded classifier for ambiguous free text;
6. orchestrator/fallback.

Low confidence should not silently become a high-impact action. Ask for clarification or route to a bounded fallback.

## Agent contract

Every agent must expose a narrow interface and explicit capability boundary.

```python
from dataclasses import dataclass, field
from typing import Any

@dataclass(frozen=True)
class AgentContext:
    bot_id: str
    user_id: int
    chat_id: int
    session_id: str
    message: str
    recent_history: tuple[dict[str, Any], ...] = ()
    user_memory: tuple[dict[str, Any], ...] = ()
    active_flow: str | None = None

@dataclass
class AgentResponse:
    text: str
    agent_name: str
    memory_writes: list[dict[str, Any]] = field(default_factory=list)
    follow_up_job: dict[str, Any] | None = None
    lock_flow: str | None = None
    unlock_flow: bool = False
```

Tool access is not inherited just because one agent hands work to another. The dispatcher must select an agent and the runtime must enforce that agent's own permissions.

## Durable state model

The executable PostgreSQL schema is [`schema/telegram_agent_router.sql`](schema/telegram_agent_router.sql).

Key design choices:

- `bot_id` scopes every tenant/bot-owned row;
- RLS policies fail closed when `app.bot_id` is missing;
- `get_or_create_session()` actually inserts a session when none exists;
- `update_id` is unique per bot for webhook dedupe;
- jobs are durable rows claimed with `FOR UPDATE SKIP LOCKED`;
- messages, memory, jobs and audit rows carry expiration/retention fields where appropriate;
- long-term memory is explicit, not an automatic dump of every conversation.

PostgreSQL suitability still depends on measured workload. A durable broker/stream or external store remains justified when required semantics or isolation exceed the PostgreSQL design.

## Telegram message limits and flood control

Do not hard-code one universal “30 messages/sec” limiter for all traffic classes.

Current Telegram guidance distinguishes at least:

- single-chat pacing — avoid sustained rates above roughly one message per second;
- groups — tighter per-minute limits apply;
- bulk notifications — free broadcast throughput is around tens of messages per second;
- paid broadcasts — eligible bots can obtain higher broadcast throughput.

Always honor API `429` responses and `retry_after`. Treat numeric platform limits as upstream facts that can change; see [`references/telegram-constraints.md`](references/telegram-constraints.md) and `VERIFICATION.md`.

## Long responses

`sendMessage` accepts text up to the Bot API's documented character limit. Chunk only at safe boundaries and validate after entity parsing/formatting. The executable reference implementation includes a deterministic splitter in [`examples/router_contract.py`](examples/router_contract.py).

For supported private-chat scenarios, Telegram also exposes draft-streaming methods such as `sendMessageDraft`. Treat draft streaming as optional UX; the durable final message still follows the normal send path and current upstream constraints must be checked.

## Memory and privacy

Conversation content, user IDs, inferred preferences and dispatch logs can be personal data.

- collect only what the product needs;
- separate short-lived session context from deliberate long-term memory;
- attach source/confidence to inferred memory;
- define expiration/retention instead of “forever” by default;
- test RLS through a non-bypass application role;
- do not place secrets or full credentials in memory/audit text;
- support deletion/export obligations required by the product's jurisdiction and policy.

## Failure handling

A production-capable design needs more than a queue table:

- idempotency for incoming updates and downstream side effects;
- retry budget and `retry_after` support;
- processing timeout/reaper for abandoned jobs;
- dead-letter/failure inspection;
- bounded context size;
- explicit handling of partial Telegram sends;
- observability for route reason, confidence, latency, retries and failures.

## Verification workflow

Before claiming the architecture works:

1. `python scripts/validate_markdown.py`
2. `python scripts/validate_skill.py`
3. `python -m unittest discover -s tests -p 'test_*.py'`
4. run `schema/telegram_agent_router.sql` and `tests/runtime.sql` against PostgreSQL 18 or the production target major;
5. inspect current Telegram Bot API/FAQ for time-sensitive limits;
6. classify untested target-bot behavior as `NOT_PROVEN`.

## References

- Current Telegram constraints: [`references/telegram-constraints.md`](references/telegram-constraints.md)
- Agent design patterns: [`references/agent-design.md`](references/agent-design.md)
- Router patterns: [`references/router-patterns.md`](references/router-patterns.md)
- Anti-patterns: [`references/anti-patterns.md`](references/anti-patterns.md)
- Privacy/security model: [`references/privacy-security.md`](references/privacy-security.md)
- Preserved pre-refactor skill: [`references/SKILL.pre-2026-08-15.md`](references/SKILL.pre-2026-08-15.md)
- Verification matrix: [`VERIFICATION.md`](VERIFICATION.md)
- Evals: [`evals/cases.jsonl`](evals/cases.jsonl)
