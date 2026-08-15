BEGIN;

CREATE SCHEMA IF NOT EXISTS telegram_agent;

CREATE TABLE IF NOT EXISTS telegram_agent.bot_agent_registry (
  bot_id text NOT NULL,
  id text NOT NULL,
  display_name text NOT NULL,
  description text NOT NULL,
  commands text[] NOT NULL DEFAULT '{}',
  intent_hints text[] NOT NULL DEFAULT '{}',
  is_active boolean NOT NULL DEFAULT true,
  priority integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bot_id, id)
);

CREATE TABLE IF NOT EXISTS telegram_agent.sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bot_id text NOT NULL,
  user_id bigint NOT NULL,
  chat_id bigint NOT NULL,
  locked_agent text,
  locked_flow text,
  flow_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  message_count integer NOT NULL DEFAULT 1 CHECK (message_count >= 1),
  idle_timeout interval NOT NULL DEFAULT interval '30 minutes',
  started_at timestamptz NOT NULL DEFAULT now(),
  last_active_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (bot_id, locked_agent)
    REFERENCES telegram_agent.bot_agent_registry (bot_id, id)
);
CREATE INDEX IF NOT EXISTS sessions_lookup_idx
  ON telegram_agent.sessions (bot_id, user_id, chat_id, last_active_at DESC)
  WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS telegram_agent.messages (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bot_id text NOT NULL,
  session_id uuid NOT NULL REFERENCES telegram_agent.sessions(id) ON DELETE CASCADE,
  user_id bigint NOT NULL,
  chat_id bigint NOT NULL,
  telegram_msg_id bigint,
  role text NOT NULL CHECK (role IN ('user','assistant','system')),
  content text NOT NULL,
  agent_name text,
  intent_classified text,
  intent_confidence double precision CHECK (intent_confidence IS NULL OR intent_confidence BETWEEN 0 AND 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS messages_telegram_dedupe_idx
  ON telegram_agent.messages (bot_id, chat_id, telegram_msg_id)
  WHERE telegram_msg_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS messages_session_idx
  ON telegram_agent.messages (bot_id, session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS messages_expiry_idx
  ON telegram_agent.messages (expires_at)
  WHERE expires_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS telegram_agent.memory (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bot_id text NOT NULL,
  user_id bigint NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  confidence double precision NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
  source text NOT NULL CHECK (source IN ('explicit','inferred','system')),
  agent_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  accessed_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  UNIQUE (bot_id, user_id, key)
);
CREATE INDEX IF NOT EXISTS memory_lookup_idx
  ON telegram_agent.memory (bot_id, user_id, accessed_at DESC);
CREATE INDEX IF NOT EXISTS memory_expiry_idx
  ON telegram_agent.memory (expires_at)
  WHERE expires_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS telegram_agent.jobs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bot_id text NOT NULL,
  update_id bigint NOT NULL,
  chat_id bigint NOT NULL,
  user_id bigint NOT NULL,
  update_json jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','processing','retrying','done','failed','skipped')),
  attempts smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts smallint NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
  error text,
  run_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  UNIQUE (bot_id, update_id)
);
CREATE INDEX IF NOT EXISTS jobs_claim_idx
  ON telegram_agent.jobs (bot_id, run_at, id)
  WHERE status IN ('pending','retrying');

CREATE TABLE IF NOT EXISTS telegram_agent.dispatch_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bot_id text NOT NULL,
  session_id uuid REFERENCES telegram_agent.sessions(id) ON DELETE SET NULL,
  user_id bigint NOT NULL,
  message_id bigint REFERENCES telegram_agent.messages(id) ON DELETE SET NULL,
  detected_intent text,
  confidence double precision CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  route_reason text NOT NULL CHECK (route_reason IN ('command','callback','session_lock','deterministic_intent','classifier','fallback')),
  target_agent text NOT NULL,
  latency_ms integer CHECK (latency_ms IS NULL OR latency_ms >= 0),
  success boolean NOT NULL DEFAULT true,
  error_class text,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz
);
CREATE INDEX IF NOT EXISTS dispatch_analysis_idx
  ON telegram_agent.dispatch_log (bot_id, target_agent, created_at DESC);
CREATE INDEX IF NOT EXISTS dispatch_expiry_idx
  ON telegram_agent.dispatch_log (expires_at)
  WHERE expires_at IS NOT NULL;

ALTER TABLE telegram_agent.bot_agent_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE telegram_agent.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE telegram_agent.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE telegram_agent.memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE telegram_agent.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE telegram_agent.dispatch_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bot_scope_registry ON telegram_agent.bot_agent_registry;
CREATE POLICY bot_scope_registry ON telegram_agent.bot_agent_registry
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));
DROP POLICY IF EXISTS bot_scope_sessions ON telegram_agent.sessions;
CREATE POLICY bot_scope_sessions ON telegram_agent.sessions
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));
DROP POLICY IF EXISTS bot_scope_messages ON telegram_agent.messages;
CREATE POLICY bot_scope_messages ON telegram_agent.messages
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));
DROP POLICY IF EXISTS bot_scope_memory ON telegram_agent.memory;
CREATE POLICY bot_scope_memory ON telegram_agent.memory
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));
DROP POLICY IF EXISTS bot_scope_jobs ON telegram_agent.jobs;
CREATE POLICY bot_scope_jobs ON telegram_agent.jobs
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));
DROP POLICY IF EXISTS bot_scope_dispatch ON telegram_agent.dispatch_log;
CREATE POLICY bot_scope_dispatch ON telegram_agent.dispatch_log
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));

CREATE OR REPLACE FUNCTION telegram_agent.get_or_create_session(
  p_bot_id text,
  p_user_id bigint,
  p_chat_id bigint,
  p_idle_timeout interval DEFAULT interval '30 minutes'
) RETURNS telegram_agent.sessions
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_session telegram_agent.sessions%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_bot_id || ':' || p_user_id::text || ':' || p_chat_id::text, 0)
  );

  SELECT * INTO v_session
  FROM telegram_agent.sessions
  WHERE bot_id = p_bot_id
    AND user_id = p_user_id
    AND chat_id = p_chat_id
    AND ended_at IS NULL
    AND last_active_at > now() - idle_timeout
  ORDER BY last_active_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    UPDATE telegram_agent.sessions
    SET last_active_at = now(),
        message_count = message_count + 1
    WHERE id = v_session.id
    RETURNING * INTO v_session;
  ELSE
    INSERT INTO telegram_agent.sessions (
      bot_id, user_id, chat_id, idle_timeout, message_count
    ) VALUES (
      p_bot_id, p_user_id, p_chat_id, p_idle_timeout, 1
    )
    RETURNING * INTO v_session;
  END IF;

  RETURN v_session;
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.claim_job(p_bot_id text)
RETURNS telegram_agent.jobs
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_job telegram_agent.jobs%ROWTYPE;
BEGIN
  WITH candidate AS (
    SELECT id
    FROM telegram_agent.jobs
    WHERE bot_id = p_bot_id
      AND status IN ('pending','retrying')
      AND run_at <= now()
    ORDER BY run_at, id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  UPDATE telegram_agent.jobs AS j
  SET status = 'processing',
      started_at = now(),
      attempts = attempts + 1
  FROM candidate
  WHERE j.id = candidate.id
  RETURNING j.* INTO v_job;

  RETURN v_job;
END;
$$;

COMMIT;
