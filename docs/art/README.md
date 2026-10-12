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

v2 key art (Ryan's feedback, #29): the Sun is larger in the background with the Stabiliser scaffolding built around it, and the focal point is a ship in the foreground. Three scene prompts share the style text below. Regenerate the raw takes with `python3 skills/image-gen/scripts/gen-image.py --manifest <manifest> <outdir>` (Gemini backend, 16:9, takes 2), then build each capsule set with:

```
python3 tools/art/make_capsules.py --key art/store/keyart-v2-cargo.png --out-suffix=-cargo
python3 tools/art/make_capsules.py --key art/store/keyart-v2-money.png --out-suffix=-money
python3 tools/art/make_capsules.py --key art/store/keyart-v2-candles.png --out-suffix=-candles
```

Style (all three): flat cel-shaded illustration, uniform ink contours, flat graphic shadow cuts, ochre (#c99a2e), bone (#e6dcc3), ink black (#1c1a17), slate (#2c353b) and teal (#4fb3a9) accents; a huge unstable flaring amber Sun in the upper right with a massive curved scaffolding arc (the Stabiliser) around about a third of its limb; the left third calm and dark for a title; no text, letters, numbers, logos or UI.

- cargo: a battered corporate cargo freighter in the foreground, three-quarter view, visibly crammed with trade goods (stacked containers, ore sacks, fuel drums and crates lashed to the hull).
- money: a sleek corporate trading ship in the foreground, three-quarter view, with a glittering stream of gold credit chips and coins pouring out of its engine exhaust.
- candles: a corporate trading ship in the foreground, three-quarter view, its engine trail stylized as a rising green and red candlestick chart.

The script reads `art/store/keyart-raw-1.png`, crops and resizes it to each size in `game/data/store_assets.json`, overlays the "AGORA" wordmark (Archivo, bone cream), and writes `art/store/capsules-sheet.png` for review. The page background and library hero carry no text.

Key art prompt (Gemini, 16:9, with `card_art/antitrust_audit.png` and `card_art/card_mars.png` as style references):

> Match the art style of the reference images exactly: flat cel-shaded illustration, uniform ink contours, flat graphic shadow cuts, mineral and rust palette with teal accents. Wide establishing shot of a corporate trading armada in orbit above a rust-red Mars, a cargo freighter in the foreground right, a ring of orbital trading platforms with glowing ticker-board panels, a distant small Sun at upper left. Leave the left third of the frame calm and dark (deep space) for a title. Absolutely no text, letters, numbers, logos or UI anywhere.

### v3 scene: orbital candlestick trail

Gemini, 16:9, references `art/store/keyart-v2-money.png` and `art/store/keyart-v2-candles.png`. Picks: `keyart-v3-orbit.png`, runner-up `keyart-v3-orbit-b.png`.

> Match the flat cel-shaded illustration style of the reference images exactly: uniform ink contours, flat graphic shadow cuts, ochre, bone, ink black, slate and teal palette. Absolutely no text, letters, numbers, logos, currency symbols or UI anywhere. Leave the left third of the frame calm, dark deep space for a title. Foreground lower right: the exact sleek teal, bone and rust-red trading starship from the first reference image, three-quarter view, large and in sharp focus. Its engine trail is a wide elliptical orbital arc of bold green and red financial candlestick bars with thin wicks that curves away from the ship and loops around the Sun in the distance, like a planet's orbit line: the candles nearest the ship are big, thick, saturated and crisp, and they shrink and fade to fully transparent as the orbit curves behind the Sun. Background upper right: a dying amber Sun, fully visible as a complete circle, about 40 percent of the frame height, its surface scarred with dark blackened veins, necrotic patches and cracked charcoal sunspot clusters. The Stabiliser megastructure: a separate thin skeletal scaffolding ring, half-built with missing segments, floating far out from the Sun like a planetary ring seen at an angle. Its radius is about 1.6 times the Sun's radius, so a thick band of empty black space separates the ring from the Sun on every side; the ring never touches, crosses or overlaps the solar disc.

```
python3 tools/art/make_capsules.py --key art/store/keyart-v3-orbit.png --out-suffix=-v3
python3 tools/art/make_capsules.py --key art/store/keyart-v3-orbit-b.png --out-suffix=-v3b
```

These capsules are SAMPLES pending design approval. Do not upload them to Steamworks until the design is signed off.
