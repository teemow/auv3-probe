"""Offline purchase observations; never contact WebDriverAgent or buy an app."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


loader = importlib.machinery.SourceFileLoader(
    "ipad_buy", str(Path(__file__).resolve().parents[2] / "scripts" / "ipad-buy"))
spec = importlib.util.spec_from_loader(loader.name, loader)
buy = importlib.util.module_from_spec(spec)
loader.exec_module(buy)

HAVE, NONE = {"com.example.synth"}, set()   # what `ios apps` lists


class FollowTestCase(unittest.TestCase):
    """follow() on a clock that advances only when it sleeps."""

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

    def screen(self, state):
        return SimpleNamespace(texts=[], state=lambda: state)


class PurchaseProgressTests(FollowTestCase):
    def top(self, offer):
        return SimpleNamespace(offer=offer, read_top=Mock())

    def follow(self, timeout=12):
        return buy.follow(self.session, self.page, "com.example.synth",
                          SimpleNamespace(timeout=timeout), 0)

    def test_locked_download_is_not_reported_as_installed(self):
        with patch.object(buy, "ipad_locked", return_value=True), \
                patch.object(buy, "listed", return_value=HAVE):
            self.assertFalse(self.follow())
        self.assertFalse(any("installed:" in line for line in self.messages))
        self.assertTrue(any("Unlock it to verify" in line for line in self.messages))

    def test_unlock_and_open_verify_completion(self):
        with patch.object(buy, "ipad_locked", side_effect=[True, False]), \
                patch.object(buy, "listed", return_value=HAVE), \
                patch.object(buy, "Page", return_value=self.top(("open", "Open"))):
            self.assertTrue(self.follow())
        self.assertIn("installed: Example Synth", self.messages[-1])

    def test_unknown_inventory_after_sheet_closes_waits_for_open(self):
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "listed", side_effect=[NONE, None, None, HAVE]), \
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
                patch.object(buy, "listed", return_value=NONE), \
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
                patch.object(buy, "listed", return_value=NONE), \
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
                patch.object(buy, "listed", side_effect=[NONE, HAVE]), \
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
                patch.object(buy, "listed", side_effect=[NONE, HAVE]), \
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
                patch.object(buy, "listed", return_value=NONE), \
                patch.object(buy, "Page", return_value=self.top(self.page.offer)), \
                patch.object(buy, "Screen", side_effect=[dialog]):
            self.assertFalse(self.follow())
        self.assertFalse(any(c.args[0].endswith("/click") for c in self.session.post.call_args_list))


# --- App Store bundles -------------------------------------------------------

BUNDLE_ID = "1000000000"
APPS = [("1000000001", "Example Synth", "com.example.synth", "22,99 €", False),
        ("1000000002", "Example Drums", "com.example.drums", "12,99 €", True)]
PRICE = ("get", "29,99 €")
ROWS = {"1000000001": ("Example Synth", ("get", "22,99 €")),
        "1000000002": ("Example Drums", ("get", "12,99 €"))}


def bundle_html(kind="BundlePageIntent", bundle_id=BUNDLE_ID, apps=APPS, iap=True):
    """A bundle page shaped like the App Store web app's serialized data."""
    children = [{"adamId": i, "title": t, "bundleId": b,
                 "offerDisplayProperties": {"priceFormatted": p, **({"hasInAppPurchases": x} if iap else {})}}
                for i, t, b, p, x in apps]
    data = {"data": [{"intent": {"$kind": kind, "id": bundle_id},
                      "data": {"title": "Example Bundle", "regularPriceFormatted": "35,98 €",
                               "titleOfferDisplayProperties": {"priceFormatted": "29,99 €", "isFree": False},
                               "developerAction": {"title": "Example Audio"},
                               "lockup": {"children": children}}}]}
    return ('<html><script type=application/ld+json>{}</script>'
            '<script type="application/json" id="serialized-server-data">' + json.dumps(data)
            + "</script></html>")


def bundle_entry(installed=frozenset(), lookups=None):
    entry = buy.parse_bundle_page(bundle_html(), BUNDLE_ID)
    for a in entry["apps"]:
        a["lookup"] = (lookups or {}).get(a["id"], {"trackName": a["name"], "bundleId": a["bundleId"]})
    entry["installed"] = set(installed)
    return entry


def bundle_page(rows=None, offer=PRICE):
    page = buy.Page()
    page.title, page.offer, page.developer, page.iap = "Example Bundle", offer, "Example Audio", "no"
    page.children = dict(ROWS if rows is None else rows)
    return page


NO_CONFIRMATION = SimpleNamespace(confirm_name=None, confirm_price=None)


