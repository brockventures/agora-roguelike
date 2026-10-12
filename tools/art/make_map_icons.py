#!/usr/bin/env python3
"""Builds the small map icons for the Sol tactical map (#73 Visual Identity & Art Asset Pipeline).

Reads the generated 1:1 illustrations (batch 6.3: station-*.png, body-sol.png), flood-fills the
dark background in from the corners to transparent, also keys enclosed background pockets (regions
the corner fill cannot reach, e.g. between gantry beams) when they are big enough that they are
not a thin ink line or small shadow, blurs the edge
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
POCKET_MIN_AREA = 400  # enclosed background-coloured regions at least this many px (of 512x512) are keyed
POCKET_MEAN_DIST = 7   # ...and only when their mean colour is this close to the backdrop (a plate behind a rig is
                       # 1-6 away; dark art inside the subject, e.g. Earth ocean or Mars basins, is 7+ away)
WINDOW_INNER = 0.44  # fraction of the half-width kept fully opaque
WINDOW_OUTER = 0.50  # fully transparent beyond this
MARGIN = 0.05     # empty border kept around the subject after the crop


def _window(size: int) -> Image.Image:
    """Soft circular alpha window: 255 inside WINDOW_INNER, fading to 0 at WINDOW_OUTER."""
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse([size * (0.5 - WINDOW_INNER), size * (0.5 - WINDOW_INNER),
                               size * (0.5 + WINDOW_INNER), size * (0.5 + WINDOW_INNER)], fill=255)
    return m.filter(ImageFilter.GaussianBlur(size * (WINDOW_OUTER - WINDOW_INNER) / 2.0))


def _mean_dist(px: bytes, comp: list, corner: tuple) -> float:
    """Euclidean distance between the region's mean RGB and the backdrop colour."""
    n = len(comp)
    mean = [sum(px[3 * i + c] for i in comp) / n for c in range(3)]
    return sum((mean[c] - corner[c]) ** 2 for c in range(3)) ** 0.5


def _pockets(im: Image.Image, is_bg: Image.Image, corner: tuple) -> Image.Image:
    """Mask (255 = key) of enclosed regions within KEY_THRESH of the corner background colour that the
    corner flood fill never reached and whose connected area is >= POCKET_MIN_AREA. 4-connected,
    row-major scan, so deterministic."""
    w, h = im.size
    close = None
    for band, c in zip(im.split(), corner):
        d = band.point(lambda v, c=c: 255 if abs(v - c) <= KEY_THRESH else 0)
        close = d if close is None else ImageChops.multiply(close, d)
    px = im.tobytes()
    cand = bytearray(close.tobytes())
    bg = is_bg.tobytes()
    for i in range(w * h):
        if bg[i]:
            cand[i] = 0
    seen = bytearray(w * h)
    out = bytearray(w * h)
    for start in range(w * h):
        if not cand[start] or seen[start]:
            continue
        comp = [start]
        seen[start] = 1
        k = 0
        while k < len(comp):
            i = comp[k]
            k += 1
            x = i % w
            for j in ((i - w) if i >= w else -1, (i + w) if i + w < w * h else -1,
                      (i - 1) if x > 0 else -1, (i + 1) if x < w - 1 else -1):
                if j >= 0 and cand[j] and not seen[j]:
                    seen[j] = 1
                    comp.append(j)
        if len(comp) >= POCKET_MIN_AREA and _mean_dist(px, comp, corner) <= POCKET_MEAN_DIST:
            for i in comp:
                out[i] = 255
    return Image.frombytes("L", (w, h), bytes(out))


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
    corner = tuple(round(sum(im.getpixel(p)[c] for p in ((0, 0), (WORK - 1, 0), (0, WORK - 1), (WORK - 1, WORK - 1))) / 4)
                   for c in range(3))
    is_bg = ImageChops.lighter(is_bg, _pockets(im, is_bg, corner))
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


VESSEL_ICONS = {"hauler": "icon-hauler", "interceptor": "icon-interceptor",
                "freighter": "icon-freighter", "scout": "icon-scout",
                "scrap_barge": "icon-scrap_barge"}
