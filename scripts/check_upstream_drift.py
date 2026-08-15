#!/usr/bin/env python3
"""Sentinel for time-sensitive Telegram platform facts used by this repository.

This is a drift detector, not a parser of the complete Bot API. If it fails, re-read
the authoritative docs and update VERIFICATION.md before changing any claim.
"""

from __future__ import annotations

import sys
import urllib.request

PAGES = {
    "api": (
        "https://core.telegram.org/bots/api",
        ("sendMessageDraft", "4096", "retry_after"),
    ),
    "faq": (
        "https://core.telegram.org/bots/faq",
        ("20 messages per minute", "30 messages per second", "one message per second"),
    ),
}


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "telegram-agent-router-drift-check/1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", errors="replace")


def main() -> int:
    errors: list[str] = []
    for name, (url, markers) in PAGES.items():
        body = fetch(url).casefold()
        for marker in markers:
            if marker.casefold() not in body:
                errors.append(f"{name}: marker missing from {url}: {marker}")
    if errors:
        print("Telegram upstream drift suspected:\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print("Telegram upstream drift sentinel: expected markers present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
