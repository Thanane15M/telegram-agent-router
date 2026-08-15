# Security policy

## Report privately

Use GitHub private security reporting when available. Do not publish bot tokens, webhook secrets, user data, private chat content, exploit payloads against real bots, or infrastructure credentials in public issues.

## Security rules

- Validate the configured Telegram webhook secret and never log it.
- Deduplicate `update_id` before expensive work or side effects.
- Use least-privilege agent/tool permissions; handoff does not transfer authority.
- Treat user/retrieved text as untrusted input; it cannot override policy or authorize privileged tool calls.
- Keep bot tokens, API keys, cookies and credentials in secret stores/environment variables.
- Test RLS with a role that does not own tables and does not have `BYPASSRLS`.
- Set explicit retention for raw updates, messages, memory, jobs and dispatch logs.
- Use separate idempotency keys for downstream external side effects.
- GitHub Actions use least-privilege permissions and full-SHA-pinned third-party actions.
- Pull-request validation must not require privileged production secrets.

## Scope of repository claims

A green parser/unit/schema test is not an attestation that a specific production bot is secure or compliant. Target deployment, network, secrets, tool permissions, recovery and legal/privacy controls must be verified separately.
