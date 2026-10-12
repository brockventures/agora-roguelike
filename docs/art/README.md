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

Steam store capsules for #29 (Steam store assets). Design approved by Ryan on 2026-10-12: the working title "Agora Station", a trading ship whose engine trail is an orbital arc of candlesticks, and the dying Sun with the Stabiliser ring floating clear of it.

- `art/store/keyart-source.png` is the raw Gemini take.
- `art/store/keyart.png` is the same image with the mottled sky smoothed by `tools/art/clean_background.py`.
- `tools/art/make_capsules.py` crops `keyart.png` to each size in `game/data/store_assets.json` and writes `art/store/capsules-sheet.png` for review. It sets the two-line title ("AGORA" over a tracked-out "STATION", Archivo, bone cream) at the largest size that clears the art. The page background and library hero carry no text.

Regenerate:

```
python3 tools/art/clean_background.py art/store/keyart-source.png art/store/keyart.png
python3 tools/art/make_capsules.py
```

Key art prompt (Gemini, 16:9, built from two earlier takes as references: the money-trail ship scene and the orbital candlestick scene):

> Match the flat cel-shaded illustration style of the reference images exactly. Absolutely no text, letters, numbers, logos, currency symbols or UI anywhere. Leave the left third of the frame calm, dark deep space for a title. Recreate the first reference image's composition exactly: same ship, same position lower right, same candlestick trail arcing away in an orbital path and fading to transparent, same free-floating half-built scaffolding ring well clear of the Sun, same whole Sun fully in frame upper right. Change only the Sun: render it in the style of the second reference image's Sun, with a ragged flaring fiery corona edge with small flame licks around the limb, deeper amber-orange, and bold black cracked veins and charred necrotic patches across the surface. The ring must stay separated from the Sun by a band of empty black space all the way around.
