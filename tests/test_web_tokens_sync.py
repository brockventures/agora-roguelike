"""The deploy serves only public/, so the design-system tokens are copied into
public/css/tokens/. Fail if a copy drifts from docs/design-system/tokens/, or if
a page stops linking the shared stylesheet or pulls in a font CDN the design
system does not already use."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "design-system" / "tokens"
DST = ROOT / "public" / "css" / "tokens"
PAGES = ["index", "terminal", "orrery", "orrery-3d", "documentation", "patch-notes"]


class WebTokensSync(unittest.TestCase):
    def test_every_source_token_file_is_copied_verbatim(self):
        sources = sorted(SRC.glob("*.css"))
        self.assertTrue(sources)
        for src in sources:
            dst = DST / src.name
            self.assertTrue(dst.exists(), f"{dst} missing: run cp docs/design-system/tokens/*.css public/css/tokens/")
            self.assertEqual(src.read_bytes(), dst.read_bytes(), f"{src.name} drifted from the design-system source")

    def test_agora_css_imports_every_token_file(self):
        css = (ROOT / "public" / "css" / "agora.css").read_text(encoding="utf-8")
        for src in SRC.glob("*.css"):
            self.assertIn(f'@import "tokens/{src.name}"', css)

    def test_pages_link_shared_stylesheet_and_no_new_font_cdn(self):
        for name in PAGES:
            html = (ROOT / "public" / f"{name}.html").read_text(encoding="utf-8")
            self.assertIn('href="/css/agora.css"', html, name)
            self.assertNotIn("JetBrains", html, name)
            for host in re.findall(r"https?://(fonts\.[a-z.]+|[a-z.]*cdn[a-z.]*)", html):
                self.fail(f"{name}: unexpected CDN {host}")


if __name__ == "__main__":
    unittest.main()
