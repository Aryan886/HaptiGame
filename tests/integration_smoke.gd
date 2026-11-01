extends SceneTree
## Headless end-to-end smoke test of the day-1 gate against a running bridge:
## a rear-right drone gives the expected simulated cue, turning brings it to
## the front, shooting removes the cue, restart and stop leave output off.
##
## Start the bridge first:  python bridge/main.py --backend simulator
## Then:  godot --headless --path game --script ../tests/integration_smoke.gd
## With --no-bridge, checks only that the game runs and reports unavailable.

var failures := 0
var game: Node
var client: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var expect_bridge := not "--no-bridge" in OS.get_cmdline_user_args()
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	client = game.get_node("haptics_client")
	await _wait(0.6)

	if not expect_bridge:
		_check("status without bridge", client.status_text() == "bridge unavailable", client.status_text())
		_check("telemetry empty", client.telemetry.is_empty(), client.telemetry)
		_check("game still playing", game.state == "playing", game.state)
		return _finish()

	_check("bridge telemetry fresh", client.is_telemetry_fresh(), client.status_text())
	_check("honest no-hardware label", client.status_text() in ["simulated output", "fake serial device (no hardware)"], client.status_text())
	_check("output off before enable", not _any_level(), client.telemetry.get("motor_levels"))

	game.haptics_latch = true
	await _wait(0.3)
	var t: Dictionary = client.telemetry
	_check("drone selected", t.get("selected_target_id") == "drone_001", t)
	_check("bearing 135", _close(t.get("bearing_deg"), 135.0), t.get("bearing_deg"))
	# 6 m -> strength 0.52; 135 deg between motors 2 (120) and 3 (180), blend 0.25.
	_check_levels("rear-right levels", [0, 0, 0.39, 0.13, 0, 0])

	game.player.rotate_y(-deg_to_rad(135.0))
	await _wait(0.3)
	_check("turned: bearing 0", _close(client.telemetry.get("bearing_deg"), 0.0), client.telemetry.get("bearing_deg"))
	_check_levels("front levels", [0.52, 0, 0, 0, 0, 0])
	game.player.pitch_pivot.rotation.x = deg_to_rad(40.0)
	await _wait(0.2)
	_check("pitch does not move bearing", _close(client.telemetry.get("bearing_deg"), 0.0), client.telemetry.get("bearing_deg"))
	game.player.pitch_pivot.rotation.x = 0.0
	await physics_frame
	await physics_frame

	game.player.try_shoot()
	await _wait(0.2)
	_check("drone destroyed", game.drones.is_empty() and game.score == 1, [game.drones, game.score])
	_check("cue removed after shot", not _any_level() and client.telemetry.get("selected_target_id") == null, client.telemetry)

	game.player.try_shoot()  # miss: nothing in front
	await _wait(0.3)
	_check("miss is harmless", game.score == 1, game.score)

	game._start_scenario(1)
	await _wait(0.3)
	_check("scenario reset keeps session armed", _any_level(), client.telemetry.get("motor_levels"))

	var input := InputEventAction.new()
	input.action = "haptics_stop"
	input.pressed = true
	Input.parse_input_event(input)
	await _wait(0.2)
	_check("S stops output", not _any_level() and not game.haptics_latch, client.telemetry.get("motor_levels"))

	game.haptics_latch = true
	await _wait(0.2)
	var old_session: String = client.session_id
	input.action = "restart"
	Input.parse_input_event(input)
	await _wait(0.3)
	_check("restart makes new session", client.session_id != old_session, client.session_id)
	_check("restart leaves output off", not _any_level() and not game.haptics_latch, client.telemetry.get("motor_levels"))
	_check("drone ids restart per session", game.drones.has("drone_001"), game.drones.keys())

	game._start_scenario(4)
	game.haptics_latch = true
	await _wait(4.0)
	_check("survival spawns approaching drones", game.drones.size() >= 1, game.drones.size())
	var survival_target = client.telemetry.get("selected_target_id")
	_check("approaching drone selected", survival_target != null, client.telemetry)
	_finish()


func _finish() -> void:
	print("integration smoke: %s" % ("PASS" if failures == 0 else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _any_level() -> bool:
	for l in client.telemetry.get("motor_levels", []):
		if l > 0.0:
			return true
	return false


func _check_levels(label: String, want: Array) -> void:
	var got: Array = client.telemetry.get("motor_levels", [])
	var ok := got.size() == want.size()
	if ok:
		for i in want.size():
			ok = ok and absf(got[i] - want[i]) < 0.002
	_check(label, ok, got)


func _close(got, want: float) -> bool:
	return typeof(got) != TYPE_NIL and absf(float(got) - want) < 0.01


func _check(label: String, ok: bool, detail) -> void:
	if ok:
		print("ok   %s" % label)
	else:
		failures += 1
		printerr("FAIL %s: %s" % [label, detail])
