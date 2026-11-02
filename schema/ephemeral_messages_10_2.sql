BEGIN;

ALTER TABLE telegram_agent.messages
  ADD COLUMN IF NOT EXISTS ephemeral_message_id bigint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'telegram_agent.messages'::regclass
      AND conname = 'messages_one_telegram_identity'
  ) THEN
    ALTER TABLE telegram_agent.messages
      ADD CONSTRAINT messages_one_telegram_identity
      CHECK (telegram_msg_id IS NULL OR ephemeral_message_id IS NULL);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS messages_ephemeral_dedupe_idx
  ON telegram_agent.messages (bot_id, chat_id, ephemeral_message_id)
  WHERE ephemeral_message_id IS NOT NULL;

COMMIT;
