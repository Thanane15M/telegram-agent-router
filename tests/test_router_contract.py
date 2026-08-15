import unittest

from examples.router_contract import (
    MAX_MESSAGE_CHARS,
    route_fast_path,
    split_telegram_text,
    telegram_retry_after,
)


class RouterContractTests(unittest.TestCase):
    def test_split_never_exceeds_limit(self):
        text = "a" * (MAX_MESSAGE_CHARS * 2 + 17)
        chunks = split_telegram_text(text)
        self.assertEqual("".join(chunks), text)
        self.assertTrue(chunks)
        self.assertTrue(all(0 < len(chunk) <= MAX_MESSAGE_CHARS for chunk in chunks))

    def test_known_command_skips_classifier(self):
        decision = route_fast_path(
            "/invoice@mybot 123",
            command_routes={"/invoice": "invoice"},
        )
        self.assertEqual(decision.target_agent, "invoice")
        self.assertEqual(decision.reason, "command")
        self.assertFalse(decision.needs_classifier)

    def test_callback_precedes_other_routes(self):
        decision = route_fast_path(
            "anything",
            command_routes={},
            callback_data="approve:quote_123",
            callback_routes={"approve": "approvals"},
            locked_agent="sales",
        )
        self.assertEqual(decision.target_agent, "approvals")
        self.assertEqual(decision.reason, "callback")

    def test_session_lock_precedes_keyword(self):
        decision = route_fast_path(
            "invoice please",
            command_routes={},
            locked_agent="onboarding",
            keyword_routes={"invoice": ["invoice"]},
        )
        self.assertEqual(decision.target_agent, "onboarding")
        self.assertEqual(decision.reason, "session_lock")

    def test_ambiguous_keywords_require_classifier(self):
        decision = route_fast_path(
            "price quote",
            command_routes={},
            keyword_routes={"sales": ["quote"], "pricing": ["price"]},
        )
        self.assertTrue(decision.needs_classifier)
        self.assertIsNone(decision.target_agent)

    def test_retry_after_uses_api_value(self):
        self.assertEqual(
            telegram_retry_after({"parameters": {"retry_after": 4}}),
            4.0,
        )
        self.assertEqual(telegram_retry_after({}, default=2.5), 2.5)


if __name__ == "__main__":
    unittest.main()
