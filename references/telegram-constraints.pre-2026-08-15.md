# Telegram Constraints — Everything That Will Break Your Bot

Production reference for the Telegram Bot API hard limits.
Every number here is verified against the official API documentation.

---

## WEBHOOK CONSTRAINTS

| Constraint | Value | Consequence if violated |
|---|---|---|
| Webhook response | Return a successful response promptly | Failed or interrupted delivery may be retried |
| Max webhook connections | 100 (default) | Adjust with `setWebhook.max_connections` |
| Allowed update types | Must be declared | Undeclared types are silently dropped |
| HTTPS required | Mandatory | HTTP webhooks rejected |
| Port | 443, 80, 88, or 8443 | Other ports rejected |
| Certificate | Must be valid | Self-signed allowed if you provide it |

```python
# Correct setWebhook call
async def register_webhook(token: str, url: str, secret: str):
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"https://api.telegram.org/bot{token}/setWebhook",
            json={
                "url": url,
                "secret_token": secret,               # Validate in handler
                "allowed_updates": [                  # Only what you handle
                    "message",
                    "callback_query",
                    "inline_query"                    # Remove if unused
                ],
                "max_connections": 100,
                "drop_pending_updates": False         # Set True on first deploy
            }
        )
    return resp.json()

# Validate secret token in every webhook request
def validate_webhook_secret(request_headers: dict, expected: str) -> bool:
    received = request_headers.get("X-Telegram-Bot-Api-Secret-Token", "")
    return secrets.compare_digest(received, expected)
```

---

## MESSAGE SIZE LIMITS

| Content type | Limit |
|---|---|
| Text message | **4096 characters** |
| Caption (photo/video/document) | **1024 characters** |
| Inline keyboard button text | **64 characters** |
| Callback query data | **64 bytes** |
| Inline query results | **50 results** |
| Inline query answer cache | 300 seconds default |

```python
# Inline keyboard callback data: 64 bytes max.
# Use structured prefixes to route callbacks:

# ❌ Too much data in callback
callback_data = json.dumps({"action": "approve_quote", "quote_id": 12345, "user_id": 67890})
# 60 bytes — technically ok but fragile at scale

# ✅ Use prefix:id pattern, look up full data from DB
callback_data = "approve:12345"   # 14 bytes — safe, unambiguous

# In your router:
if ':' in callback_data:
    prefix, payload = callback_data.split(':', 1)
    # Route by prefix
    CALLBACK_ROUTES = {
        'approve': ApproveHandler,
        'reject':  RejectHandler,
        'view':    ViewHandler,
    }
    handler = CALLBACK_ROUTES.get(prefix, DefaultHandler)
    await handler.handle(payload, ctx)
```

---

## RATE LIMITS

| Limit | Value | Notes |
|---|---|---|
| Global message rate | **30 messages/second** | Across all chats combined |
| Per-chat rate | **~1 message/second** | Soft limit, enforced per chat |
| Flood control | 429 error with `retry_after` | Respect the field in the error |
| `getUpdates` polling | 1 request/second max | Use webhooks instead |

```python
import asyncio
import httpx

async def send_with_retry(token: str, chat_id: int, text: str, max_retries: int = 3):
    """Send message with automatic rate limit handling."""
    url = f"https://api.telegram.org/bot{token}/sendMessage"

    for attempt in range(max_retries):
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(url, json={
                    "chat_id": chat_id,
                    "text": text,
                    "parse_mode": "Markdown"
                }, timeout=10.0)

            data = resp.json()

            if resp.status_code == 429:
                retry_after = data.get("parameters", {}).get("retry_after", 5)
                await asyncio.sleep(retry_after + 0.5)    # Add buffer
                continue

            if not data.get("ok"):
                raise ValueError(f"Telegram error: {data.get('description')}")

            return data["result"]

        except httpx.TimeoutException:
            if attempt == max_retries - 1:
                raise
            await asyncio.sleep(2 ** attempt)

    raise RuntimeError(f"Failed to send after {max_retries} attempts")
```

---

## PARSE MODES

