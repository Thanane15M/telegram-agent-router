import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_upstream_drift.py"
SPEC = importlib.util.spec_from_file_location("telegram_upstream_drift", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class UpstreamDriftTests(unittest.TestCase):
    def test_parses_latest_version_from_changelog(self):
        body = "<h4>August 24, 2026</h4><p>Bot API 10.3</p><p>Bot API 9.6</p>"
        self.assertEqual(MODULE.parse_latest_bot_api_version(body), "10.3")

    def test_missing_version_is_explicit(self):
        self.assertIsNone(MODULE.parse_latest_bot_api_version("no release heading here"))

    def test_reviewed_version_is_pinned(self):
        self.assertEqual(MODULE.reviewed_version(), "10.3")


if __name__ == "__main__":
    unittest.main()
