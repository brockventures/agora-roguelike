"""Generate game/tests/golden/draws/sample.json (shared Python/GDScript fixture).

Usage: python3 tools/golden/gen_sample_draws.py [out_dir]
Default out_dir: game/tests/golden/draws
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from record_draws import RecordingRandom  # noqa: E402

OUT = pathlib.Path(__file__).resolve().parents[2] / "game/tests/golden/draws/sample.json"


def main(out_dir=None):
    out = pathlib.Path(out_dir) / "sample.json" if out_dir else OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    r = RecordingRandom("bag-test-1")
    r.randint(1, 6)
    r.random()
    r.uniform(0.5, 2.5)
    r.choice(["mars", "ceres", "vesta"])
    r.randrange(0, 20, 5)
    r.gauss(0.0, 1.0)
    r.shuffle([10, 20, 30, 40, 50])
    r.randint(1, 100)
    r.dump(out)
    print(f"wrote {len(r.draws)} draws to {out}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
