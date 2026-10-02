BEGIN;

ALTER TABLE telegram_agent.jobs
  ADD COLUMN IF NOT EXISTS claimed_by text,
  ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_heartbeat_at timestamptz;

CREATE INDEX IF NOT EXISTS jobs_reaper_idx
  ON telegram_agent.jobs (bot_id, lease_expires_at, id)
  WHERE status = 'processing';

CREATE TABLE IF NOT EXISTS telegram_agent.agent_executions (
  execution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bot_id text NOT NULL,
  agent_id text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','ended')),
  lease_expires_at timestamptz NOT NULL,
  last_heartbeat_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (bot_id, agent_id)
    REFERENCES telegram_agent.bot_agent_registry (bot_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS agent_executions_one_active_idx
  ON telegram_agent.agent_executions (bot_id, agent_id)
  WHERE status = 'active';
CREATE INDEX IF NOT EXISTS agent_executions_lease_idx
  ON telegram_agent.agent_executions (bot_id, lease_expires_at)
  WHERE status = 'active';

CREATE TABLE IF NOT EXISTS telegram_agent.agent_messages (
  message_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bot_id text NOT NULL,
  sender_agent text NOT NULL,
  recipient_agent text NOT NULL,
  sender_execution_id uuid NOT NULL
    REFERENCES telegram_agent.agent_executions(execution_id),
  provenance text NOT NULL
    CHECK (provenance IN ('proactive','scheduled','reply_linked')),
  request_id uuid NOT NULL,
  response_to uuid
    REFERENCES telegram_agent.agent_messages(message_id),
  idempotency_key text NOT NULL,
  payload_digest text NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','reserved','delivered','acknowledged','expired')),
  reserved_by_execution_id uuid
    REFERENCES telegram_agent.agent_executions(execution_id),
  reservation_expires_at timestamptz,
  first_delivered_at timestamptz,
  acknowledged_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  FOREIGN KEY (bot_id, sender_agent)
    REFERENCES telegram_agent.bot_agent_registry (bot_id, id),
  FOREIGN KEY (bot_id, recipient_agent)
    REFERENCES telegram_agent.bot_agent_registry (bot_id, id),
  UNIQUE (bot_id, sender_agent, idempotency_key),
  CHECK (
    (provenance = 'reply_linked' AND response_to IS NOT NULL)
    OR
    (provenance <> 'reply_linked' AND response_to IS NULL)
  )
);
CREATE INDEX IF NOT EXISTS agent_messages_inbox_idx
  ON telegram_agent.agent_messages (bot_id, recipient_agent, created_at, message_id)
  WHERE status IN ('queued','reserved','delivered');
CREATE INDEX IF NOT EXISTS agent_messages_expiry_idx
  ON telegram_agent.agent_messages (expires_at)
  WHERE expires_at IS NOT NULL;

ALTER TABLE telegram_agent.agent_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE telegram_agent.agent_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bot_scope_agent_executions ON telegram_agent.agent_executions;
CREATE POLICY bot_scope_agent_executions ON telegram_agent.agent_executions
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));

DROP POLICY IF EXISTS bot_scope_agent_messages ON telegram_agent.agent_messages;
CREATE POLICY bot_scope_agent_messages ON telegram_agent.agent_messages
  USING (bot_id = NULLIF(current_setting('app.bot_id', true), ''))
  WITH CHECK (bot_id = NULLIF(current_setting('app.bot_id', true), ''));

CREATE OR REPLACE FUNCTION telegram_agent.execution_is_current(
  p_bot_id text,
  p_execution_id uuid,
  p_agent_id text
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = telegram_agent, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM telegram_agent.agent_executions
    WHERE bot_id = p_bot_id
      AND execution_id = p_execution_id
      AND agent_id = p_agent_id
      AND status = 'active'
      AND lease_expires_at > now()
  );
$$;

