---
name: telegram-agent-router
description: >
  Multi-agent Telegram bot architecture with PostgreSQL-native state management.
  10+ specialized agents, intent-based routing, persistent cross-session memory,
  and production-grade conversation state machines. Activate when building or
  debugging Telegram bots with multiple agents, routing logic, conversation
  context, or persistent memory. Trigger phrases: "telegram bot agents",
  "multi-agent telegram", "route messages to agents", "telegram bot router",
  "conversation state telegram", "persistent memory bot", "telegram intent
  classification", "agent handoff telegram", "telegram session state",
  "specialize telegram bot", "telegram webhook architecture".
---

# Telegram Agent Router — Multi-Agent Architecture

> **Core thesis**: A Telegram bot is not a chatbot. It is a routing layer
> over a team of specialists, backed by a PostgreSQL state machine.
> Every message is a dispatch decision. Every conversation is a session.
> Every session has memory.

This skill documents the architecture, patterns, and production code for
building Telegram bots that coordinate multiple specialized AI agents with
PostgreSQL-native state, intent-based routing, and persistent cross-session memory.

**Targets production multi-agent Telegram deployments with durable PostgreSQL state.**

---

## ARCHITECTURE OVERVIEW

```
User
 │
 ▼ HTTPS (Telegram sends to your endpoint)
┌────────────────────────────────────────────┐
│  WEBHOOK RECEIVER                          │
│  /telegram/webhook                         │
│  Validates token · Deduplicates · Queues   │
└──────────────┬─────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────┐
│  INTENT CLASSIFIER                         │
│  command → direct dispatch                 │
│  free text → LLM classification           │
│  ambiguous → confidence check             │
└──────────────┬─────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────┐
│  ROUTER                                    │
│  Loads session state from PostgreSQL       │
│  Selects target agent                      │
│  Injects memory context                    │
│  Dispatches with typed contract            │
└──────────────┬─────────────────────────────┘
               │
        ┌──────┴──────┐
        ▼             ▼
  [Agent A]      [Agent B]  ···  [Agent N]
  Specialized    Specialized
  prompt +       prompt +
  tools          tools
        │             │
        └──────┬──────┘
               ▼
┌────────────────────────────────────────────┐
│  MEMORY WRITER (PostgreSQL)                │
│  Saves: message, agent used, result        │
│  Updates: session state, user preferences  │
│  Emits: NOTIFY for async post-processing   │
└──────────────┬─────────────────────────────┘
               │
               ▼
         Telegram API
         sendMessage()
```

---

## THE THREE CONSTRAINTS YOU CANNOT IGNORE

Before any architecture decision, internalize these Telegram realities:

### 1. Webhook Delivery Must Be Idempotent
Telegram can retry webhook delivery after an unsuccessful or interrupted response.
Do not depend on a universal fixed timeout: return a successful response quickly,
deduplicate by `update_id`, and process slow LLM work outside the request cycle.

```python
# ❌ WRONG — LLM call blocks webhook, causes retries
@app.post("/telegram/webhook")
async def webhook(update: dict):
    response = await llm.generate(update["message"]["text"])  # 5-8 seconds
    await send_message(response)
    return {"ok": True}

# ✅ CORRECT — Acknowledge immediately, process asynchronously
@app.post("/telegram/webhook")
async def webhook(update: dict):
    await job_queue.enqueue(update)   # < 5ms
    return {"ok": True}              # Return immediately

# Worker processes the job outside the webhook cycle
async def worker():
    while True:
        job = await dequeue()
        response = await llm.generate(job["text"])   # Takes as long as needed
        await send_message(job["chat_id"], response)
```

### 2. The 4096 Character Limit
Every message sent via `sendMessage` has a hard 4096-character cap.

```python
async def send_safe(chat_id: int, text: str) -> list[dict]:
    """Split long responses respecting Telegram's limit and word boundaries."""
    if len(text) <= 4096:
        return [await send_message(chat_id, text)]

    chunks = []
    while text:
        if len(text) <= 4096:
            chunks.append(text)
            break
        # Split at last newline before limit (don't cut mid-sentence)
        split_at = text[:4096].rfind('\n')
        if split_at == -1:
            split_at = text[:4096].rfind(' ')
        if split_at == -1:
            split_at = 4096
        chunks.append(text[:split_at])
        text = text[split_at:].lstrip()

    results = []
    for chunk in chunks:
        results.append(await send_message(chat_id, chunk))
    return results
```

