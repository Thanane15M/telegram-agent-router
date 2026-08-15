"""Deterministic reference primitives for a Telegram multi-agent router.

No network calls or secrets are required. The goal is to make the routing contract
and message-boundary behavior executable and regression-testable.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Sequence

MAX_MESSAGE_CHARS = 4096


@dataclass(frozen=True)
class RouteDecision:
    target_agent: str | None
    reason: str
    confidence: float
    needs_classifier: bool = False


def split_telegram_text(text: str, limit: int = MAX_MESSAGE_CHARS) -> list[str]:
    """Split text into non-empty chunks without exceeding the supplied limit.

    The Bot API applies its documented limit after entity parsing; callers that use
    Markdown/HTML entities must validate the final serialized message separately.
    """
    if limit < 1:
        raise ValueError("limit must be positive")
    if not text:
        return []

    chunks: list[str] = []
    remaining = text
    while len(remaining) > limit:
        window = remaining[:limit]
        split_at = window.rfind("\n")
        if split_at <= 0:
            split_at = window.rfind(" ")
        if split_at <= 0:
            split_at = limit
        chunk = remaining[:split_at].rstrip()
        if not chunk:
            chunk = remaining[:limit]
            split_at = limit
        chunks.append(chunk)
        remaining = remaining[split_at:].lstrip()
    if remaining:
        chunks.append(remaining)

    if any(len(chunk) > limit or not chunk for chunk in chunks):
        raise AssertionError("invalid chunking invariant")
    return chunks


def route_fast_path(
    message: str,
    *,
    command_routes: Mapping[str, str],
    callback_data: str | None = None,
    callback_routes: Mapping[str, str] | None = None,
    locked_agent: str | None = None,
    keyword_routes: Mapping[str, Sequence[str]] | None = None,
) -> RouteDecision:
    """Apply deterministic routing before asking an LLM classifier.

    Order: callback -> command -> session lock -> deterministic keyword -> classifier.
    Keyword routing only succeeds when exactly one agent matches.
    """
    callback_routes = callback_routes or {}
    keyword_routes = keyword_routes or {}

    if callback_data:
        prefix = callback_data.split(":", 1)[0]
        target = callback_routes.get(prefix)
        if target:
            return RouteDecision(target, "callback", 1.0)

    stripped = message.strip()
    if stripped.startswith("/"):
        command = stripped.split(maxsplit=1)[0].split("@", 1)[0].lower()
        target = command_routes.get(command)
        if target:
            return RouteDecision(target, "command", 1.0)

    if locked_agent:
        return RouteDecision(locked_agent, "session_lock", 1.0)

    lowered = stripped.casefold()
    matches: list[str] = []
    for agent, hints in keyword_routes.items():
        if any(hint.casefold() in lowered for hint in hints if hint.strip()):
            matches.append(agent)

    unique_matches = sorted(set(matches))
    if len(unique_matches) == 1:
        return RouteDecision(unique_matches[0], "deterministic_intent", 0.9)

    return RouteDecision(None, "classifier", 0.0, needs_classifier=True)


def telegram_retry_after(payload: Mapping[str, object], default: float = 1.0) -> float:
    """Extract Telegram's retry_after value from a Bot API error payload."""
    parameters = payload.get("parameters")
    if isinstance(parameters, Mapping):
        value = parameters.get("retry_after")
        if isinstance(value, (int, float)) and value >= 0:
            return float(value)
    return float(default)
