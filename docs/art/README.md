# AGORA art pipeline

Part of #73 (Epic 6: Visual Identity & Art Asset Pipeline), sub-task 6.2. Prompts live in `prompt-bible.md`; the harness is `tools/art/generate.py`.

## Running it

Generation uses the Google Gemini image API only (house policy: no other image API). The key is read from `GEMINI_API_KEY` in the environment and never from a file in the repo. `pip install pillow` is needed for real runs.

```
# See the exact prompts, no API call, no files written:
python3 tools/art/generate.py --batch 6.3 --sample --dry-run

# Generate only the sample-gate pieces for a batch:
GEMINI_API_KEY=... python3 tools/art/generate.py --batch 6.3 --sample

# Full batch (refused until the samples are approved):
GEMINI_API_KEY=... python3 tools/art/generate.py --batch 6.3

# A subset, and a custom output directory:
python3 tools/art/generate.py --batch 6.5 --ids card-cme-flare --out /tmp/art
```

Flags: `--batch 6.3|6.4|6.5`, `--sample`, `--ids ...`, `--ref ANCHOR`, `--out DIR` (default `art_out/`, gitignored), `--dry-run`, `--model` (default `gemini-2.5-flash-image`, or `GEMINI_IMAGE_MODEL`).

Output goes to `<out>/batch-<n>/<id>.png` with a `manifest.json` beside it.

## Safeguards

- **Reference-image conditioning:** entries specifying `- ref: <anchor_id>` (or `--ref`) pass the approved canonical icon (e.g. `game/assets/map_icons/<anchor_id>_256.png`) as an input image part to Gemini alongside the prompt, ensuring viewports maintain landmark and silhouette fidelity across scales.
- **Banned terms:** `tools/art/banned_terms.txt` lists brands, franchises, marks, text requests and the two named influences. Any prompt containing a listed term (whole-word, case-insensitive) is refused before any call. Add terms there.
- **Text-free:** every final prompt carries a fixed no-text sentence and an `Avoid:` clause from the bible's negative block.
- **Border sweep:** after generation, uniform borders are trimmed and the image is cropped to the exact ratio. An image more than 15% off its ratio, or one the trim would shrink by half, is rejected. Cards are 4:3.

## Review flow (the sample gate)

1. Run `--sample` for the batch. Sample pieces are the ones #73 names: 6.3 Earth + Mars, 6.4 Hauler, 6.5 Audit + Flare. Each manifest entry starts as `"review": "pending"`.
2. Show the images to @brockventures. On sign-off, edit the entries in `manifest.json` to `"review": "approved"` (or `"rejected"`, then adjust the bible and regenerate).
3. A full run of that batch is refused until every sample piece is `approved`. Regenerating a piece with a changed prompt resets it to `pending`.
4. Approved art is committed by the 6.3 to 6.5 tasks, not by this harness.

Adding an asset: add a `###` entry to `prompt-bible.md` (id, batch, aspect, sample, [ref], source, prompt) and run `python3 -m unittest tests.test_art_harness`.

## Store capsules

Steam store capsules for #29 (Steam store assets) are built from one Gemini key-art take by `tools/art/make_capsules.py`. Regenerate the files and the review sheet with:

```
python3 tools/art/make_capsules.py
```

The script reads `art/store/keyart-raw-1.png`, crops and resizes it to each size in `game/data/store_assets.json`, overlays the "AGORA" wordmark and "ROGUELIKE" tagline (Archivo, bone cream and teal), and writes `art/store/capsules-sheet.png` for review. The page background and library hero carry no text.

Key art prompt (Gemini, 16:9, with `card_art/antitrust_audit.png` and `card_art/card_mars.png` as style references):

> Match the art style of the reference images exactly: flat cel-shaded illustration, uniform ink contours, flat graphic shadow cuts, mineral and rust palette with teal accents. Wide establishing shot of a corporate trading armada in orbit above a rust-red Mars, a cargo freighter in the foreground right, a ring of orbital trading platforms with glowing ticker-board panels, a distant small Sun at upper left. Leave the left third of the frame calm and dark (deep space) for a title. Absolutely no text, letters, numbers, logos or UI anywhere.

These capsules are SAMPLES pending design approval. Do not upload them to Steamworks until the design is signed off.