### 3. The Rate Limit
Telegram allows max **30 messages/second** globally and **1 message/second per chat**.
A busy bot processing messages faster than this will receive 429 errors.

```python
import asyncio
from collections import defaultdict, deque

class RateLimiter:
    def __init__(self):
        self._locks: dict[int, asyncio.Lock] = defaultdict(asyncio.Lock)
        self._last_sent: dict[int, float] = {}
        self._global_lock = asyncio.Lock()
        self._global_sends: deque[float] = deque()

    async def send(self, chat_id: int, text: str):
        async with self._locks[chat_id]:
            loop = asyncio.get_running_loop()
            now = loop.time()
            elapsed = now - self._last_sent.get(chat_id, 0)
            if elapsed < 1.0:
                await asyncio.sleep(1.0 - elapsed)

            async with self._global_lock:
                now = loop.time()
                while self._global_sends and now - self._global_sends[0] >= 1.0:
                    self._global_sends.popleft()
                if len(self._global_sends) >= 30:
                    await asyncio.sleep(1.0 - (now - self._global_sends[0]))
                    now = loop.time()
                    while self._global_sends and now - self._global_sends[0] >= 1.0:
                        self._global_sends.popleft()
                self._global_sends.append(loop.time())

            await _send_message_api(chat_id, text)
            self._last_sent[chat_id] = loop.time()
```

---

## POSTGRESQL SCHEMA — THE COMPLETE STATE MACHINE

```sql
-- See references/postgres-schema.md for complete DDL with indexes and RLS
```

Core tables: `bot_sessions`, `bot_messages`, `bot_agent_registry`,
`bot_memory`, `bot_job_queue`, `bot_dispatch_log`

---

## ROUTING DECISION TREE

```
Incoming message
      │
      ├── Is it a COMMAND? (starts with /)
      │         │
      │         ├── Known command → Direct dispatch to registered agent
      │         └── Unknown command → Error + help menu
      │
      ├── Is there an ACTIVE SESSION with locked agent?
      │         │
      │         └── Yes → Continue with same agent (multi-turn flow)
      │
      ├── Is it a CALLBACK QUERY? (inline keyboard button)
      │         │
      │         └── Yes → Dispatch to agent that owns the callback prefix
      │
      └── Free text → Intent classification
                │
                ├── HIGH confidence (> 0.8) → Dispatch to classified agent
                ├── MEDIUM confidence (0.5-0.8) → Ask for clarification
                └── LOW confidence (< 0.5) → Default to orchestrator agent
```

Full implementation: `references/router-patterns.md`

---

## AGENT CONTRACT — THE TYPED INTERFACE

Every agent must implement this interface. Non-negotiable.

```python
from dataclasses import dataclass, field
from typing import Optional

@dataclass
class AgentContext:
    user_id: int
    chat_id: int
    session_id: str
    session: dict
    message: str
    recent_history: list[dict]      # Last N messages for context
    user_memory: list[dict]         # Persistent facts about this user
    active_flow: Optional[str] = None  # Multi-step flow identifier

@dataclass
class AgentResponse:
    text: str                        # Response to send to user
    agent_name: str                  # Which agent produced this
    memory_writes: list[dict] = field(default_factory=list)
    lock_session: Optional[str] = None
    unlock_session: bool = False
    follow_up_job: Optional[dict] = None
    flow_state_update: Optional[dict] = None

class AgentBase:
    name: str
    description: str                 # Used by LLM orchestrator for routing
    commands: list[str]              # /commands this agent handles
    intent_keywords: list[str]       # Keywords for fast-path routing
    max_context_messages: int = 10   # How much history to load

    async def handle(self, ctx: AgentContext) -> AgentResponse:
        raise NotImplementedError

    def can_handle(self, message: str) -> float:
        """Returns confidence 0.0-1.0 that this agent should handle message."""
        raise NotImplementedError
```

