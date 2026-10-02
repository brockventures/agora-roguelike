import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "golden"))
from record_draws import RecordingRandom  # noqa: E402

SEED = "bag-test-1"


def _calls(r):
    out = [
        r.randint(1, 6),
        r.random(),
        r.uniform(0.5, 2.5),
        r.choice(["a", "b", "c"]),
        r.randrange(0, 20, 5),
        r.randrange(7),
        r.gauss(0.0, 1.0),
    ]
    arr = list(range(8))
    r.shuffle(arr)
    out.append(arr)
    out.append(r.randint(1, 100))
    return out


def test_results_match_plain_random():
    assert _calls(RecordingRandom(SEED)) == _calls(random.Random(SEED))


def test_only_outermost_calls_recorded():
    r = RecordingRandom(SEED)
    _calls(r)
    assert [d["call"] for d in r.draws] == [
        "randint", "random", "uniform", "choice", "randrange", "randrange",
        "gauss", "shuffle", "randint",
    ]
    assert r.draws[0]["args"] == [1, 6]
    assert r.draws[5]["args"] == [0, 7, 1]


def test_shuffle_records_permutation():
    r = RecordingRandom(SEED)
    arr = list("abcdef")
    r.shuffle(arr)
    d = r.draws[0]
    assert sorted(d["result"]) == list(range(6))
    assert [d["args"][0][i] for i in d["result"]] == arr
    plain = list("abcdef")
    random.Random(SEED).shuffle(plain)
    assert arr == plain


def test_dump_roundtrip(tmp_path):
    r = RecordingRandom(SEED)
    _calls(r)
    p = tmp_path / "d.json"
    r.dump(p)
    assert json.loads(p.read_text()) == r.draws
