# PostgreSQL Schema — Telegram Agent Router

Complete DDL for a production multi-agent Telegram bot.
All tables use `BIGSERIAL` or `UUID` primary keys, `TIMESTAMPTZ` timestamps, and include appropriate indexes.

---

## CORE TABLES

```sql
-- ─────────────────────────────────────────────
-- AGENT REGISTRY
-- Source of truth for what agents exist.
-- Populated at startup, updated on config change.
-- ─────────────────────────────────────────────
CREATE TABLE bot_agent_registry (
  id            TEXT PRIMARY KEY,              -- 'sales', 'finance', 'support'
  display_name  TEXT NOT NULL,
  description   TEXT NOT NULL,                 -- Used by LLM orchestrator for routing
  commands      TEXT[] NOT NULL DEFAULT '{}',  -- ['/sales', '/quote']
  intent_hints  TEXT[] NOT NULL DEFAULT '{}',  -- keywords for fast-path routing
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  priority      INT NOT NULL DEFAULT 0,        -- Higher = checked first
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
-- SESSIONS
-- One row per user conversation window.
-- New session created after idle_timeout of inactivity.
-- ─────────────────────────────────────────────
CREATE TABLE bot_sessions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         BIGINT NOT NULL,             -- Telegram user ID
  chat_id         BIGINT NOT NULL,             -- Telegram chat ID
  locked_agent    TEXT REFERENCES bot_agent_registry(id),  -- NULL = free routing
  locked_flow     TEXT,                        -- Multi-step flow identifier
  flow_state      JSONB NOT NULL DEFAULT '{}', -- Flow-specific state
  message_count   INT NOT NULL DEFAULT 0,
  is_compressed   BOOLEAN NOT NULL DEFAULT FALSE,
  idle_timeout    INTERVAL NOT NULL DEFAULT '30 minutes',
  started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_active_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at        TIMESTAMPTZ,
  metadata        JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX idx_sessions_user    ON bot_sessions (user_id, last_active_at DESC);
CREATE INDEX idx_sessions_chat    ON bot_sessions (chat_id, last_active_at DESC);
CREATE INDEX idx_sessions_active  ON bot_sessions (last_active_at)
  WHERE ended_at IS NULL;

-- ─────────────────────────────────────────────
-- MESSAGES
-- Complete conversation history.
-- role: 'user' | 'assistant' | 'system'
-- ─────────────────────────────────────────────
CREATE TABLE bot_messages (
  id              BIGSERIAL PRIMARY KEY,
  session_id      UUID NOT NULL REFERENCES bot_sessions(id) ON DELETE CASCADE,
  user_id         BIGINT NOT NULL,
  chat_id         BIGINT NOT NULL,
  telegram_msg_id BIGINT,                      -- Telegram message ID (for dedup)
  role            TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content         TEXT NOT NULL,
  agent_name      TEXT,                        -- Which agent produced this (if assistant)
  intent_classified TEXT,                      -- What intent was detected
  intent_confidence FLOAT,                     -- 0.0-1.0
  tokens_used     INT,
  compressed      BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_messages_session    ON bot_messages (session_id, created_at DESC);
CREATE INDEX idx_messages_user       ON bot_messages (user_id, created_at DESC);
CREATE INDEX idx_messages_telegram   ON bot_messages (telegram_msg_id)
  WHERE telegram_msg_id IS NOT NULL;

-- ─────────────────────────────────────────────
-- LONG-TERM MEMORY
-- Persistent facts about users, cross-session.
-- key-value with confidence and TTL.
-- ─────────────────────────────────────────────
CREATE TABLE bot_memory (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT NOT NULL,
  key         TEXT NOT NULL,                   -- 'preferred_language', 'company_name'
  value       TEXT NOT NULL,
  confidence  FLOAT NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
  source      TEXT,                            -- 'explicit' | 'inferred' | 'system'
  agent_name  TEXT,                            -- Which agent wrote this
  expires_at  TIMESTAMPTZ,                     -- NULL = never expires
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  accessed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, key)
);

CREATE INDEX idx_memory_user      ON bot_memory (user_id, accessed_at DESC)
  WHERE expires_at IS NULL OR expires_at > NOW();
CREATE INDEX idx_memory_expires   ON bot_memory (expires_at)
  WHERE expires_at IS NOT NULL;

-- ─────────────────────────────────────────────
-- JOB QUEUE
-- Decouples webhook receipt from LLM processing.
-- Uses FOR UPDATE SKIP LOCKED — no Redis needed.
-- ─────────────────────────────────────────────
CREATE TABLE bot_job_queue (
  id           BIGSERIAL PRIMARY KEY,
  chat_id      BIGINT NOT NULL,
  user_id      BIGINT NOT NULL,
  update_json  JSONB NOT NULL,               -- Raw Telegram Update object
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','processing','done','failed','skipped')),
  attempts     SMALLINT NOT NULL DEFAULT 0,
  max_attempts SMALLINT NOT NULL DEFAULT 3,
  error        TEXT,
  run_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at   TIMESTAMPTZ,
  finished_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_jobs_dequeue ON bot_job_queue (status, run_at)
  WHERE status IN ('pending');
CREATE INDEX idx_jobs_chat    ON bot_job_queue (chat_id, created_at DESC);

-- ─────────────────────────────────────────────
-- DISPATCH LOG
-- Audit trail: every routing decision, forever.
-- Essential for debugging and improving routing.
-- ─────────────────────────────────────────────
CREATE TABLE bot_dispatch_log (
  id              BIGSERIAL PRIMARY KEY,
  session_id      UUID NOT NULL,
  user_id         BIGINT NOT NULL,
  message_id      BIGINT REFERENCES bot_messages(id),
  input_text      TEXT NOT NULL,
  detected_intent TEXT,
  confidence      FLOAT,
  route_reason    TEXT NOT NULL,             -- 'command'|'session_lock'|'intent'|'fallback'
  target_agent    TEXT NOT NULL,
  latency_ms      INT,
  success         BOOLEAN NOT NULL DEFAULT TRUE,
  error           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_dispatch_session ON bot_dispatch_log (session_id, created_at DESC);
CREATE INDEX idx_dispatch_agent   ON bot_dispatch_log (target_agent, created_at DESC);
CREATE INDEX idx_dispatch_intent  ON bot_dispatch_log (detected_intent)
  WHERE detected_intent IS NOT NULL;
```

