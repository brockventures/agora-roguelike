class_name NativeDrawSource
extends DrawSource
## Runtime draw source on Godot's RandomNumberGenerator. Seeded and
## deterministic within Godot, but it is NOT expected to match Python's
## random.Random; parity is checked through ReplayDrawSource instead.

var _rng := RandomNumberGenerator.new()

func _init(seed_value: int = 0) -> void:
	_rng.seed = seed_value

func randint(a: int, b: int) -> int:
	return _rng.randi_range(a, b)

func randrange(start: int, stop: int, step: int = 1) -> int:
	if step == 0:
		push_error("NativeDrawSource.randrange: step must not be zero")
		return start
	var n: int
	if step > 0:
		n = (stop - start + step - 1) / step
	else:
		n = (start - stop - step - 1) / (-step)
	if n <= 0:
		push_error("NativeDrawSource.randrange: empty range")
		return start
	return start + step * _rng.randi_range(0, n - 1)

func uniform(a: float, b: float) -> float:
	return _rng.randf_range(a, b)

func random() -> float:
	return _rng.randf()

func choice(seq: Array) -> Variant:
	if seq.is_empty():
		push_error("NativeDrawSource.choice: empty sequence")
		return null
	return seq[_rng.randi_range(0, seq.size() - 1)]

func gauss(mu: float, sigma: float) -> float:
	return _rng.randfn(mu, sigma)

func shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t = arr[i]
		arr[i] = arr[j]
		arr[j] = t
