#!/usr/bin/env python3
"""Smooth the mottled deep-space background of a Gemini key art (#29, Steam store assets).

Gemini's dark gradients come back blotchy. This keeps every pixel that carries
detail (ship, candles, Sun, ring, stars) and replaces flat dark sky with a
heavily blurred copy of itself plus a 1-level dither, so the gradient is smooth
without banding. Pixels count as sky when they are dark and close to the local
blurred average; the mask is feathered so edges blend.

Usage: python3 tools/art/clean_background.py IN.png OUT.png [--lum 70] [--diff 7]
"""
import argparse

import numpy as np
from PIL import Image, ImageFilter


def _blur(arr, radius):
    """Smooth low-pass of a float HxW array: box-downsample by `radius`, then bicubic back up."""
    im = Image.fromarray(arr.astype(np.float32), mode="F")
    w, h = im.size
    small = im.resize((max(2, w // radius), max(2, h // radius)), Image.BOX)
    return np.asarray(small.resize((w, h), Image.BICUBIC))


def masked_blur(px, mask, radius):
    """Blur only the masked (sky) pixels, normalised, so bright detail never bleeds into the sky."""
    w = _blur(mask, radius) + 1e-4
    return np.stack([_blur(px[..., c] * mask, radius) / w for c in range(3)], axis=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--lum", type=float, default=70.0, help="max luminance treated as sky")
    ap.add_argument("--diff", type=float, default=7.0, help="max distance from local average treated as sky")
    a = ap.parse_args()

    img = Image.open(a.src).convert("RGB")
    px = np.asarray(img).astype(np.float32)
    local = np.asarray(img.filter(ImageFilter.GaussianBlur(6))).astype(np.float32)
    lum = px @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    dist = np.abs(px - local).max(axis=2)
    sky = ((lum < a.lum) & (dist < a.diff)).astype(np.float32)
    smooth = masked_blur(px, sky, 32)
    mask = np.asarray(Image.fromarray((sky * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(5))
                      .filter(ImageFilter.GaussianBlur(3))).astype(np.float32)[..., None] / 255.0

    rng = np.random.default_rng(29)
    dither = rng.uniform(-0.5, 0.5, size=px.shape[:2])[..., None].astype(np.float32)
    out = px * (1 - mask) + (smooth + dither) * mask
    Image.fromarray(np.clip(np.rint(out), 0, 255).astype(np.uint8)).save(a.dst)
    print(f"sky fraction {sky.mean():.2f} -> {a.dst}")


if __name__ == "__main__":
    main()
