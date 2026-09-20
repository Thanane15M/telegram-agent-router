#!/usr/bin/env python3
"""Sentinel for time-sensitive Telegram platform facts used by this repository.

This is a drift detector, not a parser of the complete Bot API. It checks both
specific facts used by the skill and the latest reviewed Bot API release. If it
fails, re-read the authoritative docs and update VERIFICATION.md before changing
any claim.
"""

from __future__ import annotations

import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "UPSTREAM_BOT_API_VERSION"
CHANGELOG_URL = "https://core.telegram.org/bots/api-changelog"

PAGES = {
    "api": (
        "https://core.telegram.org/bots/api",
        ("sendMessageDraft", "4096", "retry_after", "bot-to-bot communication"),
    ),
    "faq": (
        "https://core.telegram.org/bots/faq",
        ("20 messages per minute", "30 messages per second", "one message per second"),
    ),
}


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "telegram-agent-router-drift-check/2"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", errors="replace")


def parse_latest_bot_api_version(body: str) -> str | None:
    """Return the first Bot API X.Y version advertised by the official changelog."""
    match = re.search(r"Bot API\s+(\d+\.\d+)", body, flags=re.IGNORECASE)
    return match.group(1) if match else None


def reviewed_version() -> str:
    return VERSION_FILE.read_text(encoding="utf-8").strip()


def main() -> int:
    errors: list[str] = []

    for name, (url, markers) in PAGES.items():
        body = fetch(url).casefold()
        for marker in markers:
            if marker.casefold() not in body:
                errors.append(f"{name}: marker missing from {url}: {marker}")

    changelog = fetch(CHANGELOG_URL)
    current_version = parse_latest_bot_api_version(changelog)
    expected_version = reviewed_version()
    if current_version is None:
        errors.append(f"changelog: unable to determine latest Bot API version from {CHANGELOG_URL}")
    elif current_version != expected_version:
        errors.append(
            "changelog: reviewed Bot API version drifted "
            f"(reviewed={expected_version}, current={current_version}); re-review upstream facts"
        )

    if errors:
        print("Telegram upstream drift suspected:\n" + "\n".join(errors), file=sys.stderr)
        return 1

    print(f"Telegram upstream drift sentinel: reviewed Bot API {expected_version}; expected markers present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
