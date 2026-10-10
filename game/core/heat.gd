class_name Heat
extends RefCounted
## Baron heat and the consequence events it queues (Epic 3 task 11,
## docs/design/epic3-barons.md 6.2 and 7, decision 9.4).
##
## Heat is what a baron remembers of the player. It lives in BaronState.heat (an existing
## saved field, 0 for a baron nobody has hurt) and rises only when a player action actually
## hurts that baron: a corner round charged, a margin call executed, a credit line opened or
## defaulted, a defense contract missed, a bounty the player sponsors near its docks. A
## sale's pressure accrual does NOT raise heat, only the call it may cause does.
##
##  - Decay. `heat.decay_per_round` a round, at the round boundary.
##  - Retaliation. At `heat.retaliation_at` the baron QUEUES a consequence event (scratch key
##    `retaliate`, written only while queued) and the player gets a GalNet warning; the
##    event lands at the next boundary, and heat drops to `heat.reset_to` so it does not
##    re-fire every round. The event is a crises.json entry of `origin: "consequence"`
##    for the baron's archetype, injected straight into the deck's active list
##    (CrisisDeck.inject: no Bags, no max_active, no draw_count) and never touching doomsday
##    ticks. Its fine goes through Barons.penalize(.., "consequence"), uncapped, and may
##    force Chapter 11 because the player's own choices exposed them (decision 9.4).
##  - Random baron events. `consequence.random_event_bps` (shipped 300 = 3% a baron a round, a
##    placeholder; it was 0 until task 12 switched it on and re-pinned the world hashes) is the chance per baron per round
##    of an `origin: "random"` entry for the archetype. Its fine goes through
##    Barons.penalize(.., "random"): clamped by the lethal guard, so it can never push net
##    worth below its pre-event value minus `consequence.random_max_loss_bps` and can never
##    by itself make Chapter11.assess insolvent.
##  - Chapter 11. Heat is per corp: a filing zeroes every baron's heat and drops the queue.
##
## Determinism: integers only; barons walked in sorted id order; the one chance is a fresh
## NativeDrawSource seeded hash32("baron-event-<id>-<run_seed>-<round>"). Every number is a
## placeholder in barons.json.

const DEFAULTS: Dictionary = {
	"decay_per_round": 1,
	"retaliation_at": 6,
	"corner_round": 2,
	"margin_call": 3,
	"credit_open": 1,
	"credit_default": 3,
	"missed_contract": 4,
	"bounty_sponsored": 3,
	"reset_to": 0,
}
const ORIGINS: Array[String] = ["random", "consequence"]
const BARON_TIER: String = CrisisDeck.TIER_BARON


static func settings(w: Barons) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate()
	var h = w.data.get("heat", {})
	if h is Dictionary:
		for k in DEFAULTS:
			if (h as Dictionary).has(k):
				out[k] = int(h[k])
	return out


static func random_event_bps(w: Barons) -> int:
	var c = w.data.get("consequence", {})
	return clampi(int((c as Dictionary).get("random_event_bps", 0)), 0, 10000) if c is Dictionary else 0


## Heat the baron carries.
static func level(w: Barons, id: String) -> int:
	var s: BaronState = w.state(id)
	return s.heat if s != null else 0


## Heat summed over every baron: what rival bounty targeting reads.
static func total(w: Barons) -> int:
	var n: int = 0
	for id in w.ids():
		n += level(w, id)
	return n


## The queued retaliation {due} for a baron, {} when none.
static func queued(w: Barons, id: String) -> Dictionary:
	var s: BaronState = w.state(id)
	if s == null:
		return {}
	var q = s.scratch.get("retaliate", null)
	if q is Dictionary:
		return {"due": int((q as Dictionary).get("due", 0))}
	return {}


## Raises a baron's heat. Only a baron running itself has a grudge to hold: a held baron
## (by the player or a rival) takes none. Returns the heat standing after.
static func raise(w: Barons, id: String, n: int) -> int:
	var s: BaronState = w.state(id)
	if s == null or n <= 0 or s.holder != "":
		return level(w, id)
	s.heat = mini(s.heat + n, 99)
	return s.heat


