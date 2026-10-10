class_name TactileAudio
extends RefCounted
## Tactile Audio Engine & Financial Market Soundscape for Agora Roguelike (#24).
##
## Implements tactile sound design for Steam Deck & Bloomberg terminal experience:
## - Crisp mechanical keyboard actuation and release clicks with pitch jitter
## - Dual-tone market opening bells and trade execution chimes
## - GalNet ticker blips, emergency warning buzzers, and insolvency klaxons
## - Mid-range ambient pad (a soft chord, not a sub-bass drone) whose pitch and
##   loudness follow the Doomsday Clock stage; the only looping sound
## - Alerts (warning, critical) are one-shots: one event, one play, never looped
## - Multi-bus audio mixing, volume/mute telemetry, and cooldown throttling
## - Procedural PCM audio generation with zero external asset dependencies

signal sound_played(sound_id: String, bus: String, volume_db: float, pitch: float)
signal bus_volume_changed(bus_name: String, volume: float)
signal bus_mute_changed(bus_name: String, muted: bool)
signal tension_level_changed(stage: int, drone_freq: float)

## Sound IDs
const KEY_CLICK_DOWN: String = "KEY_CLICK_DOWN"
const KEY_CLICK_UP: String = "KEY_CLICK_UP"
const NAV_TICK: String = "NAV_TICK"
const NAV_BUMP: String = "NAV_BUMP"
const TAB_SWOOSH: String = "TAB_SWOOSH"
const MODAL_OPEN: String = "MODAL_OPEN"
const MODAL_CLOSE: String = "MODAL_CLOSE"
const ORDER_BUY: String = "ORDER_BUY"
const ORDER_SELL: String = "ORDER_SELL"
const ORDER_FILL: String = "ORDER_FILL"
const ORDER_CANCEL: String = "ORDER_CANCEL"
const MARKET_BELL: String = "MARKET_BELL"
const TICKER_BLIP: String = "TICKER_BLIP"
const ALARM_WARNING: String = "ALARM_WARNING"
const ALARM_CRITICAL: String = "ALARM_CRITICAL"
## The looping ambient pad. Still named DRONE_TENSION in code and bus names
## ("Ambient_Drone") so saved layouts and callers keep working.
const DRONE_TENSION: String = "DRONE_TENSION"
## Sounds that raise an alert. Each plays once per event and must never loop.
const ALERT_SOUNDS: Array[String] = [ALARM_WARNING, ALARM_CRITICAL]
## Alert volume steps (settings): linear volume of the Alerts bus.
const ALERT_VOLUME_STEP: float = 0.1

## Audio Buses
const BUS_MASTER: String = "Master"
const BUS_UI: String = "UI_SFX"
const BUS_MARKET: String = "Market_Chimes"
const BUS_ALERTS: String = "Alerts"
const BUS_AMBIENT: String = "Ambient_Drone"

const ALL_BUSES: Array[String] = [
	BUS_MASTER,
	BUS_UI,
	BUS_MARKET,
	BUS_ALERTS,
	BUS_AMBIENT
]

## Default Bus Volumes [0.0..1.0]
var bus_volumes: Dictionary = {
	BUS_MASTER: 1.0,
	BUS_UI: 0.85,
	BUS_MARKET: 0.90,
	BUS_ALERTS: 1.0,
	BUS_AMBIENT: 0.55
}

## Bus Mute States
var bus_mutes: Dictionary = {
	BUS_MASTER: false,
	BUS_UI: false,
	BUS_MARKET: false,
	BUS_ALERTS: false,
	BUS_AMBIENT: false
}

## Wall-clock cooldown to prevent acoustic stacking / clipping (in milliseconds)
const MIN_COOLDOWN_MSEC: int = 25
var sound_last_played_msec: Dictionary = {}
var _time_offset_msec: int = 0

