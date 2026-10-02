\set ON_ERROR_STOP on

\ir ../schema/telegram_agent_router.sql
\ir ../schema/durable_coordination.sql

DROP ROLE IF EXISTS router_coord_app;
CREATE ROLE router_coord_app NOLOGIN NOBYPASSRLS;

GRANT USAGE ON SCHEMA telegram_agent TO router_coord_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA telegram_agent TO router_coord_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA telegram_agent TO router_coord_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA telegram_agent TO router_coord_app;

INSERT INTO telegram_agent.bot_agent_registry(bot_id,id,display_name,description)
VALUES
  ('bot-a','alpha','Alpha','sender fixture'),
  ('bot-a','beta','Beta','recipient fixture'),
  ('bot-b','other','Other','cross-bot fixture')
ON CONFLICT DO NOTHING;

SET ROLE router_coord_app;
SET app.bot_id = 'bot-a';

SELECT (telegram_agent.start_agent_execution(
  'bot-a','alpha',interval '5 minutes'
)).execution_id AS alpha_exec \gset

SELECT (telegram_agent.start_agent_execution(
  'bot-a','beta',interval '5 minutes'
)).execution_id AS beta_exec \gset

-- Payload-aware idempotency survives retries.
SELECT (telegram_agent.enqueue_agent_message(
  'bot-a',
  'alpha',
  'beta',
  :'alpha_exec'::uuid,
  'proactive',
  '11111111-1111-1111-1111-111111111111'::uuid,
  NULL,
  'msg-1',
  '{"kind":"work","value":1}'::jsonb,
  interval '1 day'
)).message_id AS msg1 \gset

SELECT (telegram_agent.enqueue_agent_message(
  'bot-a',
  'alpha',
  'beta',
  :'alpha_exec'::uuid,
  'proactive',
  '11111111-1111-1111-1111-111111111111'::uuid,
  NULL,
  'msg-1',
  '{"kind":"work","value":1}'::jsonb,
  interval '1 day'
)).message_id AS msg1_retry \gset

SELECT :'msg1'::uuid = :'msg1_retry'::uuid AS idempotent_message \gset
\if :idempotent_message
\else
  \echo 'same idempotent message did not return the original receipt'
  \quit 1
\endif

DO $$
BEGIN
  BEGIN
    PERFORM telegram_agent.enqueue_agent_message(
      'bot-a',
      'alpha',
      'beta',
      (
        SELECT execution_id
        FROM telegram_agent.agent_executions
        WHERE bot_id='bot-a' AND agent_id='alpha'
          AND status='active' AND lease_expires_at > now()
        ORDER BY started_at DESC
        LIMIT 1
      ),
      'proactive',
      '11111111-1111-1111-1111-111111111111'::uuid,
      NULL,
      'msg-1',
      '{"kind":"work","value":2}'::jsonb,
      interval '1 day'
    );
    RAISE EXCEPTION 'expected idempotency conflict was not raised';
  EXCEPTION WHEN SQLSTATE '22000' THEN
    NULL;
  END;
END;
$$;

-- Reserve, deliver, lose the ACK, then redeliver under a new execution.
SELECT (telegram_agent.reserve_agent_message(
  'bot-a','beta',:'beta_exec'::uuid,interval '30 seconds'
)).message_id = :'msg1'::uuid AS first_reservation \gset
\if :first_reservation
\else
  \echo 'message was not reserved by the current recipient execution'
  \quit 1
\endif

SELECT (telegram_agent.mark_agent_message_delivered(
  'bot-a',:'msg1'::uuid,:'beta_exec'::uuid,interval '30 seconds'
)).first_delivered_at AS first_delivery \gset

UPDATE telegram_agent.agent_messages
SET reservation_expires_at = now() - interval '1 second'
WHERE message_id = :'msg1'::uuid;

UPDATE telegram_agent.agent_executions
SET lease_expires_at = now() - interval '1 second'
WHERE execution_id = :'beta_exec'::uuid;

