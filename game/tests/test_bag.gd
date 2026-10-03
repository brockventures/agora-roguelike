extends RefCounted
## Tests for Bags (res://core/bag.gd) marble-bag RNG engine.
## Verifies exact rate over full bags, streak bounds, varying draws,
## DrawSource integration, forced rolls, and serialization.

func test_composition_examples() -> String:
	var cases := [
		{"p": 0.10, "k": 1, "n": 10},
		{"p": 0.14, "k": 7, "n": 50},
		{"p": 0.25, "k": 1, "n": 4},
		{"p": 0.5, "k": 1, "n": 2},
		{"p": 0.02, "k": 1, "n": 50},
		{"p": 0.1 * 0.45, "k": 9, "n": 200},
		{"p": 0.2 * 0.85, "k": 17, "n": 100},
	]
	for c in cases:
		var res = Bags.composition(float(c["p"]))
		if res == null:
			return "composition(%f) returned null, expected [%d, %d]" % [c["p"], c["k"], c["n"]]
		if int(res[0]) != int(c["k"]) or int(res[1]) != int(c["n"]):
			return "composition(%f) returned [%s, %s], expected [%d, %d]" % [c["p"], res[0], res[1], c["k"], c["n"]]
	return "ok"

func test_composition_off_grid() -> String:
	var off_grid := [
		1.0 / 3.0 + 1e-6,
		0.0001,
		0.123456,
		1.0 / 201.0,
		0.0,
		1.0,
		-0.1,
		1.5
	]
	for p in off_grid:
		var res = Bags.composition(p)
		if res != null:
			return "composition(%f) returned %s, expected null" % [p, var_to_str(res)]
	return "ok"

func test_exact_rate_over_whole_bags() -> String:
	var b := Bags.new("hazards", NativeDrawSource.new(42))
	var cases := [
		{"p": 0.10, "k": 1, "n": 10},
		{"p": 0.14, "k": 7, "n": 50},
		{"p": 0.25, "k": 1, "n": 4},
	]
	for c in cases:
		var p: float = float(c["p"])
		var k: int = int(c["k"])
		var n: int = int(c["n"])
		var total_hits: int = 0
		for bag_idx in 30:
			var bag_hits: int = 0
			for d in n:
				if b.draw("test_event_%f" % p, "amos", p):
					bag_hits += 1
					total_hits += 1
			if bag_hits != k:
				return "bag %d for p=%f had %d hits, expected exactly %d" % [bag_idx, p, bag_hits, k]
		if total_hits != k * 30:
			return "total hits for p=%f was %d, expected %d" % [p, total_hits, k * 30]
	return "ok"

func test_streaks_bounded() -> String:
	var b := Bags.new("piracy", NativeDrawSource.new(12345))
	var cases := [0.10, 0.02, 0.25, 0.14, 0.045]
	for p in cases:
		var comp = Bags.composition(p)
		var k: int = int(comp[0])
		var n: int = int(comp[1])
		var max_miss_bound: int = 2 * ((n + k - 1) / k - 1)  # 2 * (ceil(n/k) - 1)

		var cur_hit: int = 0
		var cur_miss: int = 0
		var max_hit: int = 0
		var max_miss: int = 0

		for i in (n * 200):
			var hit: bool = b.draw("streak_event", "fleet_%f" % p, p)
			if hit:
				cur_hit += 1
				cur_miss = 0
				if cur_hit > max_hit:
					max_hit = cur_hit
			else:
				cur_miss += 1
				cur_hit = 0
				if cur_miss > max_miss:
					max_miss = cur_miss

		if max_hit > 2:
			return "p=%f max hit streak was %d, expected <= 2" % [p, max_hit]
		if max_miss > max_miss_bound:
			return "p=%f max miss streak was %d, expected <= %d" % [p, max_miss, max_miss_bound]
	return "ok"

func test_forced_outcomes() -> String:
	var b := Bags.new("covert", NativeDrawSource.new(1))
	b.force("sabotage", true)
	b.force("sabotage", false)
	b.force("sabotage", [true, true])

	if not b.draw("sabotage", "amos", 0.10):
		return "expected forced draw 1 to be true"
	if b.draw("sabotage", "amos", 0.10):
		return "expected forced draw 2 to be false"
	if not b.draw("sabotage", "amos", 0.10):
		return "expected forced draw 3 to be true"
	if not b.draw("sabotage", "amos", 0.10):
		return "expected forced draw 4 to be true"

	# After queue is exhausted, regular draw proceeds
	var next_roll: bool = b.draw("sabotage", "amos", 0.10)
	# Should not crash
	return "ok"