## A new corp starts with no grudge against it.
static func reset(w: Barons) -> void:
	for id in w.ids():
		var s: BaronState = w.state(id)
		s.heat = 0
		s.scratch.erase("retaliate")


static func _draw(prefix: String, id: String, run_seed: int, round_num: int) -> NativeDrawSource:
	return NativeDrawSource.new(StableHash.hash32("%s-%s-%d-%d" % [prefix, id, run_seed, round_num]))


## The crises.json entry for a baron archetype and origin, {} when none (sorted by id,
## the first wins).
static func event_def(deck_data: Dictionary, archetype: String, origin: String) -> Dictionary:
	var best: Dictionary = {}
	for d in deck_data.get("crises", []):
		if str(d.get("tier", "")) != BARON_TIER or str(d.get("origin", "random")) != origin:
			continue
		if str(d.get("baron_archetype", "")) != archetype:
			continue
		if best.is_empty() or str(d.get("id", "")) < str(best.get("id", "")):
			best = d
	return best


## The once-a-round step (Barons.advance_round, after the levers have raised heat and
## before the books are reseeded): barons by sorted id. Returns events:
## {kind: "heat_queued", baron, heat, due_round} and
## {kind: "retaliation", baron, origin, name, station, requested, fine, clamped, forced_ch11}.
static func advance(w: Barons, round_num: int, rc: RunController) -> Array:
	var events: Array = []
	var cfg: Dictionary = settings(w)
	var chance: int = random_event_bps(w)
	for id in w.ids():
		var s: BaronState = w.state(id)
		if s.holder != "":
			s.heat = 0
			s.scratch.erase("retaliate")
			continue
		var fired: bool = false
		var q: Dictionary = queued(w, id)
		if not q.is_empty() and round_num >= int(q["due"]):
			var ev: Dictionary = _fire(w, id, round_num, rc, "consequence")
			if not ev.is_empty():
				events.append(ev)
				s.scratch.erase("retaliate")
				s.heat = int(cfg["reset_to"])
				fired = true
		if not fired:
			s.heat = maxi(0, s.heat - int(cfg["decay_per_round"]))
			if s.heat >= int(cfg["retaliation_at"]) and queued(w, id).is_empty():
				s.scratch["retaliate"] = {"due": round_num + 1}
				events.append({"kind": "heat_queued", "baron": id, "heat": s.heat, "due_round": round_num + 1})
		if chance > 0 and rc != null and queued(w, id).is_empty():
			if _draw("baron-event", id, rc.run_seed, round_num).randint(0, 9999) < chance:
				var rev: Dictionary = _fire(w, id, round_num, rc, "random")
				if not rev.is_empty():
					events.append(rev)
	return events


## Fires one baron event of `origin` now: the fine first (so the modal can state it),
## then the deck entry. {} when there is nothing to fire (no player, no entry for the
## archetype) or the same event is still live (a consequence stays queued and retries).
static func _fire(w: Barons, id: String, round_num: int, rc: RunController, origin: String) -> Dictionary:
	if rc == null:
		return {}
	var deck: CrisisDeck = rc.crisis_deck
	var data: Dictionary = deck.data if deck != null else CrisisDeck.load_data()
	var def: Dictionary = event_def(data, str(w.def(id).get("archetype", "")), origin)
	if def.is_empty():
		return {}
	if deck != null and deck.is_active(str(def.get("id", ""))):
		return {}
	var anchor: String = str(w.def(id).get("anchor", ""))
	var fx: Dictionary = def.get("effects", {})
	var fine: int = maxi(0, rc.net_worth()) * int(fx.get("fine_bps", 0)) / 10000
	var res: Dictionary = w.penalize(rc, fine, origin)
	var name: String = str(def.get("name", ""))
	if deck != null:
		var inst: Dictionary = deck.inject(def, round_num, anchor, id, origin, {"fine_cr": int(res["applied"])})
		name = Loc.crisis_name(inst)
	return {
		"kind": "retaliation", "baron": id, "origin": origin, "name": name, "station": anchor,
		"requested": int(res["requested"]), "fine": int(res["applied"]), "clamped": bool(res["clamped"]),
		"forced_ch11": bool(res["forced_ch11"]),
	}