---

## OPERATIONAL QUERIES

### Get or create active session

```sql
-- Returns the current active session for a user, or NULL if expired
WITH active AS (
  SELECT id, locked_agent, locked_flow, flow_state, message_count
  FROM bot_sessions
  WHERE user_id = $1
    AND chat_id = $2
    AND ended_at IS NULL
    AND last_active_at > NOW() - idle_timeout
  ORDER BY last_active_at DESC
  LIMIT 1
  FOR UPDATE SKIP LOCKED   -- Prevents concurrent message processing issues
)
UPDATE bot_sessions
SET last_active_at = NOW(), message_count = message_count + 1
FROM active
WHERE bot_sessions.id = active.id
RETURNING bot_sessions.*;
```

### Dequeue next job (race-condition safe)

```sql
WITH claimed AS (
  SELECT id FROM bot_job_queue
  WHERE status = 'pending'
    AND run_at <= NOW()
  ORDER BY created_at
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
UPDATE bot_job_queue
SET status = 'processing',
    started_at = NOW(),
    attempts = attempts + 1
FROM claimed
WHERE bot_job_queue.id = claimed.id
RETURNING *;
```

### Write long-term memory

```sql
INSERT INTO bot_memory (user_id, key, value, confidence, source, agent_name)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (user_id, key) DO UPDATE
  SET value = EXCLUDED.value,
      confidence = GREATEST(bot_memory.confidence, EXCLUDED.confidence),
      updated_at = NOW(),
      accessed_at = NOW()
  WHERE EXCLUDED.confidence >= bot_memory.confidence;  -- Only upgrade, never downgrade
```

### Load context for agent

```sql
-- Everything an agent needs in one query
SELECT
  s.id              AS session_id,
  s.locked_agent,
  s.locked_flow,
  s.flow_state,
  json_agg(
    json_build_object('role', m.role, 'content', m.content, 'agent', m.agent_name)
    ORDER BY m.created_at
  ) FILTER (WHERE m.id IS NOT NULL)  AS history,
  (
    SELECT json_agg(json_build_object('key', key, 'value', value, 'confidence', confidence))
    FROM bot_memory
    WHERE user_id = $1
      AND (expires_at IS NULL OR expires_at > NOW())
    ORDER BY accessed_at DESC
    LIMIT 20
  ) AS memories
FROM bot_sessions s
LEFT JOIN bot_messages m ON m.session_id = s.id
  AND m.compressed = FALSE
  AND m.created_at > NOW() - INTERVAL '2 hours'
WHERE s.id = $2
GROUP BY s.id, s.locked_agent, s.locked_flow, s.flow_state;
```

### Routing analytics (improve your router over time)

```sql
-- What agents are used, and for what intents?
SELECT
  target_agent,
  detected_intent,
  COUNT(*)                                    AS dispatches,
  AVG(latency_ms)                             AS avg_latency_ms,
  SUM(CASE WHEN NOT success THEN 1 ELSE 0 END) AS failures,
  ROUND(AVG(confidence)::numeric, 2)          AS avg_confidence
FROM bot_dispatch_log
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY target_agent, detected_intent
ORDER BY dispatches DESC;

-- Session health: how many sessions end in failure?
SELECT
  date_trunc('day', started_at) AS day,
  COUNT(*)                       AS total_sessions,
  AVG(message_count)             AS avg_messages_per_session,
  SUM(CASE WHEN message_count = 1 THEN 1 ELSE 0 END) AS single_message_sessions
FROM bot_sessions
WHERE started_at > NOW() - INTERVAL '30 days'
GROUP BY 1 ORDER BY 1;
```

---

## MAINTENANCE (run via pg_cron)

```sql
-- Close idle sessions (hourly)
UPDATE bot_sessions
SET ended_at = NOW()
WHERE ended_at IS NULL
  AND last_active_at < NOW() - idle_timeout;

-- Expire short-term memory (daily)
DELETE FROM bot_memory
WHERE expires_at IS NOT NULL AND expires_at < NOW();

-- Archive old dispatch logs (weekly, keep 90 days)
DELETE FROM bot_dispatch_log
WHERE created_at < NOW() - INTERVAL '90 days';

-- Clean completed jobs (daily, keep 7 days)
DELETE FROM bot_job_queue
WHERE status IN ('done', 'skipped')
  AND finished_at < NOW() - INTERVAL '7 days';
```