class BundleIdTests(unittest.TestCase):
    def test_a_bundle_url_names_a_bundle(self):
        self.assertEqual(buy.app_id_of(
            "https://apps.apple.com/de/app-bundle/example-bundle/id1000000000?platform=iphone"),
            (BUNDLE_ID, "de", True))
        self.assertEqual(buy.app_id_of("itms-apps://apps.apple.com/app-bundle/id1000000000"),
                         (BUNDLE_ID, None, True))

    def test_an_app_url_and_a_bare_id_do_not(self):
        self.assertEqual(buy.app_id_of("https://apps.apple.com/de/app/example-synth/id1000000001"),
                         ("1000000001", "de", False))
        self.assertEqual(buy.app_id_of(BUNDLE_ID), (BUNDLE_ID, None, False))

    def test_a_bare_id_the_lookup_does_not_know_is_tried_as_a_bundle(self):
        entry = buy.parse_bundle_page(bundle_html(), BUNDLE_ID)
        with patch.object(buy, "lookup", side_effect=lambda i, cc: None if i == BUNDLE_ID else {"id": i}), \
                patch.object(buy, "bundle_lookup", return_value=entry), \
                patch.object(buy, "listed", return_value=NONE):
            got, bundle = buy.catalogue(BUNDLE_ID, "de", False)
        self.assertTrue(bundle)
        self.assertEqual([a["lookup"] for a in got["apps"]], [{"id": "1000000001"}, {"id": "1000000002"}])
        self.assertEqual(got["installed"], set())

    def test_an_app_the_lookup_knows_is_no_bundle(self):
        with patch.object(buy, "lookup", return_value={"trackName": "Example Synth"}), \
                patch.object(buy, "bundle_lookup") as page:
            self.assertEqual(buy.catalogue("1000000001", "de", False), ({"trackName": "Example Synth"}, False))
        page.assert_not_called()


class BundlePageTests(unittest.TestCase):
    def test_reads_name_price_developer_and_apps(self):
        entry = buy.parse_bundle_page(bundle_html(), BUNDLE_ID)
        self.assertEqual((entry["kind"], entry["trackName"], entry["formattedPrice"], entry["artistName"]),
                         ("bundle", "Example Bundle", "29,99 €", "Example Audio"))
        self.assertEqual([(a["id"], a["name"], a["bundleId"], a["formattedPrice"], a["iap"]) for a in entry["apps"]],
                         APPS)

    def test_another_page_or_another_id_is_no_bundle(self):
        self.assertIsNone(buy.parse_bundle_page(bundle_html(kind="AppPageIntent"), BUNDLE_ID))
        self.assertIsNone(buy.parse_bundle_page(bundle_html(), "1000000009"))
        self.assertIsNone(buy.parse_bundle_page(bundle_html(apps=[]), BUNDLE_ID))
        self.assertIsNone(buy.parse_bundle_page("<html>no data</html>", BUNDLE_ID))
        self.assertIsNone(buy.parse_bundle_page(
            '<script id="serialized-server-data">{"data": [{}]}</script>', BUNDLE_ID))

    def test_unknown_in_app_purchases_stay_unknown(self):
        entry = buy.parse_bundle_page(bundle_html(iap=False), BUNDLE_ID)
        self.assertEqual([a["iap"] for a in entry["apps"]], [None, None])

    def test_the_ipad_rows_of_the_apps_in_the_bundle(self):
        def cell(parent, app_id, title, price):
            button = {"name": "AppStore.offerButton[state=get]", "label": price}
            return {"name": f"AppStore.shelfItem.smallLockup[id={app_id},parentId={parent},cellType=Small"
                            "LockupCollectionViewCell,index=0,shelfIndex=2]",
                    "children": [{"name": "AppStore.shelfItemSubComponent.title", "label": title},
                                 dict(button, children=[dict(button)])]}
        tree = {"children": [cell("bundleChildren", "1000000001", "Example Synth", "22,99 €"),
                             cell("bundleChildren", "1000000002", "Example Drums", "12,99 €"),
                             cell("moreByDeveloper", "1000000003", "Example Bass", "9,99 €")]}
        page = buy.Page()
        page.read_children(tree)
        self.assertEqual(page.children, ROWS)