VESSEL_SAMPLES = ROOT / "docs" / "screens" / "vessel-samples"


def _clean_alpha(alpha: Image.Image, min_area: int = 100) -> Image.Image:
    """Removes small isolated alpha speckles/islands (less than min_area pixels)."""
    w, h = alpha.size
    px = bytearray(alpha.tobytes())
    seen = bytearray(w * h)
    for start in range(w * h):
        if px[start] <= 60 or seen[start]:
            continue
        comp = [start]
        seen[start] = 1
        k = 0
        while k < len(comp):
            i = comp[k]
            k += 1
            x = i % w
            for j in ((i - w) if i >= w else -1, (i + w) if i + w < w * h else -1,
                      (i - 1) if x > 0 else -1, (i + 1) if x < w - 1 else -1):
                if j >= 0 and px[j] > 60 and not seen[j]:
                    seen[j] = 1
                    comp.append(j)
        if len(comp) < min_area:
            for i in comp:
                px[i] = 0
    return Image.frombytes("L", (w, h), bytes(px))


def build_vessel(src: Path, work_size: int = 1024) -> Image.Image:
    """Keys out plain flat pale paper background from a 1:1 vessel transit marker illustration,
    cleans stray alpha speckles, and fits to the subject bounding box."""
    im = Image.open(src).convert("RGB").resize((work_size, work_size), Image.LANCZOS)
    key = im.copy()
    w, h = work_size, work_size
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
                 (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)):
        ImageDraw.floodfill(key, seed, (255, 0, 255), thresh=KEY_THRESH)
    r, g, b = key.split()
    is_bg = ImageChops.multiply(ImageChops.multiply(r.point(lambda v: 255 if v == 255 else 0),
                                                    g.point(lambda v: 255 if v == 0 else 0)),
                                b.point(lambda v: 255 if v == 255 else 0))
    corner = tuple(round(sum(im.getpixel(p)[c] for p in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))) / 4)
                   for c in range(3))
    is_bg = ImageChops.lighter(is_bg, _pockets(im, is_bg, corner))
    alpha = ImageChops.invert(is_bg).filter(ImageFilter.GaussianBlur(1.2))
    alpha = _clean_alpha(alpha, min_area=100)
    out = im.convert("RGBA")
    out.putalpha(alpha)
    fitted = _fit(out)
    return fitted.resize((work_size, work_size), Image.LANCZOS)


def main() -> None:
    src_dir = Path(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ROOT / "art_out" / "batch-6.3"
    do_vessels = "--vessels" in sys.argv or "--all" in sys.argv
    do_stations = "--stations" in sys.argv or "--all" in sys.argv or not do_vessels

    if do_stations:
        OUT.mkdir(parents=True, exist_ok=True)
        for name, stem in ICONS.items():
            src = src_dir / f"{stem}.png"
            if not src.exists():
                continue
            big = build(src)
            for s in SIZES:
                big.resize((s, s), Image.LANCZOS).save(OUT / f"{name}_{s}.png", optimize=True)
                print("wrote", OUT / f"{name}_{s}.png")

    if do_vessels:
        vessel_src_dir = Path(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ROOT / "art_out" / "batch-6.4"
        VESSEL_SAMPLES.mkdir(parents=True, exist_ok=True)
        OUT.mkdir(parents=True, exist_ok=True)
        for name, stem in VESSEL_ICONS.items():
            src = vessel_src_dir / f"{stem}.png"
            if not src.exists():
                src = VESSEL_SAMPLES / f"{stem}.png"
            if not src.exists():
                continue
            fitted = build_vessel(src, work_size=1024)
            fitted.save(VESSEL_SAMPLES / f"{stem}.png", optimize=True)
            print("wrote vessel sample", VESSEL_SAMPLES / f"{stem}.png")
            for s in SIZES:
                fitted.resize((s, s), Image.LANCZOS).save(OUT / f"vessel_{name}_{s}.png", optimize=True)
                print("wrote", OUT / f"vessel_{name}_{s}.png")


if __name__ == "__main__":
    main()
