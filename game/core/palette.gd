class_name Palette
extends RefCounted
## Colorblind-safe colors for the red/green market semantics (#37).
##
## Every color that carries meaning (bid vs ask) lives here, nowhere else. The two
## colorblind palettes draw from the Okabe-Ito set, which stays distinguishable
## under red-green deficiencies: blue/orange for deuteranopia, blue/yellow for
## protanopia (where red reads as dark). Color is never the only signal: bid and
## ask rows also carry a word and a glyph (BID_GLYPH / ASK_GLYPH, see the SIDE_*
## and BOARD_* strings), so a player with no color vision loses nothing.

const DEFAULT: String = "default"
const DEUTERANOPIA: String = "deuteranopia"
const PROTANOPIA: String = "protanopia"
const CHOICES: Array[String] = [DEFAULT, DEUTERANOPIA, PROTANOPIA]

## Non-color cue glyphs, used by the ladder and the board next to BID / ASK.
const BID_GLYPH: String = "+"
const ASK_GLYPH: String = "-"

const _COLORS: Dictionary = {
	# Default: the HUD's oxidized teal for bids, rust red for asks (#105).
	DEFAULT: {"bid": Color(0.10, 0.42, 0.46), "ask": Color(0.78, 0.30, 0.14)},
	# Okabe-Ito sky blue 56B4E9 and orange E69F00.
	DEUTERANOPIA: {"bid": Color("56B4E9"), "ask": Color("E69F00")},
	# Okabe-Ito sky blue 56B4E9 and yellow F0E442 (red is dark to a protanope).
	PROTANOPIA: {"bid": Color("56B4E9"), "ask": Color("F0E442")},
}

static var _current: String = DEFAULT


static func current() -> String:
	return _current


## False (and unchanged) for an unknown id.
static func set_current(id: String) -> bool:
	if not CHOICES.has(id):
		return false
	_current = id
	return true


static func bid_color(id: String = "") -> Color:
	return _COLORS[_resolve(id)]["bid"]


static func ask_color(id: String = "") -> Color:
	return _COLORS[_resolve(id)]["ask"]


static func _resolve(id: String) -> String:
	return id if _COLORS.has(id) else _current


## Display name of a palette in the current language.
static func label(id: String) -> String:
	return Loc.t("SET_PALETTE_" + id.to_upper())