## Ambient pad state. The pad stream is rendered at PAD_BASE_HZ; the stage
## frequency sets its pitch_scale. All stage pitches stay mid-range (see
## DRONE_STAGE_HZ), well above the old 41-110 Hz sub-bass drone.
const PAD_BASE_HZ: float = 220.0
## Pad root per Doomsday stage: A3, B3, C4, D4, then F3 for COLLAPSED (lower and darker, still mid-range).
const DRONE_STAGE_HZ: Array[float] = [220.0, 246.9, 261.6, 293.7, 174.6]
var current_doomsday_stage: int = 0
var current_drone_freq: float = PAD_BASE_HZ

## Pad loudness in dB; climbs with each Doomsday stage (see DRONE_VOLUME_DB).
## Mid-range carries further than sub-bass, so the curve sits lower than the old drone's.
const DRONE_VOLUME_DB: Array[float] = [-34.0, -29.0, -23.0, -18.0, -14.0]
var current_drone_volume_db: float = DRONE_VOLUME_DB[0]

## Recent sound event log (ring buffer of 20 items)
var recent_sound_events: Array[Dictionary] = []

## Sounds actually emitted (past mute and cooldown) since creation. Lets callers
## ask "did anything play?" without parsing the capped event log.
var sounds_played_count: int = 0

## Sounds that must never be dropped behind routine UI feedback (see MainScene voices).
const PRIORITY_SOUNDS: Array[String] = [ALARM_WARNING, ALARM_CRITICAL, MARKET_BELL]

## Pitch jitter range for mechanical clicks (±4%)
const PITCH_JITTER_RANGE: float = 0.04

## Cached procedural waveforms
var cached_streams: Dictionary = {}

func _init() -> void:
	pass

## Current audio clock in milliseconds (tracks real wall-clock by default)
func get_current_time_msec() -> int:
	return Time.get_ticks_msec() + _time_offset_msec

## Advance internal audio clock offset (useful for simulation or test stepping)
func advance_time(delta_sec: float) -> void:
	_time_offset_msec += int(delta_sec * 1000.0)

## Core playback method
func play_sfx(sound_id: String, pitch_scale: float = 1.0, volume_offset_db: float = 0.0) -> bool:
	var bus_name := get_sound_bus(sound_id)
	if is_bus_muted(bus_name) or is_bus_muted(BUS_MASTER):
		return false

	# Enforce rate-limiting cooldown per sound_id against wall-clock time
	var now_ms: int = get_current_time_msec()
	var last_ms: int = int(sound_last_played_msec.get(sound_id, -100000))
	if (now_ms - last_ms) < MIN_COOLDOWN_MSEC:
		return false
	sound_last_played_msec[sound_id] = now_ms

	# Calculate volume in dB from bus linear volume + offset
	var base_db: float = get_bus_base_db(bus_name)
	var final_db: float = base_db + volume_offset_db

	# Apply slight pitch jitter for mechanical keyboard feel
	var final_pitch: float = pitch_scale
	if sound_id in [KEY_CLICK_DOWN, KEY_CLICK_UP, NAV_TICK]:
		# Deterministic pseudo-jitter from millisecond timestamp
		var jitter_factor: float = (sin(float(now_ms) * 0.037 + float(sound_id.length())) * PITCH_JITTER_RANGE)
		final_pitch = clampf(pitch_scale + jitter_factor, 0.7, 1.4)

	# Record event in telemetry log
	var event := {
		"time_ms": now_ms,
		"time": float(now_ms) / 1000.0,
		"sound_id": sound_id,
		"bus": bus_name,
		"volume_db": snappedf(final_db, 0.1),
		"pitch": snappedf(final_pitch, 0.01)
	}
	recent_sound_events.push_front(event)
	if recent_sound_events.size() > 20:
		recent_sound_events.pop_back()

	sounds_played_count += 1
	sound_played.emit(sound_id, bus_name, final_db, final_pitch)
	return true

