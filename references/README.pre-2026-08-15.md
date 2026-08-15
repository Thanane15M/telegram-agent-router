![Claude Skill](https://img.shields.io/badge/Claude-Skill-orange) ![MIT License](https://img.shields.io/badge/License-MIT-green)

# telegram-agent-router

Webhook delivery can be retried after an unsuccessful or interrupted response.
Running an LLM call inside the request path therefore risks duplicate work,
double cost, and incoherent conversation state.

This skill documents the correct architecture: immediate acknowledgment, async processing, PostgreSQL-native state.

## What this skill covers

The core pattern is a two-phase handler — respond to Telegram in under 200ms, then process in a background worker. On top of that: a hybrid intent classifier that routes simple commands on a fast local path (no LLM call) and escalates ambiguous input to an LLM only when needed. Session state is a typed finite state machine stored in PostgreSQL, not in memory, which means state survives restarts and scales horizontally without Redis. Cross-session memory uses the same database — no external vector store required. The skill includes the full schema, the rate-limiting patterns (per-user, per-agent, global), and the eight anti-patterns that break production bots.

Designed from production multi-agent patterns. Each agent is isolated, has its
own intent scope, and receives work through a non-blocking router contract.

## Who built this

Gaël-Wilfrid Mamou, Thanane Nextactik, Mayotte. The repository focuses on
implementation patterns and executable examples rather than a hosted demo.

## Install

```bash
git clone https://github.com/Thanane15M/telegram-agent-router.git
```

Copy `SKILL.md` and `references/` into your agent's local skills directory.

## License

MIT
