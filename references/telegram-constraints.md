# Telegram constraints — current reference

Last evidence review: **2026-08-15**. Platform limits are time-sensitive; verify the current Bot API and Bots FAQ before hard-coding them.

## Webhook delivery

- Treat each `update_id` as an idempotency key for intake.
- Return a successful webhook response promptly; slow LLM/tool work belongs in a durable background job.
- Use `setWebhook.secret_token` and compare the `X-Telegram-Bot-Api-Secret-Token` header without logging the secret.
- Restrict `allowed_updates` to update types the bot actually handles.
- A retry-safe intake path must not double-charge, double-send, or repeat side effects when Telegram redelivers an update.

## Text size

Current `sendMessage` documentation defines text as **1–4096 characters after entities parsing**.

Chunking code must therefore:

- keep each final chunk within the current API limit;
- avoid empty chunks;
- consider Markdown/HTML entity parsing;
- preserve ordering when multiple chunks are sent;
- handle partial failure if chunk N succeeds and chunk N+1 fails.

Use `examples/router_contract.py` for the repository's deterministic plain-text splitter.

## Flood control and rate limits

Telegram's current Bots FAQ advises:

- in a single chat, avoid sustained rates above roughly **1 message/second**; short bursts may be tolerated before 429 responses;
- in a group, bots cannot send more than **20 messages/minute**;
- free bulk notifications are limited to roughly **30 messages/second**;
- eligible paid broadcasts can increase bulk throughput substantially (currently documented up to 1000 messages/second).

These are not a reason to implement one global fixed limiter for every traffic class.

### Required behavior on 429

Read `parameters.retry_after` from the Bot API error response and delay that operation accordingly. Keep retries bounded and idempotent.

```python
from examples.router_contract import telegram_retry_after

payload = {"parameters": {"retry_after": 3}}
delay = telegram_retry_after(payload)
```

## Draft streaming

The current Bot API exposes `sendMessageDraft` for partial generated-message UX. Current documentation describes the draft as temporary/ephemeral and requires sending the final durable message separately.

Treat draft streaming as optional:

- verify current support/constraints before enabling it;
- do not use a draft as the durable conversation record;
- use a stable non-zero draft ID when the current API requires one;
- still apply output validation, privacy controls and final-send error handling.

## Typing indicator

`sendChatAction` is UX only; the typing status expires automatically after a short interval (currently documented as 5 seconds or less). It is not job state, a lock, or proof that work is still running.

## Callback data

Keep callback payloads small and opaque. Prefer a short prefix + identifier and load authoritative state from PostgreSQL rather than embedding sensitive/full business state into buttons.

```text
approve:quote_123
reject:quote_123
```

Never place secrets, access tokens or personal data in callback data.

## Formatting

For dynamic/user-generated text, plain text or correctly escaped HTML/MarkdownV2 is safer than concatenating untrusted markup.

When message formatting fails, do not silently drop the response; log the error class without sensitive content and use a safe fallback where the product requires it.

## Source links

- Bot API: `https://core.telegram.org/bots/api`
- Bots FAQ: `https://core.telegram.org/bots/faq`

The pre-2026-08-15 constraints document is preserved at `telegram-constraints.pre-2026-08-15.md`.
