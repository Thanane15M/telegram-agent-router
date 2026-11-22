# Telegram constraints — current reference

Last evidence review: **2026-11-22**. Reviewed upstream release: **Telegram Bot API 10.5 (2026-11-22)**. Platform limits and capabilities are time-sensitive; verify the current Bot API, changelog and Bots FAQ before hard-coding them.

## Webhook delivery

- Treat each `update_id` as an idempotency key for intake.
- Return a successful webhook response promptly; slow LLM/tool work belongs in a durable background job.
- Use `setWebhook.secret_token` and compare the `X-Telegram-Bot-Api-Secret-Token` header without logging the secret.
- Restrict `allowed_updates` to update types the bot actually handles.
- A retry-safe intake path must not double-charge, double-send, or repeat side effects when Telegram redelivers an update.

## Bot-to-bot communication

Bot API 10.0 (2026-05-08) introduced the ability to send messages to other bots by username when both bots have enabled bot-to-bot communication. Do not rely on older assumptions that bots can never exchange messages.

If bot-to-bot communication is not required, keep it disabled. If it is intentionally enabled, treat loop prevention as an application invariant:

- allow only explicitly configured peer bots;
- preserve durable idempotency for each accepted update and downstream side effect;
- enforce bounded interaction depth/time or an equivalent loop budget;
- do not let a model expand the peer allowlist or interaction budget by itself;
- keep routing/audit records sufficient to identify repeated bot-to-bot cycles without storing secrets.

This repository does **not** prove a particular production bot-to-bot deployment; such behavior remains `NOT_PROVEN` until exercised in the target environment.

## Ephemeral message identity (storage verified in CI, sending not proven)

Bot API **10.2 (2026-07-14)** introduced ephemeral messages, `ephemeral_message_id`, an optional regular `message_id` in reply parameters when the ephemeral identifier is present, and dedicated ephemeral edit/delete methods. Bot API **10.3 (2026-08-24)** then replaced the initial `receiver_user_id`/`callback_query_id` send-method parameters with `ephemeral_message_parameters`.

Keep regular and ephemeral message identifiers in separate typed identity families. Webhook intake must still deduplicate on `(bot_id, update_id)`; a nullable ordinary `telegram_msg_id` alone is **not** proof of ephemeral support. Before documenting executable integration, add official-shape fixtures, explicit routing/edit/delete/reply selection tests and an additive migration if required. The additive `schema/ephemeral_messages_10_2.sql` and `tests/ephemeral_identity.sql` prove distinct storage identity when the exact-sha PostgreSQL CI check succeeds. Actual send/edit/delete/reply behavior and target deployments remain **NOT_PROVEN**.

Bot API **10.4 (2026-11-09)** allows an ephemeral callback reply to use `callback_query_id` without `receiver_user_id` in chats other than channel direct-message chats; `chat_id` is now optional for these send calls. No executable send-path support is claimed. Before implementing, add fixtures for optional identifiers, the excluded chat category, and authorization/recipient scoping; do not treat a callback ID as a durable message identifier.

## Widget updates (10.4)

Telegram added `widget_query` and `shared_widget_query` update types. Do not grant capabilities from widget-supplied content or wallet/card data: treat it as untrusted input and validate origin, permissions and transaction state independently. This repository has no verified widget handler.

## Bot API 10.5 — bot settings, callback identity and API types

The [official changelog](https://core.telegram.org/bots/api-changelog.md) dated **2026-11-22** adds `setMySettings` and an opt-in `callback_query_mode`: callbacks from buttons in bot-sent messages may include `inline_message_id` instead of `message`. A callback dispatcher must validate both shapes, bind the action to its authorized bot/chat/user context, and never assume `callback_query.message` exists. These paths are **NOT_PROVEN** in this repository; do not silently enable a settings mode or broaden bot/group/inline access.

The `getMe` result is now `BotFullInfo` (not `User`), and expandable rich quotation blocks use `blocks` instead of `text`. If a consumer relies on concrete returned types or rich-text decoders, add official-shape fixture tests before switching. No Telegram 10.5 handler or deployed interoperability is claimed.

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
- Bot API changelog: `https://core.telegram.org/bots/api-changelog`
- Bots FAQ: `https://core.telegram.org/bots/faq`

The pre-2026-08-15 constraints document is preserved at `telegram-constraints.pre-2026-08-15.md`.
