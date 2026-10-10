class_name StableHash
extends RefCounted
## Engine-independent string hash for seed derivation (Epic 2 audit D10).
##
## GDScript's built-in hash(String) is engine-defined: it may change between
## Godot versions, so any seed derived from it (per-corp seeds, Chapter 11
## next seeds, hazard / piracy / crisis / bag RNG streams) would silently
## change replays and saves across an engine upgrade. This is the documented
## replacement: the first 32 bits (8 hex digits) of SHA-256 of the UTF-8 text,
## as a non-negative int in 0 .. 0xFFFFFFFF. SHA-256 is fixed by spec.
##
## RunSave.state_hash() already used String.sha256_text() directly and is not
## affected.


static func hash32(text: String) -> int:
	return ("0x" + text.sha256_text().substr(0, 8)).hex_to_int()
