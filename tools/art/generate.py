#!/usr/bin/env python3
"""AGORA art generation harness (#73 Epic 6, sub-task 6.2).

Generates raster art through the Google Gemini image API only (house policy:
no other image API). Reads GEMINI_API_KEY from the environment, never a file.

    python3 tools/art/generate.py --batch 6.3 --sample --dry-run
    python3 tools/art/generate.py --batch 6.3 --sample          # real call
    python3 tools/art/generate.py --batch 6.3                   # needs approval

Prompts live in docs/art/prompt-bible.md. See docs/art/README.md.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIBLE_PATH = ROOT / "docs" / "art" / "prompt-bible.md"
BANNED_PATH = Path(__file__).resolve().with_name("banned_terms.txt")
DEFAULT_OUT = ROOT / "art_out"
DEFAULT_MODEL = "gemini-2.5-flash-image"
API_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
BATCHES = ("6.3", "6.4", "6.5")
CARD_BATCH = "6.5"
REVIEW_STATES = ("pending", "approved", "rejected")
ASPECT_TOLERANCE = 0.02

TEXT_FREE = ("The image contains absolutely no text of any kind: no letters, words, numbers, "
             "symbols that read as writing, captions, signs, logos or signatures.")


class HarnessError(Exception):
    """Refusal or configuration error. The CLI prints it and exits non-zero."""


# ---------------------------------------------------------------- bible

def _block_after(text, heading):
    m = re.search(r"^## " + re.escape(heading) + r"\s*\n.*?```\n(.*?)\n```", text, re.S | re.M)
    if not m:
        raise HarnessError(f"prompt bible is missing the '{heading}' fenced block")
    return " ".join(m.group(1).split())


def load_bible(path=BIBLE_PATH):
    text = Path(path).read_text(encoding="utf-8")
    bible = {"style": _block_after(text, "Style block"),
             "negative": _block_after(text, "Negative prompt block"),
             "entries": {}}
    for m in re.finditer(r"^### (\S+)\n((?:- .*\n?)+)", text, re.M):
        fields = dict(re.findall(r"^- (\w+): (.*)$", m.group(2), re.M))
        missing = {"batch", "aspect", "sample", "prompt"} - set(fields)
        if missing:
            raise HarnessError(f"entry {m.group(1)} is missing {sorted(missing)}")
        eid = m.group(1)
        entry = {"id": eid, "batch": fields["batch"], "aspect": fields["aspect"],
                 "sample": fields["sample"].strip().lower() == "yes",
                 "prompt": fields["prompt"].strip(), "source": fields.get("source", ""),
                 "ref": fields.get("ref", "").strip()}
        if entry["batch"] == CARD_BATCH and entry["aspect"] != "4:3":
            raise HarnessError(f"entry {eid}: cards must be 4:3, got {entry['aspect']}")
        if eid in bible["entries"]:
            raise HarnessError(f"duplicate entry id {eid}")
        bible["entries"][eid] = entry
    return bible


def resolve_reference(ref, root=ROOT):
    """Resolve a reference string or anchor ID to an existing image Path.

    Accepts:
    - An anchor ID, e.g. 'earth' -> game/assets/map_icons/earth_256.png
    - A station ID, e.g. 'station-earth' -> game/assets/map_icons/earth_256.png
    - A direct relative path from repo root
    - An art_out batch reference
    """
    if not ref:
        return None
    ref_str = str(ref).strip()
    candidates = [
        root / "game" / "assets" / "map_icons" / f"{ref_str}_256.png",
    ]
    if ref_str.startswith("station-"):
        short = ref_str[len("station-"):]
        candidates.append(root / "game" / "assets" / "map_icons" / f"{short}_256.png")
    candidates.extend([
        root / ref_str,
        root / "game" / "assets" / "card_art" / f"{ref_str}.png",
        root / "docs" / "screens" / "vessel-samples" / f"{ref_str}.png",
        root / "game" / "assets" / "map_icons" / f"{ref_str}.png",
        root / "art_out" / f"{ref_str}.png",
        root / "art_out" / "batch-6.3" / f"{ref_str}.png",
        root / "art_out" / "batch-6.4" / f"{ref_str}.png",
        root / "art_out" / "batch-6.5" / f"{ref_str}.png",
    ])
    for cand in candidates:
        if cand.is_file():
            return cand
    raise HarnessError(f"reference image not found for ref '{ref_str}'")


# ---------------------------------------------------------------- filter

def load_banned(path=BANNED_PATH):
    terms = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            terms.append(line.lower())
    return terms


def find_banned(text, terms):
    low = text.lower()
    hits = []
    for t in terms:
        if re.search(r"(?<![\w])" + re.escape(t) + r"(?![\w])", low):
            hits.append(t)
    return hits


def check_prompt(text, terms):
    hits = find_banned(text, terms)
    if hits:
        raise HarnessError(f"refused: banned term(s) in prompt: {', '.join(hits)}")


def build_prompt(bible, entry):
    """Return (checked, final). `checked` is style + entry, the text the banned-term
    filter scans; `final` adds the fixed text-free sentence and the Avoid clause,
    which deliberately name words like logo and signature in order to forbid them."""
    checked = f"{bible['style']}\n\n{entry['prompt']}"
    return checked, f"{checked}\n\n{TEXT_FREE}\n\nAvoid: {bible['negative']}."


# ---------------------------------------------------------------- selection

def select(bible, batch, sample=False, ids=None):
    entries = [e for e in bible["entries"].values() if e["batch"] == batch]
    if not entries:
        raise HarnessError(f"no entries for batch {batch}")
    if sample:
        entries = [e for e in entries if e["sample"]]
    if ids:
        known = {e["id"] for e in entries}
        unknown = [i for i in ids if i not in known]
        if unknown:
            raise HarnessError(f"ids not in selection for batch {batch}: {', '.join(unknown)}")
        entries = [e for e in entries if e["id"] in ids]
    return entries


# ---------------------------------------------------------------- manifest

def manifest_path(out, batch):
    return Path(out) / f"batch-{batch}" / "manifest.json"


def load_manifest(out, batch):
    p = manifest_path(out, batch)
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    return {"batch": batch, "items": {}}


def save_manifest(out, batch, manifest):
    p = manifest_path(out, batch)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def check_gate(bible, batch, selected, manifest):
    """A run that includes any non-sample piece needs every sample piece approved."""
    if all(e["sample"] for e in selected):
        return
    pending = []
    for e in bible["entries"].values():
        if e["batch"] == batch and e["sample"]:
            item = manifest["items"].get(e["id"])
            if not item or item.get("review") != "approved":
                pending.append(e["id"])
    if pending:
        raise HarnessError(
            f"sample gate: batch {batch} sample piece(s) not approved: {', '.join(pending)}. "
            f"Generate with --sample, then set review to 'approved' in the manifest after sign-off.")


# ---------------------------------------------------------------- image post-processing

def sweep_borders(img, aspect, tol=12):
    """Trim uniform borders, then center-crop to the target aspect.

    Returns (image, report). Raises HarnessError if trimming leaves too little
    or the aspect is more than 15% off before cropping.
    """
    from PIL import Image, ImageChops
    rgb = img.convert("RGB")
    bg = Image.new("RGB", rgb.size, rgb.getpixel((0, 0)))
    diff = ImageChops.difference(rgb, bg).convert("L").point(lambda v: 255 if v > tol else 0)
    box = diff.getbbox()
    original = rgb.size
    if box is None:
        raise HarnessError("border sweep: image is a single flat color")
    out = rgb.crop(box)
    aw, ah = (int(x) for x in aspect.split(":"))
    target = aw / ah
    orig_drift = abs(original[0] / original[1] - target) / target
    if out.size[0] < original[0] * 0.5 or out.size[1] < original[1] * 0.5:
        if orig_drift <= ASPECT_TOLERANCE:
            return rgb, {"original_size": list(original), "final_size": list(original), "trim_box": [0, 0, original[0], original[1]]}
        raise HarnessError("border sweep: trimmed more than half the image, rejecting")
    w, h = out.size
    drift = abs(w / h - target) / target
    if drift > 0.15:
        if orig_drift <= ASPECT_TOLERANCE:
            return rgb, {"original_size": list(original), "final_size": list(original), "trim_box": [0, 0, original[0], original[1]]}
        raise HarnessError(f"aspect check: {w}x{h} is {drift:.0%} off {aspect}")
    if drift > ASPECT_TOLERANCE / 10:
        if w / h > target:
            nw = round(h * target)
            x0 = (w - nw) // 2
            out = out.crop((x0, 0, x0 + nw, h))
        else:
            nh = round(w / target)
            y0 = (h - nh) // 2
            out = out.crop((0, y0, w, y0 + nh))
    w, h = out.size
    if abs(w / h - target) / target > ASPECT_TOLERANCE:
        raise HarnessError(f"aspect check failed: {w}x{h} vs {aspect}")
    return out, {"original_size": list(original), "final_size": [w, h], "trim_box": list(box)}


# ---------------------------------------------------------------- API client

class GeminiClient:
    """Minimal Gemini image client (REST, stdlib only). The key comes from the
    environment only."""

    def __init__(self, api_key, model=DEFAULT_MODEL):
        self.api_key = api_key
        self.model = model

    def generate(self, prompt, aspect, seed, reference_image=None):
        parts = []
        if reference_image:
            ref_path = Path(reference_image)
            if not ref_path.exists():
                raise HarnessError(f"reference image file does not exist: {ref_path}")
            ref_bytes = ref_path.read_bytes()
            ref_b64 = base64.b64encode(ref_bytes).decode("utf-8")
            ref_mime = "image/png" if ref_path.suffix.lower() == ".png" else "image/jpeg"
            parts.append({
                "inlineData": {
                    "mimeType": ref_mime,
                    "data": ref_b64
                }
            })
        parts.append({"text": prompt})

        body = {"contents": [{"parts": parts}],
                "generationConfig": {"responseModalities": ["IMAGE"], "seed": seed,
                                     "imageConfig": {"aspectRatio": aspect}}}
        req = urllib.request.Request(
            API_URL.format(model=self.model), data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "x-goog-api-key": self.api_key})
        with urllib.request.urlopen(req, timeout=180) as r:
            data = json.load(r)
        for cand in data.get("candidates", []):
            for part in cand.get("content", {}).get("parts", []):
                inline = part.get("inlineData") or part.get("inline_data")
                if inline and inline.get("data"):
                    return base64.b64decode(inline["data"])
        raise HarnessError("Gemini returned no image (possibly blocked by safety filters)")


def client_from_env(model):
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not key:
        raise HarnessError("GEMINI_API_KEY is not set in the environment")
    return GeminiClient(key, model)


# ---------------------------------------------------------------- run

def prompt_hash(final_prompt, ref=""):
    content = f"{final_prompt}|ref:{ref}" if ref else final_prompt
    return hashlib.sha256(content.encode("utf-8")).hexdigest()[:16]


def seed_for(entry_id):
    return int(hashlib.sha256(entry_id.encode()).hexdigest()[:8], 16) % (2 ** 31)


def run(args, client=None, bible=None, banned=None):
    """Execute a request. Returns the list of final prompts (dry-run) or manifest items."""
    bible = bible or load_bible()
    banned = banned if banned is not None else load_banned()
    selected = select(bible, args.batch, args.sample, args.ids)
    prepared = []
    for e in selected:
        positive, final = build_prompt(bible, e)
        check_prompt(positive, banned)
        prepared.append((e, final))

    manifest = load_manifest(args.out, args.batch)
    if args.dry_run:
        for e, final in prepared:
            ref_id = getattr(args, "ref", None) or e.get("ref", "")
            ref_tag = f" | ref={ref_id}" if ref_id else ""
            print(f"=== {e['id']} | batch {e['batch']} | {e['aspect']} | sample={'yes' if e['sample'] else 'no'}{ref_tag} "
                  f"| hash {prompt_hash(final, ref_id)} ===\n{final}\n")
        try:
            check_gate(bible, args.batch, selected, manifest)
            print("[dry-run] sample gate: open for this selection. No API call made.")
        except HarnessError as exc:
            print(f"[dry-run] {exc}\n[dry-run] A real run of this selection would be refused. No API call made.")
        return prepared

    check_gate(bible, args.batch, selected, manifest)
    client = client or client_from_env(args.model)
    out_dir = Path(args.out) / f"batch-{args.batch}"
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for e, final in prepared:
        seed = seed_for(e["id"])
        ref_id = getattr(args, "ref", None) or e.get("ref", "")
        ref_path = resolve_reference(ref_id) if ref_id else None
        try:
            raw = client.generate(final, e["aspect"], seed, reference_image=ref_path)
        except TypeError:
            raw = client.generate(final, e["aspect"], seed)

        from PIL import Image
        import io
        img, report = sweep_borders(Image.open(io.BytesIO(raw)), e["aspect"])
        path = out_dir / f"{e['id']}.png"
        img.save(path)
        prev = manifest["items"].get(e["id"], {})
        curr_hash = prompt_hash(final, ref_id)
        item = {"id": e["id"], "batch": e["batch"], "aspect": e["aspect"], "sample": e["sample"],
                "prompt_hash": curr_hash, "model": args.model,
                "params": {"seed": seed, "aspect_ratio": e["aspect"]},
                "output": str(path), "sweep": report,
                "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                # A regenerated piece with a changed prompt or ref needs a fresh review.
                "review": prev.get("review", "pending") if prev.get("prompt_hash") == curr_hash else "pending"}
        if ref_id:
            item["ref"] = ref_id
            item["params"]["ref"] = ref_id
            item["reference_image"] = str(ref_path)
        manifest["items"][e["id"]] = item
        save_manifest(args.out, args.batch, manifest)
        results.append(item)
        print(f"wrote {path} (review: {item['review']})")
    return results


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="AGORA art generation harness (Gemini image API only).")
    p.add_argument("--batch", required=True, choices=BATCHES)
    p.add_argument("--sample", action="store_true", help="only the #73 sample-gate pieces")
    p.add_argument("--ids", nargs="+", help="restrict to these asset ids")
    p.add_argument("--ref", help="override or provide reference anchor image for conditioning")
    p.add_argument("--out", default=str(DEFAULT_OUT), help="output directory (default: art_out/)")
    p.add_argument("--model", default=os.environ.get("GEMINI_IMAGE_MODEL", DEFAULT_MODEL))
    p.add_argument("--dry-run", action="store_true", help="print final prompts, make no API call")
    return p.parse_args(argv)


def main(argv=None):
    try:
        run(parse_args(argv))
    except HarnessError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
