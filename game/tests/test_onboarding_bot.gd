extends RefCounted
## The first-hour bot (#36 First-Hour Onboarding Flow, task 5; tools/onboarding_bot.gd): a scripted
## player drives the real Main through core beats 1 to 5 on three seeds. Each beat must fire, hold
## (every core beat has `holds` true), and complete in order; the dismissals must reach no m0_*
## handler; and the run hash, after equal sim ticks, must equal the same script with the tutorial
## off and the dismissals removed (docs/design/onboarding.md section 8). Prints the sim time to each
## beat for section 12's measurement.

const BOT_PATH := "res://tools/onboarding_bot.gd"
const SEEDS: Array = [11, 42, 84]
const BEATS: Array = ["tabs", "order", "debt", "leave", "sell"]


func _play(p_seed: int, tutorial: bool):
	var bot = load(BOT_PATH).new(p_seed, tutorial)
	bot.run()
	return bot


func _check(p_seed: int, timings: Array) -> String:
	var on = _play(p_seed, true)
	var off = _play(p_seed, false)
	var why := ""
	var tag := "seed %d: " % p_seed
	if on.error != "":
		why = "tutorial-on script stopped: " + on.error
	elif off.error != "":
		why = "tutorial-off script stopped: " + off.error
	elif on.fire_order != BEATS:
		why = "beats fired %s, expected %s" % [str(on.fire_order), str(BEATS)]
	elif on.done_order != BEATS:
		why = "beats completed %s, expected %s" % [str(on.done_order), str(BEATS)]
	elif on.main.settings.tutorial_enabled:
		why = "completing beat 5 should switch the core tutorial off"
	else:
		for id in BEATS:
			var holds: bool = bool(on.main.onboarding.beat(id)["holds"])
			if holds and int(on.holds.get(id, 0)) != 1:
				why = "beat %s has holds=true and should hold exactly once, held %d" % [id, int(on.holds.get(id, 0))]
			elif not holds and on.holds.has(id):
				why = "beat %s has holds=false but held" % id
			elif int(on.fired_tick[id]) > int(on.done_tick[id]):
				why = "beat %s completed before it fired" % id
			if why != "":
				break
	if why == "":
		if on.leaks != 0 or on.presses != BEATS.size():
			why = "%d dismissals (%d leaked into M0Loop), expected %d and none" % [on.presses, on.leaks, BEATS.size()]
		elif off.presses != 0 or off.main.onboarding != null:
			why = "the control script must have no tutorial and no dismissals"
		elif on.end_ticks != off.end_ticks or on._ticks() != off._ticks():
			why = "tick counts differ: %d vs %d" % [on._ticks(), off._ticks()]
		elif on.rounds != off.rounds or on.main.loop.total_fills != off.main.loop.total_fills or on.main.loop.total_fills != 2:
			why = "rounds/fills differ: %d/%d vs %d/%d" % [on.rounds, on.main.loop.total_fills, off.rounds, off.main.loop.total_fills]
		elif on.frames != off.frames:
			why = "frame counts differ: %d vs %d" % [on.frames, off.frames]  # holds add no step() frames
		elif on.state_hash() != off.state_hash():
			why = "state_hash differs with the tutorial on"
		elif on.canonical() != off.canonical():
			why = "RunSave.capture differs with the tutorial on"
		elif JSON.stringify(on.main.controller.sim_clock.to_dict()) != JSON.stringify(off.main.controller.sim_clock.to_dict()):
			why = "the clock state differs"
	if why == "":
		var row := {"seed": p_seed, "buy": on.buy_station, "sell": on.sell_station, "rounds": on.rounds, "end": on.end_ticks}
		for id in BEATS:
			row[id + "_fired"] = int(on.fired_tick[id])
			row[id + "_done"] = int(on.done_tick[id])
		timings.append(row)
	on.free_main()
	off.free_main()
	return "" if why == "" else tag + why


func test_bot_walks_beats_1_to_5_and_matches_the_tutorial_off_run() -> String:
	var timings: Array = []
	for s in SEEDS:
		var why: String = _check(int(s), timings)
		if why != "":
			return why
	for row in timings:
		var parts: Array = []
		for id in BEATS:
			parts.append("%s %d/%d" % [id, row[id + "_fired"], row[id + "_done"]])
		print("ONBOARDING-BOT seed %d %s->%s rounds %d ticks fired/done: %s" % [row["seed"], row["buy"], row["sell"], row["rounds"], ", ".join(parts)])
	return "ok"
