## What changed

<!-- Routing, schema, Telegram fact, privacy, or validation change. -->

## Evidence

- [ ] Current Telegram Bot API/FAQ checked for time-sensitive facts
- [ ] `python scripts/validate_markdown.py`
- [ ] `python scripts/validate_skill.py`
- [ ] `python -m unittest discover -s tests -p 'test_*.py'`
- [ ] PostgreSQL runtime test updated/run if schema/RLS/session/jobs changed
- [ ] Eval case updated/run for routing behavior

## Security / privacy

- [ ] No bot token, webhook secret, customer chat content, credential or private infrastructure added
- [ ] Agent/tool authority remains bounded after handoff/fallback
- [ ] Retention and RLS impact considered
- [ ] External side effects have idempotency/approval where required

## Proof boundary

<!-- State what remains PARTIAL or NOT_PROVEN for a target deployment. -->
