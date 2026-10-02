"""Record every random draw as {call, args, result} for golden replay.

RecordingRandom subclasses random.Random, so with the same seed it produces
exactly what plain random.Random does. The Godot ReplayDrawSource
(game/core/replay_draw_source.gd) replays the dump and fails on any mismatch.

CPython implements randint via randrange and uniform/gauss via random, so the
public methods guard against recursion: only the outermost call is recorded.
shuffle records the resulting permutation of indices (new[i] = old[perm[i]]).
"""
import json
import random


class RecordingRandom(random.Random):
    def __init__(self, seed=None):
        self.draws = []
        self._depth = 0
        super().__init__(seed)

    def getrandbits(self, k):
        # Defining this keeps CPython's _randbelow on the getrandbits path.
        # Without it, overriding random() below makes Random.__init_subclass__
        # switch to the float-based _randbelow and the streams diverge.
        return super().getrandbits(k)

    def _rec(self, name, args, fn):
        outer = self._depth == 0
        self._depth += 1
        try:
            result = fn()
        finally:
            self._depth -= 1
        if outer:
            self.draws.append({"call": name, "args": args, "result": result})
        return result

    def randint(self, a, b):
        return self._rec("randint", [a, b], lambda: super(RecordingRandom, self).randint(a, b))

    def randrange(self, start, stop=None, step=1):
        if stop is None:
            start, stop = 0, start
        return self._rec("randrange", [start, stop, step],
                         lambda: super(RecordingRandom, self).randrange(start, stop, step))

    def uniform(self, a, b):
        return self._rec("uniform", [a, b], lambda: super(RecordingRandom, self).uniform(a, b))

    def random(self):
        return self._rec("random", [], lambda: super(RecordingRandom, self).random())

    def choice(self, seq):
        seq = list(seq)
        return self._rec("choice", [seq], lambda: super(RecordingRandom, self).choice(seq))

    def gauss(self, mu=0.0, sigma=1.0):
        return self._rec("gauss", [mu, sigma], lambda: super(RecordingRandom, self).gauss(mu, sigma))

    def shuffle(self, x):
        original = list(x)
        n = len(original)

        def run():
            idx = list(range(n))
            super(RecordingRandom, self).shuffle(idx)
            x[:] = [original[i] for i in idx]
            return idx

        self._rec("shuffle", [original], run)

    def dump(self, path):
        with open(path, "w") as f:
            json.dump(self.draws, f, indent=1)
            f.write("\n")
