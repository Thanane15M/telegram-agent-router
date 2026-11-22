import importlib.util
import unittest
from unittest.mock import patch
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_upstream_drift.py"
SPEC = importlib.util.spec_from_file_location("telegram_upstream_drift", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class UpstreamDriftTests(unittest.TestCase):
    def test_parses_latest_version_from_changelog(self):
        body = "#### November 22, 2026\nBot API 10.5\n\nBot API 10.4"
        self.assertEqual(MODULE.parse_latest_bot_api_version(body), "10.5")

    def test_missing_version_is_explicit(self):
        self.assertIsNone(MODULE.parse_latest_bot_api_version("no release heading here"))

    def test_reviewed_version_is_pinned(self):
        self.assertEqual(MODULE.reviewed_version(), "10.5")

    def test_new_release_fails_closed_against_stale_review_pin(self):
        fixtures = {
            MODULE.PAGES["api"][0]: "sendMessageDraft 4096 retry_after",
            MODULE.PAGES["faq"][0]: "20 messages per minute 30 messages per second one message per second",
            MODULE.CHANGELOG_URL: "Bot API 10.5\n" + MODULE.CHANGELOG_BOT_TO_BOT_MARKER,
        }
        with patch.object(MODULE, "fetch", side_effect=lambda url: fixtures[url]):
            with patch.object(MODULE, "reviewed_version", return_value="10.4"):
                self.assertEqual(MODULE.main(), 1)

    def test_bot_to_bot_fact_checked_in_official_changelog_not_api_page(self):
        self.assertNotIn("bot-to-bot communication", MODULE.PAGES["api"][1])
        fixtures = {
            MODULE.PAGES["api"][0]: "sendMessageDraft 4096 retry_after",
            MODULE.PAGES["faq"][0]: "20 messages per minute 30 messages per second one message per second",
            MODULE.CHANGELOG_URL: "Bot API 10.5\n" + MODULE.CHANGELOG_BOT_TO_BOT_MARKER,
        }
        with patch.object(MODULE, "fetch", side_effect=lambda url: fixtures[url]):
            self.assertEqual(MODULE.main(), 0)
            fixtures[MODULE.CHANGELOG_URL] = "Bot API 10.4"
            self.assertEqual(MODULE.main(), 1)


if __name__ == "__main__":
    unittest.main()
