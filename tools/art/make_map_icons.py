#!/usr/bin/env python3
"""Builds the small map icons for the Sol tactical map (#73 Visual Identity & Art Asset Pipeline).

Reads the generated 1:1 illustrations (batch 6.3: station-*.png, body-sol.png), flood-fills the
dark background in from the corners to transparent (enclosed ink outlines stay), blurs the edge
a touch, applies a soft circular window so stray stars vanish without hard-clipping the subject,
then downsamples to 128px and 256px (high DPI) into game/assets/map_icons/.

    python3 tools/art/make_map_icons.py [SRC_DIR]     # default: art_out/batch-6.3
Needs Pillow. Deterministic: same inputs give the same PNGs.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "game" / "assets" / "map_icons"
ICONS = {"earth": "station-earth", "luna": "station-luna", "mars": "station-mars",
         "ceres": "station-ceres", "sol": "body-sol"}
SIZES = (128, 256)
WORK = 512        # work resolution before the final downsample
KEY_THRESH = 34   # flood-fill colour tolerance against the corner background
WINDOW_INNER = 0.44  # fraction of the half-width kept fully opaque
WINDOW_OUTER = 0.50  # fully transparent beyond this
MARGIN = 0.05     # empty border kept around the subject after the crop


def _window(size: int) -> Image.Image:
    """Soft circular alpha window: 255 inside WINDOW_INNER, fading to 0 at WINDOW_OUTER."""
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse([size * (0.5 - WINDOW_INNER), size * (0.5 - WINDOW_INNER),
                               size * (0.5 + WINDOW_INNER), size * (0.5 + WINDOW_INNER)], fill=255)
    return m.filter(ImageFilter.GaussianBlur(size * (WINDOW_OUTER - WINDOW_INNER) / 2.0))


def build(src: Path) -> Image.Image:
    im = Image.open(src).convert("RGB").resize((WORK, WORK), Image.LANCZOS)
    key = im.copy()
    for seed in ((0, 0), (WORK - 1, 0), (0, WORK - 1), (WORK - 1, WORK - 1),
                 (WORK // 2, 0), (WORK // 2, WORK - 1), (0, WORK // 2), (WORK - 1, WORK // 2)):
        ImageDraw.floodfill(key, seed, (255, 0, 255), thresh=KEY_THRESH)
    r, g, b = key.split()
    is_bg = ImageChops.multiply(ImageChops.multiply(r.point(lambda v: 255 if v == 255 else 0),
                                                    g.point(lambda v: 255 if v == 0 else 0)),
                                b.point(lambda v: 255 if v == 255 else 0))
    alpha = ImageChops.invert(is_bg).filter(ImageFilter.GaussianBlur(1.2))
    alpha = ImageChops.multiply(alpha, _window(WORK))
    out = im.convert("RGBA")
    out.putalpha(alpha)
    return _fit(out)


def _fit(im: Image.Image) -> Image.Image:
    """Crops to the subject's bounding box (alpha > 60) and re-centres it on a square canvas with a
    small margin, so every icon fills its frame alike (the source art varies from 55% to 95%)."""
    box = im.getchannel("A").point(lambda v: 255 if v > 60 else 0).getbbox()
    cx, cy = (box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0
    half = max(box[2] - box[0], box[3] - box[1]) / 2.0 * (1.0 + MARGIN)
    return im.crop((round(cx - half), round(cy - half), round(cx + half), round(cy + half)))


def main() -> None:
    src_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "art_out" / "batch-6.3"
    OUT.mkdir(parents=True, exist_ok=True)
    for name, stem in ICONS.items():
        big = build(src_dir / f"{stem}.png")
        for s in SIZES:
            big.resize((s, s), Image.LANCZOS).save(OUT / f"{name}_{s}.png", optimize=True)
            print("wrote", OUT / f"{name}_{s}.png")


if __name__ == "__main__":
    main()
