extends SceneTree
## Headless gameplay checks that need no bridge.
## Run: godot --headless --path game --script ../tests/game_checks.gd

const HapticsClient := preload("res://scripts/haptics_client.gd")

var failures := 0
var game: Node
var client: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	client = game.get_node("haptics_client")
	await _wait(0.2)

	# HUD theme: bundled font everywhere, no outlined text, no direction words.
	var labels: Array = game.hud.find_children("*", "Label", true, false)
	var off_font: Array = labels.filter(func(l): return not l.get_theme_font("font").resource_path.begins_with("res://fonts/"))
	_check("all labels use bundled font", not labels.is_empty() and off_font.is_empty(), off_font)
	var outlined: Array = labels.filter(func(l): return l.get_theme_constant("outline_size") > 0)
	_check("no outlined labels", outlined.is_empty(), outlined)
	var direction_words := ["rear", "behind", "left", "right", "front", "ahead", "north", "south", "east", "west"]
	var leaky: Array = game.SCENARIO_NAMES.values().filter(func(n): return direction_words.any(func(w): return n.to_lower().contains(w)))
	_check("scenario names name no direction", leaky.is_empty(), leaky)
	var Hud = game.hud.get_script()
	_check("chip: simulated", Hud.bridge_chip("simulated output", {})[0] == "SIMULATED OUTPUT", Hud.bridge_chip("simulated output", {}))
	_check("chip: fake", Hud.bridge_chip("fake serial device (no hardware)", {})[0] == "FAKE DEVICE (NO HARDWARE)", "")
	var ready_chip: Array = Hud.bridge_chip("serial ready (commands acknowledged, vibration not measured)", {"output_backend": "serial", "link_state": "ready", "last_ack_seq": 42})
	_check("chip: hardware ready with ack", ready_chip[0] == "HARDWARE READY · ACK 42", ready_chip)
	_check("chip: unavailable is red", Hud.bridge_chip("bridge unavailable", {})[1] == game.hud.UiTheme.RED, "")
	var stale_chip: Array = Hud.bridge_chip("serial stale", {"output_backend": "serial", "link_state": "stale"})
	_check("chip: stale is grey with ?", stale_chip[0].ends_with("?") and stale_chip[1] == game.hud.UiTheme.GREY, stale_chip)
	_check("chip: socket error is grey with ?", Hud.bridge_chip("telemetry socket error", {})[0].ends_with("?"), "")
	_check("haptics off strip at start", game.hud.is_off_strip_visible() and game.hud.haptics_chip_text() == "HAPTICS OFF", game.hud.haptics_chip_text())
	game.haptics_latch = true
	await _wait(0.05)
	_check("strip hidden when enabled", not game.hud.is_off_strip_visible() and game.hud.haptics_chip_text().begins_with("HAPTICS ON"), game.hud.haptics_chip_text())
	game.haptics_latch = false

	# Front end: the title screen has no drones and reports an inactive state.
	_check("starts on title", game.state == "title" and game.hud.menus.screen == "title" and game.drones.is_empty(), [game.state, game.hud.menus.screen])
	_check("title sends inactive", client.game_state == "paused" and not client.haptics_enabled, client.game_state)
	_check("title lists guided demo and 5 scenarios", game.hud.menus.button_labels().size() == 6, game.hud.menus.button_labels())

	# title -> intro -> playing, through the buttons.
	_press("1 Hidden target")
	_check("title -> intro", game.state == "intro" and game.hud.menus.screen == "intro" and game.drones.is_empty(), game.state)
	_check("intro sends inactive", client.game_state == "paused", client.game_state)
	_press("Start")
	_check("intro -> playing", game.state == "playing" and game.drones.has("drone_001") and not game.hud.menus.visible, [game.state, game.drones.keys()])
	await _wait(0.1)

	# Hidden stationary target: tracked while invisible, revealed once in view, stays revealed.
	var d: Area3D = game.drones["drone_001"]
	_check("hidden drone invisible", not d.mesh.visible, d.mesh.visible)
	_check("hidden drone still in snapshot", client.targets.size() == 1, client.targets)
	game.player.rotate_y(-deg_to_rad(130.0))  # 5 deg off target: inside the 15 deg cone
	await _wait(0.1)
	_check("revealed inside cone", d.mesh.visible, d.mesh.visible)
	game.player.rotate_y(deg_to_rad(130.0))
	await _wait(0.1)
	_check("stays revealed", d.mesh.visible, d.mesh.visible)

	# Double resolution counts once.
	d.resolve_defeat()
	d.resolve_defeat()
	_check("hit marker on defeat", game.hud.is_hit_marker_showing(), "")
	await _wait(0.05)
	_check("defeat counted once", game.score == 1 and game.drones.is_empty(), [game.score, game.drones])
	_check("completion -> results", game.state == "results" and game.hud.menus.button_labels() == ["Retry", "Title"], [game.state, game.hud.menus.button_labels()])
	_check("results send inactive", client.game_state == "paused" and client.targets.is_empty(), client.game_state)

	# Orbit changes bearing over time.
	game._start_scenario(2)
	await _wait(0.1)
	var b0: float = client.targets[0]["bearing_deg"]
	await _wait(1.0)
	var b1: float = client.targets[0]["bearing_deg"]
	_check("orbit moves clockwise", b1 - b0 > 15.0 and b1 - b0 < 35.0, [b0, b1])
	_check("orbit has no contact time", client.targets[0]["time_to_contact_s"] == null, client.targets[0])

	# Approaching contact damages exactly once.
	game._start_scenario(3)
	var a: Area3D = game.drones.values()[0]
	var ttc0 = client.targets[0]["time_to_contact_s"] if not client.targets.is_empty() else null
	await _wait(0.1)
	ttc0 = client.targets[0]["time_to_contact_s"]
	_check("approaching ttc ~6 s", ttc0 != null and absf(ttc0 - 6.0) < 0.2, ttc0)
	a.approach_speed_mps = 30.0
	await _wait(0.6)
	_check("contact costs one health", game.health == game.start_health - 1 and game.drones.is_empty(), [game.health, game.drones])
	_check("contact clears targets", client.targets.is_empty(), client.targets)

	# Pause stops motion and sends an inactive snapshot.
	game._start_scenario(3)
	game.haptics_latch = true
	await _wait(0.1)
	a = game.drones.values()[0]
	game._set_paused(true)
	var pos := a.position
	await _wait(0.3)
	_check("paused: drone frozen", a.position.is_equal_approx(pos), [pos, a.position])
	_check("paused: inactive state", client.game_state == "paused" and client.targets.is_empty(), [client.game_state, client.targets])
	game._set_paused(false)
	_check("escape resume keeps latch", game.haptics_latch, game.haptics_latch)

	# Focus loss pauses and requires explicit re-enable.
	game._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check("focus loss pauses", game.state == "paused" and not game.haptics_latch, [game.state, game.haptics_latch])
	game._set_paused(false)

	# Survival: time expiry ends the round and clears drones.
	game.round_length_s = 1.0
	game._start_scenario(4)
	await _wait(1.3)
	_check("time expiry -> game over", game.state == "game_over" and game.drones.is_empty(), [game.state, game.drones])
	_check("game over inactive", client.game_state == "game_over" and not client.haptics_enabled, client.game_state)
	game.round_length_s = 60.0

	# Health reaching zero ends the round.
	game._start_scenario(4)
	game.health = 1
	await _wait(0.1)
	for drone in game.drones.values():
		drone.approach_speed_mps = 50.0
	await _wait(0.5)
	_check("zero health -> game over", game.state == "game_over" and game.health == 0, [game.state, game.health])

	# Trial: invisible, response logged, error near zero when aimed exactly.
	game.trial_repeats = 1
	game.trial_gap_s = 0.1
	game._start_scenario(5)
	_check("trial hides debug view", not game.hud.is_debug_visible(), game.hud.is_debug_visible())
	for i in 2:
		await _wait(0.3)
		var target: Area3D = game.drones.values()[0]
		var bearing = HapticsClient.horizontal_bearing_deg(game.player.view_basis(), Vector3.ZERO, target.global_position)
		game.player.rotate_y(-deg_to_rad(bearing))
		await _wait(0.05)
		_check("trial target never revealed (%d)" % i, not target.mesh.visible, target.mesh.visible)
		game.player._cooldown = 0.0
		game.player.try_shoot()
		await _wait(0.05)
	var errors: Array = game._trial_errors
	_check("trial errors recorded", errors.size() == 2 and errors.max() < 0.5, errors)
	var path := ProjectSettings.globalize_path(game._trial_path)
	var csv := FileAccess.get_file_as_string(game._trial_path)
	_check("trial csv has header + 2 rows", csv.split("\n", false).size() == 3, path)
	DirAccess.remove_absolute(path)

	# Pause -> Title clears the drones and sends an inactive snapshot.
	game._start_scenario(4)
	game.haptics_latch = true
	await _wait(0.1)
	_check("survival spawned a drone", game.drones.size() >= 1, game.drones.size())
	game._set_paused(true)
	_check("pause menu shown", game.hud.menus.screen == "paused", game.hud.menus.screen)
	_press("Title")
	await _wait(0.05)
	_check("pause -> title clears drones", game.state == "title" and game.drones.is_empty() and game.enemies.get_child_count() == 0, [game.state, game.enemies.get_child_count()])
	_check("pause -> title inactive", client.game_state == "paused" and client.targets.is_empty() and not client.haptics_enabled and not paused, [client.game_state, client.targets])

	# Guided demo: scenario 1 -> results -> Next -> intro 2 -> scenario 2; Finish after 4.
	_press("Start guided demo")
	_check("guided opens intro 1", game.state == "intro" and game._pending_scenario == 1, [game.state, game._pending_scenario])
	_press("Start")
	await _wait(0.1)
	game.drones.values()[0].resolve_defeat()
	await _wait(0.05)
	_check("guided 1 -> results with Next", game.state == "results" and game.hud.menus.button_labels() == ["Next", "Retry", "Title"], game.hud.menus.button_labels())
	_press("Next")
	_check("Next -> intro 2", game.state == "intro" and game._pending_scenario == 2, [game.state, game._pending_scenario])
	_press("Start")
	_check("Next starts scenario 2", game.state == "playing" and game.scenario == 2 and game.guided, [game.state, game.scenario])
	game._guided_index = 3
	game.round_length_s = 0.5
	game._start_scenario(4)
	await _wait(0.8)
	_check("guided 4 ends with Finish", game.state == "game_over" and game.hud.menus.button_labels()[0] == "Finish", game.hud.menus.button_labels())
	_press("Finish")
	_check("Finish returns to title", game.state == "title" and not game.guided, game.state)
	game.round_length_s = 60.0

	# Repeated restarts do not leak drones.
	game.trial_repeats = 3
	for i in 30:
		game._start_scenario(1 + i % 4)
		await process_frame
	await _wait(0.2)
	_check("no drone leak", game.enemies.get_child_count() <= 1, game.enemies.get_child_count())

	print("game checks: %s" % ("PASS" if failures == 0 else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)


## Press a visible menu button by its label.
func _press(text: String) -> void:
	for b in game.hud.menus.find_children("*", "Button", true, false):
		if b.text == text and b.is_visible_in_tree():
			b.pressed.emit()
			return
	_check("button '%s' on screen" % text, false, game.hud.menus.button_labels())


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _check(label: String, ok: bool, detail) -> void:
	if ok:
		print("ok   %s" % label)
	else:
		failures += 1
		printerr("FAIL %s: %s" % [label, detail])
