class_name DrawSource
extends RefCounted
## Interface for every random draw the engine makes. Mirrors the subset of
## Python's random.Random that the referee uses, so golden fixtures recorded
## from the referee (tools/golden/record_draws.py) can be replayed in tests.
## The base class only reports misuse; use NativeDrawSource at runtime and
## ReplayDrawSource in tests.

func _unimplemented(method: String) -> void:
	push_error("DrawSource.%s is not implemented; use a concrete source" % method)

## Integer in [a, b], both inclusive.
func randint(_a: int, _b: int) -> int:
	_unimplemented("randint")
	return 0

## Integer from range(start, stop, step).
func randrange(_start: int, _stop: int, _step: int = 1) -> int:
	_unimplemented("randrange")
	return 0

## Float in [a, b].
func uniform(_a: float, _b: float) -> float:
	_unimplemented("uniform")
	return 0.0

## Float in [0.0, 1.0).
func random() -> float:
	_unimplemented("random")
	return 0.0

## One element of a non-empty Array.
func choice(_seq: Array) -> Variant:
	_unimplemented("choice")
	return null

## Gaussian draw.
func gauss(_mu: float, _sigma: float) -> float:
	_unimplemented("gauss")
	return 0.0

## Shuffle the Array in place.
func shuffle(_arr: Array) -> void:
	_unimplemented("shuffle")