SELECT (telegram_agent.start_agent_execution(
  'bot-a','beta',interval '5 minutes'
)).execution_id AS beta_exec2 \gset

SELECT (telegram_agent.reserve_agent_message(
  'bot-a','beta',:'beta_exec2'::uuid,interval '30 seconds'
)).message_id = :'msg1'::uuid AS redelivered \gset
\if :redelivered
\else
  \echo 'unacknowledged delivered message was not redeliverable'
  \quit 1
\endif

SELECT (telegram_agent.mark_agent_message_delivered(
  'bot-a',:'msg1'::uuid,:'beta_exec2'::uuid,interval '30 seconds'
)).first_delivered_at = :'first_delivery'::timestamptz AS first_delivery_preserved \gset
\if :first_delivery_preserved
\else
  \echo 'redelivery rewrote first_delivered_at'
  \quit 1
\endif

SELECT (telegram_agent.ack_agent_message(
  'bot-a',:'msg1'::uuid,:'beta_exec2'::uuid
)).status = 'acknowledged' AS first_ack \gset

SELECT (telegram_agent.ack_agent_message(
  'bot-a',:'msg1'::uuid,:'beta_exec2'::uuid
)).status = 'acknowledged' AS second_ack \gset

\if :first_ack
\else
  \echo 'message was not acknowledged'
  \quit 1
\endif
\if :second_ack
\else
  \echo 'second ACK was not idempotent'
  \quit 1
\endif

-- A stale execution cannot complete or ACK a newly reserved handoff.
SELECT (telegram_agent.enqueue_agent_message(
  'bot-a',
  'alpha',
  'beta',
  :'alpha_exec'::uuid,
  'scheduled',
  '22222222-2222-2222-2222-222222222222'::uuid,
  NULL,
  'msg-2',
  '{"kind":"scheduled"}'::jsonb,
  interval '1 day'
)).message_id AS msg2 \gset

SELECT (telegram_agent.reserve_agent_message(
  'bot-a','beta',:'beta_exec2'::uuid,interval '30 seconds'
)).message_id = :'msg2'::uuid AS second_reserved \gset

UPDATE telegram_agent.agent_executions
SET lease_expires_at = now() - interval '1 second'
WHERE execution_id = :'beta_exec2'::uuid;

DO $$
BEGIN
  BEGIN
    PERFORM telegram_agent.mark_agent_message_delivered(
      'bot-a',
      (
        SELECT message_id
        FROM telegram_agent.agent_messages
        WHERE bot_id='bot-a' AND sender_agent='alpha' AND idempotency_key='msg-2'
      ),
      (
        SELECT execution_id
        FROM telegram_agent.agent_executions
        WHERE bot_id='bot-a' AND agent_id='beta'
          AND status='active'
        ORDER BY started_at DESC
        LIMIT 1
      ),
      interval '30 seconds'
    );
    RAISE EXCEPTION 'stale execution completed a handoff';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    NULL;
  END;
END;
$$;

UPDATE telegram_agent.agent_messages
SET reservation_expires_at = now() - interval '1 second'
WHERE message_id = :'msg2'::uuid;

SELECT (telegram_agent.start_agent_execution(
  'bot-a','beta',interval '5 minutes'
)).execution_id AS beta_exec3 \gset

SELECT (telegram_agent.reserve_agent_message(
  'bot-a','beta',:'beta_exec3'::uuid,interval '30 seconds'
)).message_id = :'msg2'::uuid AS stale_claim_recovered \gset
\if :stale_claim_recovered
\else
  \echo 'message reserved by stale execution was not recoverable'
  \quit 1
\endif

SELECT (telegram_agent.mark_agent_message_delivered(
  'bot-a',:'msg2'::uuid,:'beta_exec3'::uuid,interval '30 seconds'
)).message_id AS msg2_delivered \gset

