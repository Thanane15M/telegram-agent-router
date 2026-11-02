\set ON_ERROR_STOP on

BEGIN;

INSERT INTO telegram_agent.bot_agent_registry (bot_id, id, display_name, description)
VALUES ('ephemeral-test-bot', 'router', 'Router', 'fixture')
ON CONFLICT DO NOTHING;

INSERT INTO telegram_agent.sessions (bot_id, user_id, chat_id)
VALUES ('ephemeral-test-bot', 1001, 2001)
RETURNING id \gset test_session_

INSERT INTO telegram_agent.messages
  (bot_id, session_id, user_id, chat_id, telegram_msg_id, role, content)
VALUES
  ('ephemeral-test-bot', :'test_session_id', 1001, 2001, 10, 'user', 'regular');

INSERT INTO telegram_agent.messages
  (bot_id, session_id, user_id, chat_id, ephemeral_message_id, role, content)
VALUES
  ('ephemeral-test-bot', :'test_session_id', 1001, 2001, 10, 'user', 'ephemeral');

DO $$
BEGIN
  IF (SELECT count(*) FROM telegram_agent.messages WHERE bot_id='ephemeral-test-bot' AND telegram_msg_id=10) <> 1 THEN
    RAISE EXCEPTION 'regular identity insert failed';
  END IF;
  IF (SELECT count(*) FROM telegram_agent.messages WHERE bot_id='ephemeral-test-bot' AND ephemeral_message_id=10) <> 1 THEN
    RAISE EXCEPTION 'ephemeral identity insert failed';
  END IF;
END $$;

DO $$
BEGIN
  BEGIN
    INSERT INTO telegram_agent.messages
      (bot_id, session_id, user_id, chat_id, telegram_msg_id, ephemeral_message_id, role, content)
    VALUES
      ('ephemeral-test-bot', (SELECT id FROM telegram_agent.sessions WHERE bot_id='ephemeral-test-bot' AND user_id=1001 AND chat_id=2001 ORDER BY started_at DESC LIMIT 1), 1001, 2001, 11, 12, 'user', 'invalid');
    RAISE EXCEPTION 'mixed regular/ephemeral identity unexpectedly accepted';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;
END $$;

DO $$
BEGIN
  BEGIN
    INSERT INTO telegram_agent.messages
      (bot_id, session_id, user_id, chat_id, ephemeral_message_id, role, content)
    VALUES
      ('ephemeral-test-bot', (SELECT id FROM telegram_agent.sessions WHERE bot_id='ephemeral-test-bot' AND user_id=1001 AND chat_id=2001 ORDER BY started_at DESC LIMIT 1), 1001, 2001, 10, 'user', 'duplicate ephemeral');
    RAISE EXCEPTION 'duplicate ephemeral identity unexpectedly accepted';
  EXCEPTION
    WHEN unique_violation THEN NULL;
  END;
END $$;

ROLLBACK;

SELECT 'ephemeral message identity: OK' AS result;
