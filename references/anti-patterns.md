# Anti-Patterns — 8 Production Failures and Their Fixes

Every pattern here has been encountered in production Telegram bots.
Each one is silent until it breaks everything at scale.

---

## 1. Synchronous LLM in Webhook Handler

```python
# ❌ BREAKS at ~10 concurrent users. Telegram starts retrying. You get duplicate messages.
@app.post("/webhook")
async def webhook(update: dict):
    response = await llm.generate(update["message"]["text"])  # 3-8 seconds
    await send_message(response)
    return {"ok": True}

# ✅ Queue immediately, process in worker
@app.post("/webhook")
async def webhook(update: dict):
    await enqueue(update)         # < 5ms
    return {"ok": True}           # Telegram is satisfied
```

**Why it breaks**: Telegram retries after 3 seconds. If your handler takes 4 seconds,
Telegram sends the same message again. Now you have two LLM calls, two responses,
a confused user, and doubled cost.

---

## 2. No Update ID Deduplication

```python
# ❌ On network hiccup, Telegram resends. User gets duplicate responses.
async def process(update: dict):
    await handle(update)

# ✅ Deduplicate by update_id
async def process(update: dict):
    update_id = update["update_id"]
    async with pool.acquire() as conn:
        inserted = await conn.fetchval("""
            INSERT INTO bot_job_queue (update_id, update_json, status)
            VALUES ($1, $2, 'pending')
            ON CONFLICT (update_id) DO NOTHING
            RETURNING id
        """, update_id, json.dumps(update))
        if not inserted:
            return   # Already processed
```

Add `UNIQUE (update_id)` to your job queue table.

---

## 3. Session Lock Without TTL

```python
# ❌ Agent sets session lock, then crashes mid-flow.
# User is permanently locked to a broken flow. No way out.
await conn.execute(
    "UPDATE sessions SET locked_agent = $2 WHERE id = $1",
    session_id, 'onboarding'
)

# ✅ Always set lock expiry. Always honor /cancel.
await conn.execute("""
    UPDATE sessions
    SET locked_agent = $2,
        lock_expires_at = NOW() + INTERVAL '10 minutes'  -- Auto-release
    WHERE id = $1
""", session_id, 'onboarding')

# In your webhook handler, always check /cancel first:
if text == '/cancel' or text == '/reset':
    await conn.execute("""
        UPDATE sessions
        SET locked_agent = NULL, locked_flow = NULL, flow_state = '{}'
        WHERE id = $1
    """, session_id)
    await send("Flow cancelled. What would you like to do?")
    return
```

---

## 4. Passing Full Conversation History to Every Agent

```python
# ❌ History grows unboundedly. Token costs explode. Context window exceeded.
history = await conn.fetch(
    "SELECT * FROM messages WHERE session_id = $1 ORDER BY created_at", session_id
)
# After 50 messages: 25,000 tokens of history just for context

# ✅ Time-bound + count-bound. Compress old messages.
history = await conn.fetch("""
    SELECT role, content FROM messages
    WHERE session_id = $1
      AND created_at > NOW() - INTERVAL '2 hours'  -- Time bound
      AND compressed = FALSE                         -- Skip already-compressed
    ORDER BY created_at DESC
    LIMIT 10                                         -- Count bound
""", session_id)
# Then reverse for chronological order
history = list(reversed(history))
```

**Rule of thumb**: Most agents need the last 5-10 messages.
For longer context, compress old messages to a summary (see SKILL.md → Context Compression).

---

## 5. Monolithic Agent That Handles Everything

```python
# ❌ One agent prompt: 3000 tokens covering all domains.
# Result: inconsistent behavior, confusing responses, impossible to debug.
SYSTEM_PROMPT = """
You are an assistant. You help with sales, technical support, billing,
account management, product recommendations, legal questions, HR policies,
and general company information. When asked about pricing, check the catalog.
When asked about support, troubleshoot first. When asked about contracts...
[2000 more words]
"""

# ✅ Smaller, focused agents. Each does one thing excellently.
SALES_PROMPT = """
You are a sales specialist. You help with pricing, quotes, and purchase decisions.
Nothing else. If asked about anything else, acknowledge and redirect:
"That's not my area — use /support for technical help or /billing for account questions."
"""
# ~150 tokens. Predictable. Debuggable. Cheap.
```

---

## 6. Storing Sensitive Data in Memory Without Expiry

```python
# ❌ "Learning" credit card numbers, passwords, personal health data
# These accumulate in bot_memory forever.
await write_memory(user_id, 'credit_card', '4242-4242-4242-4242')

# ✅ Sensitive data: never store. Semi-sensitive: always set TTL.
# For anything a user might consider private:
await conn.execute("""
    INSERT INTO bot_memory (user_id, key, value, expires_at, source)
    VALUES ($1, $2, $3, NOW() + INTERVAL '24 hours', 'user')
    ON CONFLICT (user_id, key) DO UPDATE
      SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at
""", user_id, 'session_context', sanitized_value)
# Never store: passwords, payment data, government IDs, health information
```

---

## 7. Using `getUpdates` Polling in Production

```python
# ❌ Long-polling. Works locally. Breaks under load.
while True:
    updates = bot.get_updates(offset=last_update_id)
    for update in updates:
        process(update)

# ✅ Webhook. Period. Scales to thousands of concurrent users.
# One-time setup:
import httpx
httpx.post(
    f"https://api.telegram.org/bot{TOKEN}/setWebhook",
    json={
        "url": f"https://yourdomain.com/telegram/webhook",
        "secret_token": YOUR_SECRET_TOKEN,
        "allowed_updates": ["message", "callback_query"],
        "max_connections": 100
    }
)
# Verify:
# GET https://api.telegram.org/bot{TOKEN}/getWebhookInfo
```

---

## 8. No Fallback Agent

```python
# ❌ Router cannot classify → exception → user sees nothing or a 500 error
intent = await classify(message, agents)
if not intent:
    raise ValueError("No agent found")   # User gets no response

# ✅ Always have a fallback. It never fails.
DEFAULT_AGENT = GenericAgent(
    name='default',
    description='Handles anything not matched by specialized agents',
    system_prompt="""
    You are a helpful assistant. The user sent a message that didn't match
    a specific category. Your job is to:
    1. Acknowledge their question
    2. Clarify what specialized help is available (/sales, /support, /billing)
    3. Answer generally if you can

    Available commands:
    {commands_list}
    """
)

# In router:
agent_id = intent.agent_id if intent.agent_id in self.agents else 'default'
agent = self.agents[agent_id]
```