## dB of a bus's linear volume times Master's. This is what the AudioServer buses
## apply once synced, so a player routed to the bus plays at (volume_db - this).
func get_bus_base_db(bus_name: String) -> float:
	var bus_vol_lin: float = float(bus_volumes.get(bus_name, 1.0))
	if bus_name != BUS_MASTER:
		bus_vol_lin *= float(bus_volumes.get(BUS_MASTER, 1.0))
	return linear_to_db(maxf(0.0001, bus_vol_lin))

func is_priority_sound(sound_id: String) -> bool:
	return PRIORITY_SOUNDS.has(sound_id)

## Maps sound ID to logical audio mixing bus
func get_sound_bus(sound_id: String) -> String:
	match sound_id:
		KEY_CLICK_DOWN, KEY_CLICK_UP, NAV_TICK, NAV_BUMP, TAB_SWOOSH, MODAL_OPEN, MODAL_CLOSE:
			return BUS_UI
		ORDER_BUY, ORDER_SELL, ORDER_FILL, ORDER_CANCEL, MARKET_BELL, TICKER_BLIP:
			return BUS_MARKET
		ALARM_WARNING, ALARM_CRITICAL:
			return BUS_ALERTS
		DRONE_TENSION:
			return BUS_AMBIENT
		_:
			return BUS_UI

## Volume & Mute Controls
func set_bus_volume(bus_name: String, volume_lin: float) -> bool:
	if not ALL_BUSES.has(bus_name):
		return false
	bus_volumes[bus_name] = clampf(volume_lin, 0.0, 1.0)
	bus_volume_changed.emit(bus_name, bus_volumes[bus_name])
	return true

func get_bus_volume(bus_name: String) -> float:
	return float(bus_volumes.get(bus_name, 1.0))

func set_bus_mute(bus_name: String, muted: bool) -> bool:
	if not ALL_BUSES.has(bus_name):
		return false
	bus_mutes[bus_name] = muted
	bus_mute_changed.emit(bus_name, muted)
	return true

func is_bus_muted(bus_name: String) -> bool:
	return bool(bus_mutes.get(bus_name, false))

## Ambient pad modulation: pitch and loudness follow the Doomsday stage.
func update_doomsday_stage(new_stage: int) -> void:
	current_doomsday_stage = new_stage
	current_drone_freq = DRONE_STAGE_HZ[clampi(new_stage, 0, DRONE_STAGE_HZ.size() - 1)]
	current_drone_volume_db = DRONE_VOLUME_DB[clampi(new_stage, 0, DRONE_VOLUME_DB.size() - 1)]
	tension_level_changed.emit(current_doomsday_stage, current_drone_freq)
	play_sfx(DRONE_TENSION, get_drone_pitch_scale())

## Playback pitch_scale for the looping pad stream at the current stage.
func get_drone_pitch_scale() -> float:
	return current_drone_freq / PAD_BASE_HZ

func is_alert_sound(sound_id: String) -> bool:
	return ALERT_SOUNDS.has(sound_id)

## Alerts bus controls used by the settings screen.
func set_alert_volume(volume_lin: float) -> void:
	set_bus_volume(BUS_ALERTS, snappedf(volume_lin, ALERT_VOLUME_STEP))

func set_alert_mute(muted: bool) -> void:
	set_bus_mute(BUS_ALERTS, muted)

