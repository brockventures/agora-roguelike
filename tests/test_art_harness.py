"""Art harness (#73 Epic 6, sub-task 6.2): filter, sample gate, dry-run, manifest,
border sweep. No network: the Gemini client is mocked."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("art_generate", ROOT / "tools" / "art" / "generate.py")
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None


def args(batch, out, sample=False, ids=None, dry_run=False):
    return SimpleNamespace(batch=batch, out=str(out), sample=sample, ids=ids,
                           dry_run=dry_run, model="test-model")


def png_bytes(size, border=0, color=(200, 60, 30)):
    img = Image.new("RGB", size, (255, 255, 255))
    inner = Image.new("RGB", (size[0] - 2 * border, size[1] - 2 * border), color)
    img.paste(inner, (border, border))
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


class FakeClient:
    def __init__(self, size=(400, 400), border=10):
        self.calls = []
        self.size, self.border = size, border

    def generate(self, prompt, aspect, seed):
        self.calls.append((prompt, aspect, seed))
        aw, ah = (int(x) for x in aspect.split(":"))
        inner = (self.size[0], round(self.size[0] * ah / aw))
        return png_bytes((inner[0] + 2 * self.border, inner[1] + 2 * self.border), self.border)


class BibleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bible = G.load_bible()
        cls.banned = G.load_banned()

    def test_counts_and_cards_are_4x3(self):
        by = {b: [e for e in self.bible["entries"].values() if e["batch"] == b] for b in G.BATCHES}
        self.assertEqual(len([e for e in by["6.5"]]), 12)
        self.assertTrue(all(e["aspect"] == "4:3" for e in by["6.5"]))
        self.assertEqual(len([e for e in by["6.4"] if e["id"].startswith("hull-")]), 5)
        for st in ("earth", "luna", "mars", "ceres"):
            self.assertIn(f"station-{st}", self.bible["entries"])

    def test_every_bible_prompt_passes_the_filter(self):
        for e in self.bible["entries"].values():
            checked, _ = G.build_prompt(self.bible, e)
            G.check_prompt(checked, self.banned)

    def test_sample_ids_match_issue_73(self):
        picked = lambda b: sorted(e["id"] for e in G.select(self.bible, b, sample=True))
        self.assertEqual(picked("6.3"), ["station-earth", "station-mars"])
        self.assertEqual(picked("6.4"), ["hull-hauler"])
        self.assertEqual(picked("6.5"), ["card-antitrust-audit", "card-cme-flare"])

    def test_ids_restrict_and_unknown_id_refused(self):
        sel = G.select(self.bible, "6.3", ids=["station-luna"])
        self.assertEqual([e["id"] for e in sel], ["station-luna"])
        with self.assertRaises(G.HarnessError):
            G.select(self.bible, "6.3", ids=["hull-hauler"])

    def test_crisis_cards_cite_real_crisis_ids(self):
        crises = {c["id"] for c in json.load(open(ROOT / "game/data/crises.json"))["crises"]}
        cited = [e["source"] for e in self.bible["entries"].values()
                 if e["batch"] == "6.5" and e["source"] in crises]
        self.assertGreaterEqual(len(cited), 9)


class FilterTests(unittest.TestCase):
    def setUp(self):
        self.banned = G.load_banned()

    def test_refuses_brand_and_influence(self):
        for bad in ("a ship in the style of Luke Humphris", "NASA logo on the hull",
                    "a Star Wars cantina", "signed by the artist"):
            with self.assertRaises(G.HarnessError, msg=bad):
                G.check_prompt(bad, self.banned)

    def test_word_boundaries_do_not_overmatch(self):
        G.check_prompt("a fordable river and a dunes-free plain, pineapple crates", self.banned)

    def test_refused_prompt_stops_run_before_any_api_call(self):
        bible = {"style": "s", "negative": "n", "entries": {"x": {
            "id": "x", "batch": "6.3", "aspect": "1:1", "sample": True,
            "prompt": "a hull with a Tesla logo", "source": ""}}}
        client = FakeClient()
        with tempfile.TemporaryDirectory() as d, self.assertRaises(G.HarnessError):
            G.run(args("6.3", d, sample=True), client=client, bible=bible, banned=self.banned)
        self.assertEqual(client.calls, [])

    def test_final_prompt_enforces_text_free(self):
        bible = G.load_bible()
        _, final = G.build_prompt(bible, bible["entries"]["station-earth"])
        self.assertIn("no text of any kind", final)
        self.assertIn("Avoid:", final)


class DryRunTests(unittest.TestCase):
    def test_dry_run_prints_prompts_and_makes_no_call_or_files(self):
        client = FakeClient()
        buf = io.StringIO()
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(buf):
            G.run(args("6.3", d, sample=True, dry_run=True), client=client)
            self.assertFalse(any(Path(d).iterdir()))
        out = buf.getvalue()
        self.assertIn("station-earth", out)
        self.assertIn("station-mars", out)
        self.assertNotIn("station-luna", out)
        self.assertEqual(client.calls, [])

    def test_cli_dry_run_exit_zero(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = G.main(["--batch", "6.5", "--sample", "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("card-cme-flare", buf.getvalue())


@unittest.skipIf(Image is None, "Pillow not installed: generation and sweep tests need it")
class GateAndManifestTests(unittest.TestCase):
    def test_full_run_refused_without_approved_samples(self):
        client = FakeClient()
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(G.HarnessError) as cm:
                G.run(args("6.3", d), client=client)
            self.assertIn("sample gate", str(cm.exception))
            self.assertEqual(client.calls, [])

    def test_sample_run_writes_manifest_pending(self):
        client = FakeClient()
        with tempfile.TemporaryDirectory() as d:
            G.run(args("6.3", d, sample=True), client=client)
            self.assertEqual(len(client.calls), 2)
            m = json.load(open(G.manifest_path(d, "6.3")))
            item = m["items"]["station-earth"]
            for key in ("id", "prompt_hash", "model", "params", "output", "review"):
                self.assertIn(key, item)
            self.assertEqual(item["review"], "pending")
            self.assertEqual(item["model"], "test-model")
            self.assertTrue(Path(item["output"]).exists())
            # still refused while pending
            with self.assertRaises(G.HarnessError):
                G.run(args("6.3", d), client=client)

    def test_full_run_proceeds_after_approval(self):
        client = FakeClient()
        with tempfile.TemporaryDirectory() as d:
            G.run(args("6.3", d, sample=True), client=client)
            m = json.load(open(G.manifest_path(d, "6.3")))
            for it in m["items"].values():
                it["review"] = "approved"
            G.save_manifest(d, "6.3", m)
            client.calls.clear()
            G.run(args("6.3", d), client=client)
            self.assertEqual(len(client.calls), 13)
            m = json.load(open(G.manifest_path(d, "6.3")))
            self.assertEqual(m["items"]["station-earth"]["review"], "approved")
            self.assertEqual(m["items"]["station-luna"]["review"], "pending")

    def test_changed_prompt_resets_review(self):
        client = FakeClient()
        with tempfile.TemporaryDirectory() as d:
            G.run(args("6.3", d, sample=True, ids=["station-earth"]), client=client)
            m = json.load(open(G.manifest_path(d, "6.3")))
            m["items"]["station-earth"]["review"] = "approved"
            m["items"]["station-earth"]["prompt_hash"] = "stale"
            G.save_manifest(d, "6.3", m)
            G.run(args("6.3", d, sample=True, ids=["station-earth"]), client=client)
            m = json.load(open(G.manifest_path(d, "6.3")))
            self.assertEqual(m["items"]["station-earth"]["review"], "pending")

    def test_missing_api_key_refused(self):
        import os
        old = os.environ.pop("GEMINI_API_KEY", None)
        try:
            with tempfile.TemporaryDirectory() as d, self.assertRaises(G.HarnessError):
                G.run(args("6.3", d, sample=True))
        finally:
            if old is not None:
                os.environ["GEMINI_API_KEY"] = old


@unittest.skipIf(Image is None, "Pillow not installed: border sweep needs it")
class SweepTests(unittest.TestCase):
    def test_trims_uniform_border(self):
        img = Image.open(io.BytesIO(png_bytes((420, 420), border=10)))
        out, rep = G.sweep_borders(img, "1:1")
        self.assertEqual(out.size, (400, 400))
        self.assertEqual(rep["original_size"], [420, 420])

    def test_card_is_cropped_to_exact_4x3(self):
        img = Image.open(io.BytesIO(png_bytes((830, 620), border=15)))  # 800x590 inner
        out, _ = G.sweep_borders(img, "4:3")
        w, h = out.size
        self.assertAlmostEqual(w / h, 4 / 3, places=2)

    def test_wrong_aspect_rejected(self):
        img = Image.open(io.BytesIO(png_bytes((400, 400))))
        with self.assertRaises(G.HarnessError):
            G.sweep_borders(img, "16:9")

    def test_flat_image_rejected(self):
        with self.assertRaises(G.HarnessError):
            G.sweep_borders(Image.new("RGB", (100, 100), (5, 5, 5)), "1:1")


if __name__ == "__main__":
    unittest.main()
