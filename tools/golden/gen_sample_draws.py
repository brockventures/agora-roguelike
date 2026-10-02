"""Generate game/tests/golden/draws/sample.json (shared Python/GDScript fixture)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from record_draws import RecordingRandom  # noqa: E402

OUT = pathlib.Path(__file__).resolve().parents[2] / "game/tests/golden/draws/sample.json"


def main():
    r = RecordingRandom("bag-test-1")
    r.randint(1, 6)
    r.random()
    r.uniform(0.5, 2.5)
    r.choice(["mars", "ceres", "vesta"])
    r.randrange(0, 20, 5)
    r.gauss(0.0, 1.0)
    r.shuffle([10, 20, 30, 40, 50])
    r.randint(1, 100)
    r.dump(OUT)
    print(f"wrote {len(r.draws)} draws to {OUT}")


if __name__ == "__main__":
    main()