Telegram supports three text formatting modes.
Choose one per message — they cannot be mixed.

```python
# MarkdownV2 (recommended — most features, strictest escaping)
# Must escape these characters: _ * [ ] ( ) ~ ` > # + - = | { } . !
def escape_md2(text: str) -> str:
    """Escape all special chars for MarkdownV2."""
    chars = r'_*[]()~`>#+-=|{}.!'
    return re.sub(f'([{re.escape(chars)}])', r'\\\1', text)

# HTML (easier for dynamic content — no escaping hell)
# Supported tags: <b>, <i>, <u>, <s>, <code>, <pre>, <a href="">
def format_html(title: str, body: str) -> str:
    return f"<b>{html.escape(title)}</b>\n\n{html.escape(body)}"

# Plain text (safest — use when content is user-generated)
# No formatting, but also no accidental parse errors
```

---

## INLINE KEYBOARDS — PRODUCTION PATTERNS

```python
from typing import Optional

def build_inline_keyboard(buttons: list[list[dict]]) -> dict:
    """
    buttons: [[{'text': 'Approve', 'callback_data': 'approve:123'}]]
    Max 8 buttons per row. Max 100 buttons total.
    """
    return {"inline_keyboard": buttons}

# Pagination pattern (common for long lists)
def paginated_keyboard(
    items: list[tuple[str, str]],   # (label, callback_data)
    page: int,
    page_size: int = 5,
    prefix: str = "page"
) -> dict:
    start = page * page_size
    page_items = items[start:start + page_size]

    rows = [[{"text": label, "callback_data": data}] for label, data in page_items]

    nav = []
    if page > 0:
        nav.append({"text": "← Prev", "callback_data": f"{prefix}:{page-1}"})
    if start + page_size < len(items):
        nav.append({"text": "Next →", "callback_data": f"{prefix}:{page+1}"})
    if nav:
        rows.append(nav)

    return build_inline_keyboard(rows)

# Always handle "message not modified" error when editing keyboards
async def safe_edit_keyboard(message_id: int, chat_id: int, keyboard: dict, token: str):
    try:
        await edit_message_reply_markup(message_id, chat_id, keyboard, token)
    except TelegramError as e:
        if "message is not modified" in str(e).lower():
            pass   # Ignore — this is fine
        else:
            raise
```

---

## TYPING INDICATOR — USER EXPERIENCE

Always show "typing..." for responses that take > 500ms.

```python
async def send_with_typing(chat_id: int, generate_fn, token: str):
    """Show typing indicator while generating response."""
    # Start typing indicator
    typing_task = asyncio.create_task(
        send_chat_action(chat_id, "typing", token)
    )

    try:
        # Generate response (can take 2-10 seconds)
        response = await generate_fn()
    finally:
        typing_task.cancel()

    # Typing indicator auto-expires after 5 seconds.
    # For very long generations, send it every 4 seconds:
    # while generating: await send_chat_action(chat_id, "typing"); await asyncio.sleep(4)

    await send_message(chat_id, response, token)

async def send_chat_action(chat_id: int, action: str, token: str):
    """Valid actions: typing, upload_photo, record_video, upload_document, etc."""
    async with httpx.AsyncClient() as client:
        await client.post(
            f"https://api.telegram.org/bot{token}/sendChatAction",
            json={"chat_id": chat_id, "action": action}
        )
```

---

## DEEP LINKS — BOT ENTRY POINTS

```python
# Start link with parameter (for onboarding flows, referrals, etc.)
# https://t.me/YourBot?start=ref_12345

# In your /start handler:
async def handle_start(message: dict) -> AgentResponse:
    args = message.get('text', '').split()
    if len(args) > 1:
        start_param = args[1]   # e.g., 'ref_12345'
        # Decode and handle: referral tracking, deep link to specific flow, etc.
        if start_param.startswith('ref_'):
            referrer_id = start_param[4:]
            await write_memory(user_id, 'referred_by', referrer_id)
        elif start_param.startswith('flow_'):
            flow_name = start_param[5:]
            # Start specific onboarding flow
```