CREATE OR REPLACE FUNCTION telegram_agent.start_agent_execution(
  p_bot_id text,
  p_agent_id text,
  p_lease interval
) RETURNS telegram_agent.agent_executions
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_execution telegram_agent.agent_executions%ROWTYPE;
BEGIN
  IF p_lease <= interval '0 seconds' THEN
    RAISE EXCEPTION 'execution lease must be positive'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('agent-execution:' || p_bot_id || ':' || p_agent_id, 0)
  );

  UPDATE telegram_agent.agent_executions
  SET status = 'ended',
      ended_at = now()
  WHERE bot_id = p_bot_id
    AND agent_id = p_agent_id
    AND status = 'active'
    AND lease_expires_at <= now();

  IF EXISTS (
    SELECT 1
    FROM telegram_agent.agent_executions
    WHERE bot_id = p_bot_id
      AND agent_id = p_agent_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'agent % already has a current execution', p_agent_id
      USING ERRCODE = '55006';
  END IF;

  INSERT INTO telegram_agent.agent_executions(
    bot_id, agent_id, lease_expires_at
  ) VALUES (
    p_bot_id, p_agent_id, now() + p_lease
  )
  RETURNING * INTO v_execution;

  RETURN v_execution;
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.heartbeat_agent_execution(
  p_bot_id text,
  p_execution_id uuid,
  p_lease interval
) RETURNS boolean
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_ok boolean;
BEGIN
  IF p_lease <= interval '0 seconds' THEN
    RAISE EXCEPTION 'execution lease must be positive'
      USING ERRCODE = '22023';
  END IF;

  UPDATE telegram_agent.agent_executions
  SET last_heartbeat_at = now(),
      lease_expires_at = now() + p_lease
  WHERE bot_id = p_bot_id
    AND execution_id = p_execution_id
    AND status = 'active'
    AND lease_expires_at > now()
  RETURNING true INTO v_ok;

  RETURN coalesce(v_ok, false);
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.claim_job(
  p_bot_id text,
  p_worker_id text,
  p_lease interval
) RETURNS telegram_agent.jobs
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_job telegram_agent.jobs%ROWTYPE;
BEGIN
  IF p_lease <= interval '0 seconds' THEN
    RAISE EXCEPTION 'job lease must be positive'
      USING ERRCODE = '22023';
  END IF;

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
      attempts = attempts + 1,
      claimed_by = p_worker_id,
      lease_expires_at = now() + p_lease,
      last_heartbeat_at = now()
  FROM candidate
  WHERE j.id = candidate.id
  RETURNING j.* INTO v_job;

  RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.claim_job(p_bot_id text)
RETURNS telegram_agent.jobs
LANGUAGE sql
SET search_path = telegram_agent, pg_temp
AS $$
  SELECT telegram_agent.claim_job(
    p_bot_id,
    'legacy-worker',
    interval '5 minutes'
  );
$$;

CREATE OR REPLACE FUNCTION telegram_agent.heartbeat_job(
  p_bot_id text,
  p_job_id bigint,
  p_worker_id text,
  p_lease interval
) RETURNS boolean
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_ok boolean;
BEGIN
  IF p_lease <= interval '0 seconds' THEN
    RAISE EXCEPTION 'job lease must be positive'
      USING ERRCODE = '22023';
  END IF;

  UPDATE telegram_agent.jobs
  SET last_heartbeat_at = now(),
      lease_expires_at = now() + p_lease
  WHERE bot_id = p_bot_id
    AND id = p_job_id
    AND status = 'processing'
    AND claimed_by = p_worker_id
    AND lease_expires_at > now()
  RETURNING true INTO v_ok;

  RETURN coalesce(v_ok, false);
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.reap_expired_jobs(p_bot_id text)
RETURNS TABLE(job_id bigint, new_status text)
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
BEGIN
  RETURN QUERY
  UPDATE telegram_agent.jobs AS j
  SET status = CASE
        WHEN j.attempts >= j.max_attempts THEN 'failed'
        ELSE 'retrying'
      END,
      run_at = CASE
        WHEN j.attempts >= j.max_attempts THEN j.run_at
        ELSE now()
      END,
      finished_at = CASE
        WHEN j.attempts >= j.max_attempts THEN now()
        ELSE NULL
      END,
      error = coalesce(j.error, 'processing lease expired'),
      claimed_by = NULL,
      lease_expires_at = NULL,
      last_heartbeat_at = NULL
  WHERE j.bot_id = p_bot_id
    AND j.status = 'processing'
    AND j.lease_expires_at IS NOT NULL
    AND j.lease_expires_at <= now()
  RETURNING j.id, j.status;
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.enqueue_agent_message(
  p_bot_id text,
  p_sender_agent text,
  p_recipient_agent text,
  p_sender_execution_id uuid,
  p_provenance text,
  p_request_id uuid,
  p_response_to uuid,
  p_idempotency_key text,
  p_payload jsonb,
  p_ttl interval
) RETURNS telegram_agent.agent_messages
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_message telegram_agent.agent_messages%ROWTYPE;
  v_digest text := md5(p_payload::text);
BEGIN
  IF NOT telegram_agent.execution_is_current(
    p_bot_id, p_sender_execution_id, p_sender_agent
  ) THEN
    RAISE EXCEPTION 'sender execution is not current'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_message
  FROM telegram_agent.agent_messages
  WHERE bot_id = p_bot_id
    AND sender_agent = p_sender_agent
    AND idempotency_key = p_idempotency_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_message.recipient_agent <> p_recipient_agent
       OR v_message.provenance <> p_provenance
       OR v_message.request_id <> p_request_id
       OR v_message.response_to IS DISTINCT FROM p_response_to
       OR v_message.payload_digest <> v_digest THEN
      RAISE EXCEPTION 'idempotency key reused with different message intent'
        USING ERRCODE = '22000';
    END IF;
    RETURN v_message;
  END IF;

  INSERT INTO telegram_agent.agent_messages(
    bot_id,
    sender_agent,
    recipient_agent,
    sender_execution_id,
    provenance,
    request_id,
    response_to,
    idempotency_key,
    payload_digest,
    payload,
    expires_at
  ) VALUES (
    p_bot_id,
    p_sender_agent,
    p_recipient_agent,
    p_sender_execution_id,
    p_provenance,
    p_request_id,
    p_response_to,
    p_idempotency_key,
    v_digest,
    p_payload,
    CASE WHEN p_ttl IS NULL THEN NULL ELSE now() + p_ttl END
  )
  RETURNING * INTO v_message;

  RETURN v_message;
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.reserve_agent_message(
  p_bot_id text,
  p_recipient_agent text,
  p_execution_id uuid,
  p_reservation interval
) RETURNS telegram_agent.agent_messages
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_message telegram_agent.agent_messages%ROWTYPE;
BEGIN
  IF p_reservation <= interval '0 seconds' THEN
    RAISE EXCEPTION 'reservation must be positive'
      USING ERRCODE = '22023';
  END IF;

  IF NOT telegram_agent.execution_is_current(
    p_bot_id, p_execution_id, p_recipient_agent
  ) THEN
    RAISE EXCEPTION 'recipient execution is not current'
      USING ERRCODE = '55000';
  END IF;

  WITH candidate AS (
    SELECT message_id
    FROM telegram_agent.agent_messages
    WHERE bot_id = p_bot_id
      AND recipient_agent = p_recipient_agent
      AND (expires_at IS NULL OR expires_at > now())
      AND (
        status = 'queued'
        OR (
          status IN ('reserved','delivered')
          AND reservation_expires_at IS NOT NULL
          AND reservation_expires_at <= now()
        )
      )
    ORDER BY created_at, message_id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  UPDATE telegram_agent.agent_messages AS m
  SET status = 'reserved',
      reserved_by_execution_id = p_execution_id,
      reservation_expires_at = now() + p_reservation
  FROM candidate
  WHERE m.message_id = candidate.message_id
  RETURNING m.* INTO v_message;

  RETURN v_message;
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.mark_agent_message_delivered(
  p_bot_id text,
  p_message_id uuid,
  p_execution_id uuid,
  p_ack_window interval
) RETURNS telegram_agent.agent_messages
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_message telegram_agent.agent_messages%ROWTYPE;
BEGIN
  SELECT * INTO v_message
  FROM telegram_agent.agent_messages
  WHERE bot_id = p_bot_id
    AND message_id = p_message_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'message % not found', p_message_id;
  END IF;

  IF v_message.status = 'delivered'
     AND v_message.reserved_by_execution_id = p_execution_id THEN
    RETURN v_message;
  END IF;

  IF NOT telegram_agent.execution_is_current(
    p_bot_id, p_execution_id, v_message.recipient_agent
  ) THEN
    RAISE EXCEPTION 'recipient execution is not current'
      USING ERRCODE = '55000';
  END IF;

  IF v_message.status <> 'reserved'
     OR v_message.reserved_by_execution_id <> p_execution_id
     OR v_message.reservation_expires_at <= now() THEN
    RAISE EXCEPTION 'message is not reserved by this execution'
      USING ERRCODE = '55000';
  END IF;

  UPDATE telegram_agent.agent_messages
  SET status = 'delivered',
      first_delivered_at = coalesce(first_delivered_at, now()),
      reservation_expires_at = now() + p_ack_window
  WHERE message_id = p_message_id
  RETURNING * INTO v_message;

  RETURN v_message;
END;
$$;

CREATE OR REPLACE FUNCTION telegram_agent.ack_agent_message(
  p_bot_id text,
  p_message_id uuid,
  p_execution_id uuid
) RETURNS telegram_agent.agent_messages
LANGUAGE plpgsql
SET search_path = telegram_agent, pg_temp
AS $$
DECLARE
  v_message telegram_agent.agent_messages%ROWTYPE;
BEGIN
  SELECT * INTO v_message
  FROM telegram_agent.agent_messages
  WHERE bot_id = p_bot_id
    AND message_id = p_message_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'message % not found', p_message_id;
  END IF;

  IF v_message.status = 'acknowledged' THEN
    RETURN v_message;
  END IF;

  IF NOT telegram_agent.execution_is_current(
    p_bot_id, p_execution_id, v_message.recipient_agent
  ) THEN
    RAISE EXCEPTION 'recipient execution is not current'
      USING ERRCODE = '55000';
  END IF;

  IF v_message.status <> 'delivered'
     OR v_message.reserved_by_execution_id <> p_execution_id
     OR v_message.reservation_expires_at IS NULL
     OR v_message.reservation_expires_at <= now() THEN
    RAISE EXCEPTION 'message cannot be acknowledged by this execution'
      USING ERRCODE = '55000';
  END IF;

  UPDATE telegram_agent.agent_messages
  SET status = 'acknowledged',
      acknowledged_at = now(),
      reservation_expires_at = NULL
  WHERE message_id = p_message_id
  RETURNING * INTO v_message;

  RETURN v_message;
END;
$$;

COMMIT;
