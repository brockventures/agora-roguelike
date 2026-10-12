#!/usr/bin/env python3
"""Build the Steam store capsules from the approved key art (#29, Steam store assets).

Reads art/store/keyart.png (approved by Ryan 2026-10-12, or the --key given) and
the Archivo variable font, then writes the capsule PNGs and
art/store/capsules-sheet.png for review; see docs/art/README.md ("Store capsules").

Usage: python3 tools/art/make_capsules.py [--key PATH] [--out-suffix SUFFIX]
  --out-suffix SUFFIX  write <name><SUFFIX>.png and capsules-sheet<SUFFIX>.png
                       (e.g. -cargo), so variants do not overwrite each other.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "art" / "store"
FONT = ROOT / "game" / "assets" / "fonts" / "Archivo-VF.ttf"
DEFAULT_KEY = STORE / "keyart.png"

BONE = (0xE6, 0xDC, 0xC3)
INK = (0x1A, 0x14, 0x10)
SHEET_BG = (0x0F, 0x0D, 0x0B)
WEIGHT = 700
WORD = "SHORT"
WORD2 = "THE SUN"  # title "Short the Sun" (Ryan, 2026-10-12); second line, tracked to the first line's width

# name -> (width, height, layout, wordmark height fraction)
# layout: "left" (left third, vertically centered) | "top" (centered, top third)
#         "bg" (no text) | "hero" (no text)
SPECS = [
    ("header_capsule", 920, 430, "left", 0.22),
    ("small_capsule", 462, 174, "left", 0.45),
    ("main_capsule", 1232, 706, "left", 0.22),
    ("vertical_capsule", 748, 896, "top", 0.22),
    ("page_background", 1438, 810, "bg", 0),
    ("library_capsule", 600, 900, "top", 0.22),
    ("library_hero", 3840, 1240, "hero", 0),
]


def load_font(size):
    font = ImageFont.truetype(str(FONT), size)
    try:
        values = []
        for axis in font.get_variation_axes():
            name = axis.get("name", b"")
            name = name.decode() if isinstance(name, bytes) else str(name)
            if name.lower().startswith("weight"):
                values.append(min(max(WEIGHT, axis["minimum"]), axis["maximum"]))
            else:
                values.append(axis["default"])
        font.set_variation_by_axes(values)
    except (OSError, ValueError, KeyError, AttributeError):
        pass  # static fallback: render with the font's default weight
    return font


def render_text(text, size, fill, stroke_fill, stroke_w, tracking=0.0):
    """Return a tight RGBA layer of text with a stroke, ink bounds only."""
    font = load_font(size)
    track = tracking * size
    if track:
        advances = [font.getlength(ch) for ch in text]
        total = sum(advances) + track * (len(text) - 1)
    else:
        total = font.getlength(text)
    pad = size + 4 * stroke_w
    layer = Image.new("RGBA", (int(total) + 2 * pad, int(size * 2) + 2 * pad), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    if track:
        x = float(pad)
        for ch, adv in zip(text, advances):
            draw.text((x, pad), ch, font=font, fill=fill,
                      stroke_width=stroke_w, stroke_fill=stroke_fill)
            x += adv + track
    else:
        draw.text((pad, pad), text, font=font, fill=fill,
                  stroke_width=stroke_w, stroke_fill=stroke_fill)
    return layer.crop(layer.getbbox())


def fit_text(text, target_h, max_w, stroke_w, fill, stroke_fill, tracking=0.0):
    """Size text so its ink height is target_h, shrinking further if wider than max_w."""
    size = max(8, round(target_h / 0.72))
    layer = None
    for _ in range(6):
        layer = render_text(text, size, fill, stroke_fill, stroke_w, tracking)
        if layer.height == target_h:
            break
        size = max(8, round(size * target_h / layer.height))
    while layer.width > max_w and size > 8:
        size = max(8, min(size - 1, round(size * max_w / layer.width)))
        layer = render_text(text, size, fill, stroke_fill, stroke_w, tracking)
    return layer


def cover(img, w, h):
    """Center-crop to the target aspect, then resize with LANCZOS."""
    iw, ih = img.size
    target = w / h
    if iw / ih > target:
        cw, ch = round(ih * target), ih
    else:
        cw, ch = iw, round(iw / target)
    left, top = (iw - cw) // 2, (ih - ch) // 2
    return img.crop((left, top, left + cw, top + ch)).resize((w, h), Image.LANCZOS)


def compose(key, name, w, h, layout, wm_frac):
    base = cover(key, w, h).convert("RGBA")
    if layout in ("bg", "hero"):
        if layout == "bg":
            shade = Image.new("RGB", base.size, (153, 153, 153))  # multiply by 0.6 = darken 40%
            base = ImageChops.multiply(base.convert("RGB"), shade).convert("RGBA")
        return base

    scale = h / 706  # stroke is 2-3 px at the main capsule height, scaled up or down
    stroke_w = max(2, round(2.5 * scale))
    busy = busy_mask(base)
    best = None
    # Largest title first; for each size, the first clear spot wins. A spot is clear
    # when no art detail (ship, candles, Sun, ring) sits under the padded title box.
    for shrink in (1.0, 0.92, 0.85, 0.78, 0.72, 0.66, 0.6):
        wm_target = round(h * wm_frac * shrink)
        max_w = round(w * (0.34 if layout == "left" else 0.80) * shrink)
        block = title_block(wm_target, max_w, stroke_w)
        bw, bh = block.size
        pad = max(6, round(bh * 0.12))
        if layout == "left":
            xs = [round(w * f) for f in (0.07, 0.06, 0.05, 0.08)]
            ys = [(h - bh) // 2] + [round(h * f) for f in (0.40, 0.35, 0.30, 0.25, 0.20, 0.15, 0.10, 0.45, 0.50, 0.55)]
        else:
            xs = [(w - bw) // 2] + [round(w * f) for f in (0.07, 0.05)]
            ys = [round(h * f) for f in (0.12, 0.08, 0.05, 0.16, 0.20)]
        for y in ys:
            for x in xs:
                if x + bw > w or y + bh > h or y < 0:
                    continue
                hit = busy.crop((max(0, x - pad), max(0, y - pad), min(w, x + bw + pad), min(h, y + bh + pad)))
                score = sum(hit.histogram()[1:])
                if best is None or score < best[0]:
                    best = (score, block, x, y)
                if score == 0:
                    break
            if best[0] == 0:
                break
        if best[0] == 0:
            break
    _, block, wm_x, top = best
    base.alpha_composite(block, (wm_x, top))
    return base


def busy_mask(img):
    """1 where the art has detail (edges, bright subjects), 0 on flat sky."""
    gray = img.convert("L")
    smooth = gray.filter(ImageFilter.GaussianBlur(12))
    diff = ImageChops.difference(gray, smooth).point(lambda v: 255 if v > 10 else 0)
    bright = gray.point(lambda v: 255 if v > 80 else 0)
    return ImageChops.lighter(diff, bright).filter(ImageFilter.MaxFilter(5))


def title_block(wm_target, max_w, stroke_w):
    """SHORT over a tracked-out THE SUN, both lines the same width."""
    wordmark = fit_text(WORD, wm_target, max_w, stroke_w, BONE, INK)
    if not WORD2:
        return wordmark
    line2_h = max(8, round(wm_target * 0.34))
    line2 = fit_text(WORD2, line2_h, wordmark.width, stroke_w, BONE, INK, tracking=0.32)
    if line2.width < wordmark.width:  # stretch tracking so both lines share one width
        extra = (wordmark.width - line2.width) / (len(WORD2) - 1)
        size = round(line2_h / 0.72)
        line2 = render_text(WORD2, size, BONE, INK, stroke_w, 0.32 + extra / size)
    gap = max(4, round(wm_target * 0.16))
    block = Image.new("RGBA", (max(wordmark.width, line2.width), wordmark.height + gap + line2.height), (0, 0, 0, 0))
    block.alpha_composite(wordmark, (0, 0))
    block.alpha_composite(line2, ((block.width - line2.width) // 2, wordmark.height + gap))
    return block


def build_sheet(items, out_path):
    """Grid of every capsule scaled to fit a cell, each labelled with file and pixel size."""
    cols, cell_w, cell_h, gap, margin = 2, 760, 440, 40, 40
    label_font = load_font(22)
    rows = (len(items) + cols - 1) // cols
    canvas_w = margin * 2 + cols * cell_w + (cols - 1) * gap
    canvas_h = margin * 2 + rows * (cell_h + 46) + (rows - 1) * gap
    sheet = Image.new("RGB", (canvas_w, canvas_h), SHEET_BG)
    draw = ImageDraw.Draw(sheet)
    for i, (name, img) in enumerate(items):
        r, c = divmod(i, cols)
        cx = margin + c * (cell_w + gap)
        cy = margin + r * (cell_h + 46 + gap)
        scale = min(cell_w / img.width, cell_h / img.height)
        tw, th = round(img.width * scale), round(img.height * scale)
        sheet.paste(img.convert("RGB").resize((tw, th), Image.LANCZOS),
                    (cx + (cell_w - tw) // 2, cy + (cell_h - th) // 2))
        label = f"{name}.png  {img.width}x{img.height}"
        draw.text((cx, cy + cell_h + 10), label, font=label_font, fill=BONE)
    sheet.save(out_path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--key", default=str(DEFAULT_KEY), help="key art PNG (16:9)")
    parser.add_argument("--out-suffix", default="",
                        help="suffix for output names: <name><suffix>.png, capsules-sheet<suffix>.png")
    args = parser.parse_args()

    STORE.mkdir(parents=True, exist_ok=True)
    key = Image.open(args.key).convert("RGB")
    items = []
    for name, w, h, layout, wm_frac in SPECS:
        img = compose(key, name, w, h, layout, wm_frac)
        out = STORE / f"{name}{args.out_suffix}.png"
        img.save(out)
        items.append((name, img))
        print(f"wrote {out.relative_to(ROOT)} {img.width}x{img.height}")
    sheet = STORE / f"capsules-sheet{args.out_suffix}.png"
    build_sheet(items, sheet)
    print(f"wrote {sheet.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
