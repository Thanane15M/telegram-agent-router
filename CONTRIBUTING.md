# Contributing

Contributions are welcome when they improve routing correctness, Telegram API accuracy, privacy/security, or reproducible evidence.

## Before changing behavior

1. Identify the routing/state/platform claim being changed.
2. Check current Telegram Bot API/FAQ for time-sensitive platform facts.
3. Update an eval for decision behavior.
4. Add/update deterministic Python tests for routing/chunking logic.
5. Add/update PostgreSQL runtime tests for schema/RLS/session/job changes.
6. Preserve useful superseded guidance in a clearly labelled historical reference rather than silently deleting it.
7. Keep `SKILL.md` concise; detailed material belongs in one-level references.

## Validation

```bash
python -m pip install -r requirements-dev.txt
python scripts/validate_markdown.py
python scripts/validate_skill.py
python -m unittest discover -s tests -p 'test_*.py'
```

With PostgreSQL 18:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema/telegram_agent_router.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/runtime.sql
```

## Claim discipline

A PR must state what remains `PARTIAL` or `NOT_PROVEN`. Do not call a target deployment production-ready because documentation, schema, or CI is green.