Full patterns: `references/agent-design.md`

---

## MEMORY ARCHITECTURE

Two-tier memory model: **Working memory** (session-scoped) + **Long-term memory** (user-scoped).

```python
# Working memory: active in every request, auto-pruned
# Long-term memory: explicit writes, retrieved semantically

async def build_context(
    user_id: int,
    chat_id: int,
    session: dict,
    message: str,
) -> AgentContext:
    async with pool.acquire() as conn:
        # Working memory: last N messages this session
        history = await conn.fetch("""
            SELECT role, content, agent_name, created_at
            FROM bot_messages
            WHERE session_id = $1
            ORDER BY created_at DESC
            LIMIT $2
        """, session["id"], CONTEXT_WINDOW_MESSAGES)

        # Long-term memory: relevant facts about user
        memories = await conn.fetch("""
            SELECT key, value, confidence
            FROM bot_memory
            WHERE user_id = $1
              AND (expires_at IS NULL OR expires_at > NOW())
            ORDER BY accessed_at DESC
            LIMIT 20
        """, user_id)

        return AgentContext(
            user_id=user_id,
            chat_id=chat_id,
            session_id=session["id"],
            session=session,
            message=message,
            recent_history=[dict(r) for r in reversed(history)],
            user_memory=[dict(m) for m in memories],
            active_flow=session.get("locked_flow"),
        )
```

Full schema and retrieval patterns: `references/postgres-schema.md`

---

## CONTEXT COMPRESSION FOR LONG CONVERSATIONS

When history exceeds the LLM context window:

```python
async def compress_history(user_id: int, session_id: str, conn, llm) -> str | None:
    """Summarize old messages to stay within context limits."""
    old_messages = await conn.fetch("""
        SELECT role, content FROM bot_messages
        WHERE session_id = $1
          AND created_at < NOW() - INTERVAL '1 hour'
        ORDER BY created_at
        LIMIT 50
    """, session_id)

    if not old_messages:
        return None

    summary = await llm.generate(
        system="Summarize this conversation history in 3-5 bullet points. "
               "Focus on decisions made, facts learned, tasks completed.",
        user="\n".join(f"{m['role']}: {m['content']}" for m in old_messages)
    )

    # Store summary, mark originals as compressed
    await conn.execute("""
        INSERT INTO bot_memory (user_id, key, value, confidence)
        VALUES ($1, 'conversation_summary_' || $2, $3, 0.9)
        ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value
    """, user_id, session_id[:8], summary)

    await conn.execute("""
        UPDATE bot_messages SET compressed = true
        WHERE session_id = $1 AND created_at < NOW() - INTERVAL '1 hour'
    """, session_id)

    return summary
```

---

## PRODUCTION CHECKLIST

Before going live with a multi-agent Telegram bot:

```
Webhook
□ Webhook URL uses HTTPS (required by Telegram)
□ Secret token validated on every request
□ HTTP 200 returned in < 500ms (job queued, not processed)
□ Update ID deduplicated (Telegram may send duplicates on retry)
□ Webhook registered with setWebhook (verify with getWebhookInfo)

Routing
□ All /commands registered in agent registry
□ Fallback agent defined for unmatched intent
□ Confidence threshold tuned (0.6-0.8 is typical sweet spot)
□ Multi-turn session lock has a max TTL (prevent stuck sessions)

Memory
□ Long-term memory has TTL or explicit expiry
□ Compression runs for sessions > N messages
□ Sensitive data not stored in plaintext memory

Production
□ Connection pool sized correctly (not > PG max_connections / 3)
□ Rate limiter active (1 msg/sec per chat, 30/sec global)
□ Retry logic with exponential backoff on Telegram API errors
□ Dead letter queue for failed jobs
□ Dispatch log for debugging routing decisions
```

---

*See `references/` for complete implementations:*
- `postgres-schema.md` — Full DDL, indexes, RLS policies
- `router-patterns.md` — Intent classifier, dispatch engine, session FSM
- `agent-design.md` — Agent contracts, specialization principles, handoff
- `telegram-constraints.md` — Webhook patterns, rate limiting, message splitting
- `anti-patterns.md` — 8 production failures and their fixes