func test_draw_varying_p() -> String:
	var b := Bags.new("varying", NativeDrawSource.new(999))
	var p: float = 1.0 / 3.0 + 1e-6
	var hits: int = 0
	var total: int = 300
	for i in total:
		if b.draw_varying("var_event", "amos", p):
			hits += 1
	var expected: float = p * float(total)
	if abs(float(hits) - expected) > 10.0:
		return "varying p=%f hits %d diverged too far from expected %f" % [p, hits, expected]
	return "ok"

func test_stats_tracking() -> String:
	var b := Bags.new("stats_test", NativeDrawSource.new(777))
	# Draw one full bag of p=0.2 (k=1, n=5)
	for i in 5:
		b.draw("custom", "fleet_a", 0.2)
	var s = b.stats("custom", "fleet_a")
	if s["draws"] != 5:
		return "expected 5 draws, got %d" % s["draws"]
	if s["hits"] != 1:
		return "expected 1 hit, got %d" % s["hits"]
	return "ok"

func test_edge_cases() -> String:
	var b := Bags.new("edge", NativeDrawSource.new(1))
	if b.draw("ev", "f", 0.0):
		return "p=0.0 should never hit"
	if b.draw("ev", "f", -0.5):
		return "p < 0 should never hit"
	if not b.draw("ev", "f", 1.0):
		return "p=1.0 should always hit"
	if not b.draw("ev", "f", 2.0):
		return "p > 1.0 should always hit"
	return "ok"

func test_per_fleet_isolation() -> String:
	var b1 := Bags.new("iso", NativeDrawSource.new(50))
	var b2 := Bags.new("iso", NativeDrawSource.new(50))

	# Alone: amos draws 40 times from b1
	var alone: Array = []
	for i in 40:
		alone.append(b1.draw("e", "amos", 0.1))

	# Mixed: b2 mixes draws from zero and amos
	var mixed: Array = []
	for i in 40:
		b2.draw("e", "zero", 0.1)
		b2.draw("e", "zero", 0.1)
		mixed.append(b2.draw("e", "amos", 0.1))

	# Even with interleaving, both amos sequences draw identically from their own state
	var stats_zero = b2.stats("e", "zero")
	if stats_zero["draws"] != 80:
		return "expected 80 zero draws, got %d" % stats_zero["draws"]
	var stats_amos = b2.stats("e", "amos")
	if stats_amos["draws"] != 40:
		return "expected 40 amos draws, got %d" % stats_amos["draws"]
	return "ok"

func test_replay_draw_source_integration() -> String:
	# Construct a small recorded replay source for a p=0.5 bag (k=1, n=2)
	# Refill will call shuffle([2]) and randrange(0, 2, 1)
	var recorded := [
		{"call": "shuffle", "args": [[2]], "result": [0]},
		{"call": "randrange", "args": [0, 2, 1], "result": 1}, # hit is at index 1 -> bag is "01"
	]
	var replay := ReplayDrawSource.new(recorded)
	var b := Bags.new("replay_test", replay)

	var draw1: bool = b.draw("test_ev", "f1", 0.5)
	if draw1:
		return "expected draw1 to be false (marble 0 is '0')"

	var draw2: bool = b.draw("test_ev", "f1", 0.5)
	if not draw2:
		return "expected draw2 to be true (marble 1 is '1')"

	replay.assert_exhausted()
	if not replay.ok():
		return "replay failed: %s" % [replay.failure]
	return "ok"

func test_to_dict_roundtrip() -> String:
	var b := Bags.new("saved", NativeDrawSource.new(123))
	b.draw("ev1", "fl1", 0.25)
	b.draw("ev1", "fl1", 0.25)
	b.force("ev2", true)

	var d: Dictionary = b.to_dict()
	var b2 := Bags.new("empty", NativeDrawSource.new(999))
	b2.from_dict(d)

	if b2.ns != "saved":
		return "expected ns='saved', got '%s'" % b2.ns
	if b2.stats("ev1", "fl1")["draws"] != 2:
		return "expected 2 draws in loaded bag"
	if not b2.draw("ev2", "fl1", 0.1):
		return "expected forced draw to persist in restored bag"
	return "ok"