## Procedural Waveform Audio Synthesis (Self-contained, 0 assets required)
func get_or_generate_waveform(sound_id: String) -> AudioStreamWAV:
	if cached_streams.has(sound_id):
		return cached_streams[sound_id]

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 22050
	stream.stereo = false

	var sample_count: int = 1102 # ~50ms
	var raw_bytes := PackedByteArray()

	match sound_id:
		KEY_CLICK_DOWN:
			# Sharp tactile attack click with fast exponential decay (15ms)
			sample_count = 330
			for i in range(sample_count):
				var t := float(i) / 22050.0
				var env := exp(-t * 220.0)
				var val := int(sin(t * TAU * 1800.0) * env * 24000.0)
				raw_bytes.append(val & 0xFF)
				raw_bytes.append((val >> 8) & 0xFF)
		MARKET_BELL:
			# Metallic dual-harmonic bell chime (880Hz + 1760Hz, 300ms)
			sample_count = 6615
			for i in range(sample_count):
				var t := float(i) / 22050.0
				var env := exp(-t * 8.0)
				var val := int((sin(t * TAU * 880.0) * 0.6 + sin(t * TAU * 1760.0) * 0.4) * env * 26000.0)
				raw_bytes.append(val & 0xFF)
				raw_bytes.append((val >> 8) & 0xFF)
		ALARM_CRITICAL:
			# One-shot emergency dual-tone pulse (120ms), faded out so it ends without a click
			sample_count = 2646
			for i in range(sample_count):
				var t := float(i) / 22050.0
				var freq := 880.0 if (int(t * 16.0) % 2 == 0) else 660.0
				var fade := minf(1.0, float(sample_count - i) / 220.0)
				var val := int(sin(t * TAU * freq) * fade * 22000.0)
				raw_bytes.append(val & 0xFF)
				raw_bytes.append((val >> 8) & 0xFF)
		ALARM_WARNING:
			# One-shot soft two-note rising chime (260ms): lower and gentler than the critical pulse
			sample_count = 5733
			for i in range(sample_count):
				var t := float(i) / 22050.0
				var second: bool = t >= 0.13
				var tn := t - (0.13 if second else 0.0)
				var freq := 660.0 if second else 523.25
				var val := int(sin(t * TAU * freq) * exp(-tn * 14.0) * minf(1.0, tn * 400.0) * 20000.0)
				raw_bytes.append(val & 0xFF)
				raw_bytes.append((val >> 8) & 0xFF)
		DRONE_TENSION:
			# Mid-range ambient pad: A3 + E4 + A4 (220 / 330 / 440 Hz), each paired with a
			# 1 Hz-detuned twin for a slow chorus. One second at 22050 Hz holds a whole number
			# of cycles of every partial (220..441 Hz), so the loop is seamless. Soft by design:
			# no harmonics above 441 Hz, no attack. Pitched per Doomsday stage via pitch_scale.
			sample_count = 22050
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_begin = 0
			stream.loop_end = sample_count
			for i in range(sample_count):
				var t := float(i) / 22050.0
				var v := 0.0
				v += 0.34 * (sin(t * TAU * 220.0) + sin(t * TAU * 221.0))
				v += 0.22 * (sin(t * TAU * 330.0) + sin(t * TAU * 331.0))
				v += 0.10 * (sin(t * TAU * 440.0) + sin(t * TAU * 441.0))
				var val := int(v * 0.5 * 18000.0)
				raw_bytes.append(val & 0xFF)
				raw_bytes.append((val >> 8) & 0xFF)
		_:
			# Default navigation blip (1000Hz, 20ms)
			sample_count = 441
			for i in range(sample_count):
				var t := float(i) / 22050.0
				var env := exp(-t * 120.0)
				var val := int(sin(t * TAU * 1000.0) * env * 20000.0)
				raw_bytes.append(val & 0xFF)
				raw_bytes.append((val >> 8) & 0xFF)

	# Only the ambient pad loops. Everything else, alerts included, plays once.
	if sound_id != DRONE_TENSION:
		stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	stream.data = raw_bytes
	cached_streams[sound_id] = stream
	return stream

func clear_cache() -> void:
	cached_streams.clear()

## State Telemetry Snapshot
func to_dict() -> Dictionary:
	return {
		"bus_volumes": bus_volumes.duplicate(),
		"bus_mutes": bus_mutes.duplicate(),
		"current_sim_time_sec": snappedf(float(get_current_time_msec()) / 1000.0, 0.001),
		"doomsday_stage": current_doomsday_stage,
		"drone_freq_hz": current_drone_freq,
		"drone_volume_db": current_drone_volume_db,
		"recent_events_count": recent_sound_events.size(),
		"last_event": recent_sound_events[0] if recent_sound_events.size() > 0 else {}
	}
