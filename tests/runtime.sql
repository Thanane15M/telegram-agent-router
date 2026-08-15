\set ON_ERROR_STOP on

DROP ROLE IF EXISTS router_test_app;
CREATE ROLE router_test_app NOLOGIN NOBYPASSRLS;
GRANT USAGE ON SCHEMA telegram_agent TO router_test_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA telegram_agent TO router_test_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA telegram_agent TO router_test_app;
GRANT EXECUTE ON FUNCTION telegram_agent.get_or_create_session(text,bigint,bigint,interval) TO router_test_app;
GRANT EXECUTE ON FUNCTION telegram_agent.claim_job(text) TO router_test_app;

INSERT INTO telegram_agent.bot_agent_registry (bot_id, id, display_name, description)
VALUES ('bot-b', 'support', 'Support B', 'cross-bot isolation fixture')
ON CONFLICT DO NOTHING;

SET ROLE router_test_app;
SET app.bot_id = 'bot-a';

INSERT INTO telegram_agent.bot_agent_registry (bot_id, id, display_name, description, commands)
VALUES ('bot-a', 'invoice', 'Invoice', 'invoice specialist', ARRAY['/invoice']);

SELECT (telegram_agent.get_or_create_session('bot-a', 1001, 1001)).id AS first_id \gset
SELECT
  (s).id AS second_id,
  (s).message_count AS second_count
FROM (SELECT telegram_agent.get_or_create_session('bot-a', 1001, 1001) AS s) q \gset

SELECT :'first_id'::uuid = :'second_id'::uuid AS ok_same_session \gset
\if :ok_same_session
\else
  \echo 'get_or_create_session returned a different active session'
  \quit 1
\endif

SELECT :second_count::integer = 2 AS ok_message_count \gset
\if :ok_message_count
\else
  \echo 'get_or_create_session did not increment message_count'
  \quit 1
\endif

INSERT INTO telegram_agent.jobs (bot_id, update_id, chat_id, user_id, update_json, expires_at)
VALUES ('bot-a', 5001, 1001, 1001, '{"update_id":5001}', now() + interval '1 day')
ON CONFLICT (bot_id, update_id) DO NOTHING;
INSERT INTO telegram_agent.jobs (bot_id, update_id, chat_id, user_id, update_json, expires_at)
VALUES ('bot-a', 5001, 1001, 1001, '{"update_id":5001,"duplicate":true}', now() + interval '1 day')
ON CONFLICT (bot_id, update_id) DO NOTHING;

SELECT count(*) = 1 AS ok_update_dedupe
FROM telegram_agent.jobs WHERE bot_id = 'bot-a' AND update_id = 5001 \gset
\if :ok_update_dedupe
\else
  \echo 'duplicate update_id created more than one durable job'
  \quit 1
\endif

SELECT
  (j).status AS claimed_status,
  (j).attempts AS claimed_attempts
FROM (SELECT telegram_agent.claim_job('bot-a') AS j) q \gset

SELECT :'claimed_status' = 'processing' AS ok_claim_status \gset
\if :ok_claim_status
\else
  \echo 'claim_job did not mark job processing'
  \quit 1
\endif

SELECT :claimed_attempts::integer = 1 AS ok_claim_attempt \gset
\if :ok_claim_attempt
\else
  \echo 'claim_job did not increment attempts'
  \quit 1
\endif

SELECT count(*) = 0 AS ok_cross_bot_read
FROM telegram_agent.bot_agent_registry WHERE bot_id = 'bot-b' \gset
\if :ok_cross_bot_read
\else
  \echo 'RLS exposed a different bot_id'
  \quit 1
\endif

RESET app.bot_id;
SELECT count(*) = 0 AS ok_missing_context
FROM telegram_agent.bot_agent_registry \gset
\if :ok_missing_context
\else
  \echo 'RLS did not fail closed when app.bot_id was missing'
  \quit 1
\endif

RESET ROLE;
DROP SCHEMA telegram_agent CASCADE;
DROP ROLE router_test_app;

SELECT 'telegram-agent-router runtime: OK' AS result;
