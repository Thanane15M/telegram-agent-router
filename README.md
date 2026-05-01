![Claude Skill](https://img.shields.io/badge/Claude-Skill-orange) ![MIT License](https://img.shields.io/badge/License-MIT-green)

# telegram-agent-router

Telegram retries your webhook after 3 seconds without a response.
Your LLM call takes 5. Double message. Double cost. Incoherent conversation.
90% of Telegram bot tutorials skip this entirely.

This skill documents the correct architecture: immediate acknowledgment, async processing, PostgreSQL-native state.

## What this skill covers

The core pattern is a two-phase handler — respond to Telegram in under 200ms, then process in a background worker. On top of that: a hybrid intent classifier that routes simple commands on a fast local path (no LLM call) and escalates ambiguous input to an LLM only when needed. Session state is a typed finite state machine stored in PostgreSQL, not in memory, which means state survives restarts and scales horizontally without Redis. Cross-session memory uses the same database — no external vector store required. The skill includes the full schema, the rate-limiting patterns (per-user, per-agent, global), and the eight anti-patterns that break production bots.

Validated on a 10-agent production system. Each agent is isolated. Each has its own intent scope. The router classifies, dispatches, and never blocks.

## Who built this

Gaël-Wilfrid Mamou, Thanane Nextactik, Mayotte. Built and validated on a real system serving real users. Not a demo. Not a tutorial project.

## Install

```bash
claude skill install https://github.com/Thanane15M/telegram-agent-router
```

Or copy `SKILL.md` and `references/` into `.claude/skills/telegram-agent-router/`.

## License

MIT
