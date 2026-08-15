# PostgreSQL schema reference

The executable source of truth is [`../schema/telegram_agent_router.sql`](../schema/telegram_agent_router.sql). This document explains the invariants that the DDL enforces.

## Data authority

PostgreSQL stores durable bot routing state:

- `bot_agent_registry` — registered specialists and routing hints;
- `sessions` — active conversation/flow state;
- `messages` — bounded conversation history when retention policy permits it;
- `memory` — deliberate long-term facts with source/confidence/expiry;
- `jobs` — durable Telegram update work queue and dedupe authority;
- `dispatch_log` — routing telemetry under explicit retention.

The database is not an excuse to store every message forever.

## Multi-bot isolation

Every tenant-owned row includes `bot_id`. RLS compares it with the request-scoped PostgreSQL setting `app.bot_id`:

```sql
SET LOCAL app.bot_id = 'support-bot';
```

If the setting is missing or empty, policies fail closed. Runtime tests use a non-bypass application role; testing as a table owner/superuser is not sufficient RLS evidence.

## Real get-or-create session

The canonical function serializes one `(bot_id,user_id,chat_id)` session decision with a transaction-scoped advisory lock, then either updates the active session or inserts a new one:

```sql
SELECT telegram_agent.get_or_create_session(
  'support-bot',
  123456,
  123456,
  interval '30 minutes'
);
```

This fixes the historical reference whose heading said “get or create” while the SQL only updated an existing row.

## Webhook idempotency

`jobs` has a unique constraint on `(bot_id, update_id)`. Intake should use an insert such as:

```sql
INSERT INTO telegram_agent.jobs (
  bot_id, update_id, chat_id, user_id, update_json, expires_at
) VALUES (
  $1, $2, $3, $4, $5, now() + interval '7 days'
)
ON CONFLICT (bot_id, update_id) DO NOTHING
RETURNING id;
```

No returned row means the update was already accepted. Downstream external side effects still need their own idempotency strategy.

## Durable claim

```sql
SELECT telegram_agent.claim_job('support-bot');
```

The function claims one eligible row using `FOR UPDATE SKIP LOCKED`, increments attempts and marks it `processing`.

A complete worker also needs:

- processing timeout/reaper;
- retry scheduling;
- final failure/dead-letter inspection;
- graceful shutdown;
- backpressure;
- metrics and alerts.

## Message dedupe

Telegram message IDs can be absent for internally generated/system rows. The schema therefore uses a **partial unique index** only when `telegram_msg_id IS NOT NULL`; it does not accidentally forbid multiple internal messages in the same chat.

## Retention

`messages`, `memory`, `jobs` and `dispatch_log` expose `expires_at`. The product must define actual retention windows and cleanup jobs according to purpose, legal basis and recovery/debug requirements.

## Deployment note

The DDL enables RLS but does not create production roles. Provision application roles outside the schema migration according to the target platform, grant only required schema/table/function privileges, and do not grant `BYPASSRLS` to ordinary bot workers.

## Verification

Run:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema/telegram_agent_router.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/runtime.sql
```

See `VERIFICATION.md` for proof boundaries.

The previous long-form schema reference is preserved at `postgres-schema.pre-2026-08-15.md`.
