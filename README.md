# telegram-agent-router

Reference architecture and Agent Skill for Telegram bots that coordinate multiple specialized agents with durable state.

## What this repository now proves

The project separates documentation from executable evidence:

- `SKILL.md` — concise routing/architecture guidance.
- `schema/telegram_agent_router.sql` — executable PostgreSQL schema with multi-bot scoping, RLS, real session get-or-create and durable jobs.
- `examples/router_contract.py` — deterministic message chunking and routing primitives.
- `tests/` — Python contract tests plus PostgreSQL runtime checks.
- `evals/cases.jsonl` — behavioral evals for agent routing decisions.
- `VERIFICATION.md` — Telegram/PostgreSQL fact matrix and proof boundaries.

The pre-refactor long-form skill and corrected references are preserved as versioned historical files so no useful material is silently lost.

## Architecture

```text
Webhook
→ validate + dedupe/update_id
→ durable job row
→ acknowledge
→ worker
→ session get/create
→ deterministic route
→ classifier only when ambiguous
→ bounded agent
→ validated response
→ Telegram API with 429/retry_after handling
→ memory/audit under retention policy
```

## Run quality checks

```bash
python -m pip install -r requirements-dev.txt
python scripts/validate_markdown.py
python scripts/validate_skill.py
python -m unittest discover -s tests -p 'test_*.py'
```

With PostgreSQL 18 available:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema/telegram_agent_router.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/runtime.sql
```

GitHub Actions performs the same gates on pushes and pull requests.

## Proof vocabulary

- `VERIFIED` — authoritative upstream or deterministic runtime evidence supports the exact scoped claim.
- `VERIFIED_IN_CI` — repository check exists; inspect the current workflow run before treating it as green.
- `PARTIAL` — relevant evidence exists but a material behavior remains untested.
- `NOT_PROVEN` — do not claim target-bot/production behavior.

## Safety and privacy

Telegram messages, IDs, inferred memory and dispatch logs can be personal data. The current design fails closed on missing `bot_id` RLS context, distinguishes session context from explicit long-term memory, and adds retention fields rather than assuming indefinite storage.

A green CI run is still not proof that a specific production bot satisfies its latency, legal, cost, recovery or throughput requirements.

## Use as an Agent Skill

```bash
git clone https://github.com/Thanane15M/telegram-agent-router.git
```

Copy `SKILL.md` and the referenced files into the skill directory used by your agent environment.

## License

MIT
