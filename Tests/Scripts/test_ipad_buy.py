"""Offline purchase observations; never contact WebDriverAgent or buy an app."""
import importlib.machinery
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


loader = importlib.machinery.SourceFileLoader(
    "ipad_buy", str(Path(__file__).resolve().parents[2] / "scripts" / "ipad-buy"))
spec = importlib.util.spec_from_loader(loader.name, loader)
buy = importlib.util.module_from_spec(spec)
loader.exec_module(buy)


class PurchaseProgressTests(unittest.TestCase):
    def setUp(self):
        self.clock = 0
        self.messages = []
        self.page = SimpleNamespace(title="Example Synth", offer=("get", "7,99 €"))
        self.session = Mock()
        for name, replacement in (
            ("say", self.messages.append),
            ("time", SimpleNamespace(time=lambda: self.clock, sleep=self.advance)),
        ):
            p = patch.object(buy, name, replacement)
            p.start()
            self.addCleanup(p.stop)

    def advance(self, seconds):
        self.clock += seconds

    def top(self, offer):
        return SimpleNamespace(offer=offer, read_top=Mock())

    def screen(self, state):
        return SimpleNamespace(texts=[], state=lambda: state)

    def follow(self, timeout=12):
        return buy.follow(self.session, self.page, "com.example.synth",
                          SimpleNamespace(timeout=timeout), 0)

    def test_locked_download_is_not_reported_as_installed(self):
        with patch.object(buy, "ipad_locked", return_value=True), \
                patch.object(buy, "installed", return_value=True):
            self.assertFalse(self.follow())
        self.assertFalse(any("installed:" in line for line in self.messages))
        self.assertTrue(any("Unlock it to verify" in line for line in self.messages))

    def test_unlock_and_open_verify_completion(self):
        with patch.object(buy, "ipad_locked", side_effect=[True, False]), \
                patch.object(buy, "installed", return_value=True), \
                patch.object(buy, "Page", return_value=self.top(("open", "Open"))):
            self.assertTrue(self.follow())
        self.assertIn("installed: Example Synth", self.messages[-1])

    def test_unknown_inventory_after_sheet_closes_waits_for_open(self):
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "installed", side_effect=[False, None, None, True]), \
                patch.object(buy, "Page", side_effect=[
                    self.top(self.page.offer), self.top(self.page.offer),
                    self.top(self.page.offer), self.top(("open", "Open"))]), \
                patch.object(buy, "Screen", side_effect=[
                    self.screen("double-press"), self.screen(None), self.screen(None)]):
            self.assertTrue(self.follow())
        self.assertFalse(any("nothing was bought" in line for line in self.messages))
        self.assertTrue(any("status is unknown" in line for line in self.messages))

    def test_closed_sheet_and_confirmed_absence_stop_early(self):
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "installed", return_value=False), \
                patch.object(buy, "Page", return_value=self.top(self.page.offer)), \
                patch.object(buy, "Screen", side_effect=[
                    self.screen("double-press"), self.screen(None), self.screen(None)]):
            self.assertFalse(self.follow())
        self.assertLess(self.clock, 12)
        self.assertTrue(any("press the top button" in line for line in self.messages))
        self.assertTrue(any("nothing was bought" in line for line in self.messages))


    def test_loading_button_while_sheet_waits_is_no_purchase(self):
        # As seen live: the button reads "Download vorbereiten" (state loading)
        # as soon as the sheet opens; the sheet then runs out unconfirmed.
        loading = ("loading", "Download vorbereiten")
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "installed", return_value=False), \
                patch.object(buy, "Page", side_effect=[
                    self.top(loading), self.top(loading),
                    self.top(self.page.offer), self.top(self.page.offer)]), \
                patch.object(buy, "Screen", side_effect=[
                    self.screen("double-press"), self.screen("double-press"),
                    self.screen(None), self.screen(None)]):
            self.assertFalse(self.follow())
        self.assertFalse(any("went through" in line for line in self.messages))
        self.assertTrue(any("waits for the purchase sheet" in line for line in self.messages))
        self.assertTrue(any("nothing was bought" in line for line in self.messages))

    def test_loading_button_does_not_skip_the_sheets_confirm_tap(self):
        loading = ("loading", "Download vorbereiten")
        sheet = SimpleNamespace(texts=["App kaufen", "Example Synth", "7,99 €"],
                                state=lambda: "confirm", confirm=["e1"],
                                shows=lambda text: True, where=buy.STORE)
        self.session.post.return_value = {"value": None}
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "installed", side_effect=[False, True]), \
                patch.object(buy, "Page", side_effect=[
                    self.top(loading), self.top(("open", "Öffnen"))]), \
                patch.object(buy, "Screen", side_effect=[sheet]):
            self.assertTrue(self.follow())
        self.assertTrue(any("confirmed the purchase sheet once" in line for line in self.messages))
        self.session.post.assert_any_call("/element/e1/click", {})

    def test_always_require_question_is_answered_with_always_only(self):
        # As seen live after the password: "Passwort für weitere Käufe auf
        # diesem Gerät erfordern?" with "Nach 15 Minuten anfordern" and
        # "Immer anfordern"; the script taps only the latter.
        dialog = SimpleNamespace(texts=["Passwort für weitere Käufe auf diesem Gerät erfordern?"],
                                 state=lambda: "always-ask", always=["a1"],
                                 always_where=buy.STORE)
        self.session.post.return_value = {"value": None}
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "installed", side_effect=[False, True]), \
                patch.object(buy, "Page", side_effect=[
                    self.top(("loading", "Download vorbereiten")), self.top(("open", "Öffnen"))]), \
                patch.object(buy, "Screen", side_effect=[dialog]):
            self.assertTrue(self.follow())
        self.session.post.assert_any_call("/element/a1/click", {})
        self.assertTrue(any("always require" in line for line in self.messages))

    def test_always_require_question_with_two_candidates_taps_nothing(self):
        dialog = SimpleNamespace(texts=["Passwort für weitere Käufe auf diesem Gerät erfordern?"],
                                 state=lambda: "always-ask", always=["a1", "a2"],
                                 always_where=buy.STORE)
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "installed", return_value=False), \
                patch.object(buy, "Page", return_value=self.top(self.page.offer)), \
                patch.object(buy, "Screen", side_effect=[dialog]):
            self.assertFalse(self.follow())
        self.assertFalse(any(c.args[0].endswith("/click") for c in self.session.post.call_args_list))