class BundleCheckTests(unittest.TestCase):
    def test_a_bundle_none_of_whose_apps_is_had_passes(self):
        self.assertEqual(buy.check(bundle_page(), bundle_entry(), NO_CONFIRMATION), [])

    def test_the_confirmation_is_the_bundles_name_and_price(self):
        args = SimpleNamespace(confirm_name="Example Bundle", confirm_price="29,99 €")
        self.assertEqual(buy.check(bundle_page(), bundle_entry(), args), [])
        args = SimpleNamespace(confirm_name="Example Bundle", confirm_price="22,99 €")
        self.assertTrue(any("--confirm-price" in r for r in buy.check(bundle_page(), bundle_entry(), args)))

    def test_an_app_bought_before_refuses_the_reduced_price(self):
        rows = dict(ROWS, **{"1000000002": ("Example Drums", ("redownload", "Laden"))})
        reasons = buy.check(bundle_page(rows), bundle_entry(), NO_CONFIRMATION)
        self.assertTrue(any('"Example Drums" is bought or installed already' in r for r in reasons))

    def test_an_installed_app_refuses(self):
        reasons = buy.check(bundle_page(), bundle_entry(installed={"com.example.drums"}), NO_CONFIRMATION)
        self.assertTrue(any("is installed already" in r for r in reasons))

    def test_other_apps_on_the_ipad_than_on_apples_page_refuse(self):
        rows = {"1000000001": ROWS["1000000001"]}
        reasons = buy.check(bundle_page(rows), bundle_entry(), NO_CONFIRMATION)
        self.assertTrue(any("the page lists 1 apps in the bundle" in r for r in reasons))

    def test_a_bundle_id_the_lookup_does_not_confirm_refuses(self):
        entry = bundle_entry(lookups={"1000000002": {"trackName": "Example Drums", "bundleId": "com.other"}})
        reasons = buy.check(bundle_page(), entry, NO_CONFIRMATION)
        self.assertTrue(any("bundle id com.other" in r for r in reasons))

    def test_an_unreadable_install_list_or_in_app_purchase_refuses(self):
        entry = bundle_entry()
        entry["installed"] = None
        entry["apps"][0]["iap"] = None
        reasons = buy.check(bundle_page(), entry, NO_CONFIRMATION)
        self.assertTrue(any("`ios apps` does not answer" in r for r in reasons))
        self.assertTrue(any('whether "Example Synth" has in-app purchases' in r for r in reasons))

    def test_a_bundle_is_bought_only_at_its_price(self):
        reasons = buy.check(bundle_page(offer=("redownload", "Laden")), bundle_entry(), NO_CONFIRMATION)
        self.assertTrue(any("a bundle is bought only at its price" in r for r in reasons))


class BundlePurchaseTests(FollowTestCase):
    WANT = {"1000000001": "com.example.synth", "1000000002": "com.example.drums"}

    def setUp(self):
        super().setUp()
        self.page = bundle_page()

    def top(self, synth, drums, offer=PRICE):
        return SimpleNamespace(offer=offer, read_top=Mock(), children={
            "1000000001": ("Example Synth", synth), "1000000002": ("Example Drums", drums)})

    def follow(self, timeout=12):
        return buy.follow(self.session, self.page, self.WANT, SimpleNamespace(timeout=timeout), 0)

    def test_done_only_when_every_app_is_listed_and_its_row_reads_open(self):
        opened, loading = ("open", "Öffnen"), ("downloading", "Wird geladen")
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "listed", side_effect=[
                    {"com.example.synth"}, set(self.WANT.values()), set(self.WANT.values())]), \
                patch.object(buy, "Page", side_effect=[
                    self.top(opened, loading), self.top(opened, loading), self.top(opened, opened)]) as pages, \
                patch.object(buy, "Screen", side_effect=[self.screen(None), self.screen(None)]):
            self.assertTrue(self.follow())
        # Listed in full on the second read, but "Example Drums" still loading:
        # only the third read, with both rows at Open, finishes.
        self.assertEqual(pages.call_count, 3)
        self.assertIn("installed: Example Bundle (com.example.drums, com.example.synth)", self.messages[-1])
        self.assertTrue(any("went through" in line for line in self.messages))

    def test_closed_sheet_with_every_row_as_before_bought_nothing(self):
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "listed", return_value=NONE), \
                patch.object(buy, "Page", return_value=self.top(*(r for _, r in ROWS.values()))), \
                patch.object(buy, "Screen", side_effect=[
                    self.screen("double-press"), self.screen(None), self.screen(None)]):
            self.assertFalse(self.follow())
        self.assertTrue(any("bundle's button reads" in line and "nothing was bought" in line
                            for line in self.messages))

    def test_closed_sheet_with_an_app_downloading_is_no_cancel(self):
        with patch.object(buy, "ipad_locked", return_value=False), \
                patch.object(buy, "listed", return_value={"com.example.synth"}), \
                patch.object(buy, "Page", return_value=self.top(("downloading", "Wird geladen"),
                                                                 ROWS["1000000002"][1])), \
                patch.object(buy, "Screen", side_effect=[self.screen("double-press")]
                             + [self.screen(None)] * 10):
            self.assertFalse(self.follow(timeout=15))
        self.assertFalse(any("nothing was bought" in line for line in self.messages))
        self.assertTrue(any("timed out" in line for line in self.messages))


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
