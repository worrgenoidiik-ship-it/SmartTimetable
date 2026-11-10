"""Tests for keeper.py without network or root:  python3 -m unittest test_keeper  (in this folder)."""
import os
import tempfile
import unittest
from unittest import mock

STATE_DIR = tempfile.mkdtemp()
os.environ["KEEPER_STATE_DIR"] = STATE_DIR
import keeper  # noqa: E402  (must see the temporary state folder)

SIGNED_IN = '<html><body class="path-my">... <a href="https://portal.ulsu.ru/login/logout.php?sesskey=x">Выход</a></body></html>'
GUEST = '<html><body class="notloggedin">login form</body></html>'
MAINTENANCE = "<html><body>Сервис временно недоступен</body></html>"
LIVE = {"MoodleSession": "live"}
NEW = {"MoodleSession": "new"}


def answer(status, html="", location=None):
    return mock.Mock(return_value=(status, {"Location": location} if location else {}, html))


class Verdict(unittest.TestCase):
    def test_signed_in_page(self):
        self.assertIs(keeper.verdict(200, {}, SIGNED_IN), True)

    def test_login_redirect_and_guest_page(self):
        self.assertIs(keeper.verdict(303, {"Location": "https://portal.ulsu.ru/login/index.php"}, ""), False)
        self.assertIs(keeper.verdict(200, {}, GUEST), False)
        self.assertIs(keeper.verdict(401, {}, ""), False)

    def test_relative_redirect_inside_the_portal_is_not_a_logout(self):
        self.assertIsNone(keeper.verdict(303, {"Location": "/my/"}, ""))
        self.assertIsNone(keeper.verdict(302, {}, ""))
        self.assertIs(keeper.verdict(303, {"Location": "/login/index.php"}, ""), False)
        self.assertIs(keeper.verdict(303, {"Location": "https://other.example/"}, ""), False)

    def test_portal_failure_is_not_a_logout(self):
        for status in (500, 502, 503, 504, 429):
            self.assertIsNone(keeper.verdict(status, {}, MAINTENANCE), status)


class KeeperState(unittest.TestCase):
    def setUp(self):
        keeper.state.clear()
        keeper.state.update(cookies=dict(LIVE), alive=True)
        patcher = mock.patch.object(keeper, "time_remaining", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_503_keeps_session_alive_and_retries_soon(self):
        with mock.patch.object(keeper, "request", answer(503, MAINTENANCE)):
            self.assertTrue(keeper.check())
        self.assertTrue(keeper.state["alive"])
        self.assertIn("503", keeper.state["error"])
        self.assertEqual(keeper.next_delay(True), keeper.RETRY_DELAY)

    def test_recovers_after_portal_failure(self):
        with mock.patch.object(keeper, "request", answer(503, MAINTENANCE)):
            keeper.check()
        with mock.patch.object(keeper, "request", answer(200, SIGNED_IN)):
            self.assertTrue(keeper.check())
        self.assertIsNone(keeper.state["error"])
        self.assertGreaterEqual(keeper.next_delay(True), keeper.MIN_DELAY)

    def test_real_logout_stops_pinging(self):
        with mock.patch.object(keeper, "request", answer(200, GUEST)):
            self.assertFalse(keeper.check())
        self.assertFalse(keeper.state["alive"])
        self.assertIsNone(keeper.next_delay(False))

    def test_unverifiable_new_cookies_do_not_replace_live_session(self):
        with mock.patch.object(keeper, "request", side_effect=OSError("no route")):
            code, _ = keeper.accept_cookies(dict(NEW))
        self.assertEqual(code, 503)
        self.assertEqual(keeper.state["cookies"], LIVE)

    def test_portal_error_on_new_cookies_does_not_replace_live_session(self):
        with mock.patch.object(keeper, "request", answer(503, MAINTENANCE)):
            code, _ = keeper.accept_cookies(dict(NEW))
        self.assertEqual(code, 503)
        self.assertEqual(keeper.state["cookies"], LIVE)

    def test_rejected_new_cookies_do_not_replace_live_session(self):
        with mock.patch.object(keeper, "request", answer(303, location="https://portal.ulsu.ru/login/index.php")):
            code, payload = keeper.accept_cookies(dict(NEW))
        self.assertEqual(code, 200)
        self.assertTrue(payload["alive"])
        self.assertEqual(keeper.state["cookies"], LIVE)

    def test_working_new_cookies_replace_old_ones(self):
        with mock.patch.object(keeper, "request", answer(200, SIGNED_IN)):
            code, payload = keeper.accept_cookies(dict(NEW))
        self.assertEqual(code, 200)
        self.assertTrue(payload["alive"])
        self.assertEqual(keeper.state["cookies"], NEW)

    def test_without_a_live_session_unverifiable_cookies_are_kept(self):
        keeper.state.update(alive=False)
        with mock.patch.object(keeper, "request", side_effect=OSError("no route")):
            code, _ = keeper.accept_cookies(dict(NEW))
        self.assertEqual(code, 200)
        self.assertEqual(keeper.state["cookies"], NEW)


class Limits(unittest.TestCase):
    def test_cookies_with_a_line_break_are_refused(self):
        self.assertTrue(keeper.valid_cookies({"MoodleSession": "abc123"}))
        self.assertFalse(keeper.valid_cookies({"MoodleSession": "abc\n"}))
        self.assertFalse(keeper.valid_cookies({"Moodle\n": "abc"}))
        self.assertFalse(keeper.valid_cookies({"a": "b\r\nX-Evil: 1"}))
        self.assertFalse(keeper.valid_cookies({}))
        self.assertFalse(keeper.valid_cookies(["MoodleSession"]))
        self.assertFalse(keeper.valid_cookies({"a": 1}))

    def test_header_error_is_not_a_crash(self):
        keeper.state.clear()
        keeper.state.update(cookies=dict(LIVE), alive=True)
        with mock.patch.object(keeper, "request", side_effect=ValueError("Invalid header value")):
            self.assertTrue(keeper.check())
            code, _ = keeper.accept_cookies(dict(NEW))
        self.assertEqual(code, 503)
        self.assertEqual(keeper.state["cookies"], LIVE)

    def test_connection_slots(self):
        keeper.connections.clear()
        for _ in range(keeper.MAX_PER_IP):
            self.assertTrue(keeper.take_slot("10.0.0.1"))
        self.assertFalse(keeper.take_slot("10.0.0.1"))      # one address cannot take them all
        self.assertTrue(keeper.take_slot("10.0.0.2"))
        keeper.free_slot("10.0.0.1")
        self.assertTrue(keeper.take_slot("10.0.0.1"))
        keeper.connections.clear()
        for i in range(keeper.MAX_CONNECTIONS):
            self.assertTrue(keeper.take_slot(f"10.1.0.{i}"))
        self.assertFalse(keeper.take_slot("10.2.0.1"))      # total cap
        keeper.free_slot("10.1.0.0")
        self.assertEqual(keeper.connections.get("10.1.0.0"), None)
        keeper.connections.clear()

    def test_old_failures_are_forgotten(self):
        keeper.failures.clear()
        keeper.note_failure("1.1.1.1", 1000)
        keeper.note_failure("2.2.2.2", 1500)
        keeper.note_failure("2.2.2.2", 1700)                # 1.1.1.1 was quiet for more than 10 minutes
        self.assertEqual(list(keeper.failures), ["2.2.2.2"])
        self.assertEqual(len(keeper.failures["2.2.2.2"]), 2)
        keeper.failures.clear()


if __name__ == "__main__":
    unittest.main()