class ScreenTests(unittest.TestCase):
    def test_the_confirm_query_compares_each_word_without_in(self):
        # WebDriverAgent matched nothing with `label IN[c] {...}` on the live
        # sheet; its "Kauf" button was found with one comparison per word.
        session = Mock()
        session.source.return_value = {}
        session.find.return_value = []
        with patch.object(buy, "front_bundle", return_value=buy.STORE):
            buy.Screen(session)
        queries = [c.args[0] for c in session.find.call_args_list]
        confirm = [q for q in queries if "kauf" in q]
        self.assertTrue(confirm)
        self.assertNotIn(" IN", confirm[0])
        self.assertIn('label ==[c] "kauf"', confirm[0])


class PasswordPromptTests(unittest.TestCase):
    def tty(self):
        return patch.object(buy.sys, "stdin", SimpleNamespace(isatty=lambda: True))

    def test_an_empty_answer_is_asked_once_more(self):
        with self.tty(), patch.object(buy.sys, "stdout", SimpleNamespace(isatty=lambda: True)), \
                patch("getpass.getpass", side_effect=["", "pw"]) as ask:
            self.assertEqual(buy.ask_password(), "pw")
        self.assertEqual(ask.call_count, 2)

    def test_two_empty_answers_leave_it_to_the_ipad(self):
        with self.tty(), patch.object(buy.sys, "stdout", SimpleNamespace(isatty=lambda: True)), \
                patch("getpass.getpass", side_effect=["", ""]):
            self.assertEqual(buy.ask_password(), "")

    def test_no_terminal_asks_nothing(self):
        with patch.object(buy.sys, "stdin", SimpleNamespace(isatty=lambda: False)), \
                patch("getpass.getpass") as ask:
            self.assertIsNone(buy.ask_password())
        ask.assert_not_called()


if __name__ == "__main__":
    unittest.main()
