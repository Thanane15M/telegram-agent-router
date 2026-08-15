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

SELECT CASE WHEN :'first_id'::uuid = :'second_id'::uuid THEN 1 ELSE 1/0 END AS same_session_assertion;
SELECT CASE WHEN :second_count::integer = 2 THEN 1 ELSE 1/0 END AS message_count_assertion;

INSERT INTO telegram_agent.jobs (bot_id, update_id, chat_id, user_id, update_json, expires_at)
VALUES ('bot-a', 5001, 1001, 1001, '{"update_id":5001}', now() + interval '1 day')
ON CONFLICT (bot_id, update_id) DO NOTHING;
INSERT INTO telegram_agent.jobs (bot_id, update_id, chat_id, user_id, update_json, expires_at)
VALUES ('bot-a', 5001, 1001, 1001, '{"update_id":5001,"duplicate":true}', now() + interval '1 day')
ON CONFLICT (bot_id, update_id) DO NOTHING;
SELECT CASE WHEN count(*) = 1 THEN 1 ELSE 1/0 END AS update_dedupe_assertion
FROM telegram_agent.jobs WHERE bot_id = 'bot-a' AND update_id = 5001;

SELECT
  (j).status AS claimed_status,
  (j).attempts AS claimed_attempts
FROM (SELECT telegram_agent.claim_job('bot-a') AS j) q \gset
SELECT CASE WHEN :'claimed_status' = 'processing' THEN 1 ELSE 1/0 END AS claim_status_assertion;
SELECT CASE WHEN :claimed_attempts::integer = 1 THEN 1 ELSE 1/0 END AS claim_attempt_assertion;

SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 1/0 END AS cross_bot_read_assertion
FROM telegram_agent.bot_agent_registry WHERE bot_id = 'bot-b';

RESET app.bot_id;
SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 1/0 END AS missing_context_fails_closed_assertion
FROM telegram_agent.bot_agent_registry;

RESET ROLE;
DROP SCHEMA telegram_agent CASCADE;
DROP ROLE router_test_app;

SELECT 'telegram-agent-router runtime: OK' AS result;