SELECT (telegram_agent.ack_agent_message(
  'bot-a',:'msg2'::uuid,:'beta_exec3'::uuid
)).status = 'acknowledged' AS msg2_acked \gset
\if :msg2_acked
\else
  \echo 'recovered message was not acknowledged'
  \quit 1
\endif

-- Reply correlation is explicit and reuses the request_id.
SELECT (telegram_agent.enqueue_agent_message(
  'bot-a',
  'beta',
  'alpha',
  :'beta_exec3'::uuid,
  'reply_linked',
  '22222222-2222-2222-2222-222222222222'::uuid,
  :'msg2'::uuid,
  'reply-msg-2',
  '{"kind":"reply","ok":true}'::jsonb,
  interval '1 day'
)).message_id AS reply_id \gset

SELECT response_to = :'msg2'::uuid
   AND request_id = '22222222-2222-2222-2222-222222222222'::uuid AS reply_correlated
FROM telegram_agent.agent_messages
WHERE message_id = :'reply_id'::uuid \gset
\if :reply_correlated
\else
  \echo 'reply was not correlated to the original request'
  \quit 1
\endif

-- Processing leases make abandoned Telegram jobs recoverable.
INSERT INTO telegram_agent.jobs(
  bot_id,update_id,chat_id,user_id,update_json,max_attempts,expires_at
) VALUES (
  'bot-a',7001,1001,1001,'{"update_id":7001}'::jsonb,3,now()+interval '1 day'
);

SELECT (telegram_agent.claim_job(
  'bot-a','worker-1',interval '5 minutes'
)).id AS leased_job \gset

UPDATE telegram_agent.jobs
SET lease_expires_at = now() - interval '1 second'
WHERE id = :leased_job;

SELECT count(*) = 1 AS reaped_retry
FROM telegram_agent.reap_expired_jobs('bot-a')
WHERE job_id = :leased_job AND new_status = 'retrying' \gset
\if :reaped_retry
\else
  \echo 'expired processing job was not reaped to retrying'
  \quit 1
\endif

SELECT (telegram_agent.claim_job(
  'bot-a','worker-2',interval '5 minutes'
)).id = :leased_job AS reclaimed_same_job \gset
SELECT claimed_by = 'worker-2' AND attempts = 2 AS new_owner
FROM telegram_agent.jobs WHERE id = :leased_job \gset
\if :reclaimed_same_job
\else
  \echo 'reaped job was not reclaimable'
  \quit 1
\endif
\if :new_owner
\else
  \echo 'reclaimed job did not move to the new worker lease'
  \quit 1
\endif

-- Exhausted jobs fail closed instead of looping forever.
INSERT INTO telegram_agent.jobs(
  bot_id,update_id,chat_id,user_id,update_json,max_attempts,expires_at
) VALUES (
  'bot-a',7002,1001,1001,'{"update_id":7002}'::jsonb,1,now()+interval '1 day'
);

SELECT (telegram_agent.claim_job(
  'bot-a','worker-final',interval '5 minutes'
)).id AS final_job \gset
UPDATE telegram_agent.jobs
SET lease_expires_at = now() - interval '1 second'
WHERE id = :final_job;

SELECT count(*) = 1 AS reaped_failed
FROM telegram_agent.reap_expired_jobs('bot-a')
WHERE job_id = :final_job AND new_status = 'failed' \gset
\if :reaped_failed
\else
  \echo 'exhausted processing job did not fail closed'
  \quit 1
\endif

-- New coordination tables inherit fail-closed tenant scoping.
RESET app.bot_id;
SELECT count(*) = 0 AS no_messages_without_context
FROM telegram_agent.agent_messages \gset
\if :no_messages_without_context
\else
  \echo 'agent_messages did not fail closed without bot context'
  \quit 1
\endif

RESET ROLE;
DROP SCHEMA telegram_agent CASCADE;
DROP ROLE router_coord_app;

SELECT 'durable coordination runtime: OK' AS result;
