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


if __name__ == "__main__":
    unittest.main()

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
