extends Node3D
## Front-end flow (title, intro, play, results), round state, scenarios,
## spawning, the drone registry and the trial logger.
## Haptic output is reported to the bridge as camera-yaw bearings of known
## in-game drones; this is game-state tracking, not sound detection.

enum Scenario { STATIONARY_REAR = 1, ORBIT = 2, HIDDEN_APPROACH = 3, SURVIVAL = 4, TRIAL = 5 }

const SCENARIO_NAMES := {
	Scenario.STATIONARY_REAR: "1 Hidden target",
	Scenario.ORBIT: "2 Orbiting target",
	Scenario.HIDDEN_APPROACH: "3 Approaching target",
	Scenario.SURVIVAL: "4 Survival",
	Scenario.TRIAL: "5 Direction trial",
}
## Intro card copy: what to do and what to feel. Never names a direction.
const INTRO_CARDS := {
	Scenario.STATIONARY_REAR: ["A drone is hiding somewhere around you. Turn until you find it, then shoot.",
		"A steady buzz on one side of your head. It moves to your forehead as you face the drone."],
	Scenario.ORBIT: ["A drone is circling you. Follow it and shoot.",
		"The buzz travels around your head."],
	Scenario.HIDDEN_APPROACH: ["An unseen drone is closing in. Find it before it reaches you.",
		"The buzz grows stronger as it gets closer. If it reaches you, every motor buzzes at once."],
	Scenario.SURVIVAL: ["Drones come from all sides for 60 seconds. You can take 3 hits.",
		"The buzz points to the most urgent drone. Every motor buzzing at once means you were hit."],
	Scenario.TRIAL: ["Turn toward the vibration and click. Targets never appear.",
		"One buzz per target."],
}
const PRACTICE_NAME := "Direction trial · practice"
const PRACTICE_FEEL := " After each click you'll see the true direction."
const GUIDED_SEQUENCE: Array[int] = [Scenario.STATIONARY_REAR, Scenario.ORBIT, Scenario.HIDDEN_APPROACH, Scenario.SURVIVAL]
## Game states the bridge accepts; menu states are reported as "paused".
const BRIDGE_STATES := ["playing", "paused", "game_over"]
const DRONE_SCENE := preload("res://scenes/drone.tscn")
const HapticsClient := preload("res://scripts/haptics_client.gd")
const DroneScript := preload("res://scripts/drone.gd")
const Hud := preload("res://scripts/hud.gd")
const GRID_SHADER := preload("res://shaders/grid_floor.gdshader")
const ENEMY_LAYER := 2

@export_group("Round")
@export var round_length_s := 60.0
@export var start_health := 3
@export var spawn_radius_m := 10.0
@export var contact_radius_m := 1.0
@export var approach_speed_mps := 1.5
@export var speed_ramp_mps_per_s := 0.01
@export var max_approach_speed_mps := 2.1
@export var spawn_interval_s := 3.0
@export var max_live_drones := 6
@export var camera_height_m := 1.6
@export var reveal_cone_deg := 15.0
## After a round-ending contact, stay in play this long so the damage buzz plays.
@export var end_hold_s := 0.5

@export_group("Showcase")
@export var showcase_bearing_deg := 135.0
@export var showcase_distance_m := 6.0
@export var orbit_radius_m := 7.0
@export var orbit_speed_deg := 25.0

@export_group("Arena")
@export var platform_radius_m := 12.0
@export var pylon_count := 16
@export var pylon_radius_m := 14.5

@export_group("Trial")
@export var trial_bearings_deg: Array[float] = [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]
@export var trial_repeats := 3
@export var trial_distance_m := 6.0
@export var trial_gap_s := 1.5
@export var practice_gap_s := 3.0

@onready var player: Node3D = $player
@onready var hud: CanvasLayer = $hud
@onready var haptics: Node = $haptics_client
@onready var enemies: Node3D = $enemies

var drones := {}  # drone_id -> drone node; only unresolved drones
var scenario := Scenario.STATIONARY_REAR
## title, intro, playing, paused, results or game_over.
var state := "title"
var guided := false
## The practice trial: scenario 5 with 8 targets, widget shown and feedback.
var practice := false
var haptics_latch := false
var haptic_mode := "interpolated"
var hidden_mode := true
var health := 3
var score := 0
var time_left := 0.0

var _next_drone_number := 1
var _spawn_timer := 0.0
var _elapsed := 0.0
var _play_time := 0.0  # seconds in play this scenario; stops while paused
var _guided_index := 0
var _pending_scenario := Scenario.STATIONARY_REAR
var _pending_practice := false
var _widget_pref := Hud.Widget.MOTORS  # last F1 choice
var _widget_override := -1  # F1 choice made in this scenario, or -1
var _end_hold_left := 0.0
var _end_hold_action := Callable()
var _rng := RandomNumberGenerator.new()
var _sfx := {}
var _effects: Node3D
var _laser_material: StandardMaterial3D
var _burst_mesh: Mesh

var _trial_queue: Array[float] = []
var _trial_total := 0
var _trial_bearing := 0.0
var _trial_started_ms := 0
var _trial_gap_left := 0.0
var _trial_errors: Array[float] = []
var _trial_file: FileAccess
var _trial_path := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	enemies.process_mode = Node.PROCESS_MODE_PAUSABLE
	_rng.randomize()
	_register_input_actions()
	_build_arena()
	_build_effects()
	_build_sfx()
	player.shot_fired.connect(_on_shot_fired)
	haptics.telemetry_changed.connect(_refresh_hud)
	hud.menus.chosen.connect(_on_menu)
	_show_title()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# Focus loss pauses and disarms; resuming needs an explicit enable.
		haptics_latch = false
		if state == "playing":
			_set_paused(true)
		else:
			haptics.set_inactive(_bridge_state())
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		haptics.set_inactive("paused")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if state == "playing":
			_set_paused(true)
		elif state == "paused":
			_on_menu("controls_back" if hud.menus.screen == "controls" else "resume")
		elif state == "intro":
			_on_menu("back")
	elif event.is_action_pressed("restart"):
		haptics.start_new_session()
		haptics_latch = false
		_next_drone_number = 1
		if state not in ["title", "intro"]:
			_start_scenario(scenario)
	elif event.is_action_pressed("haptics_stop"):
		haptics_latch = false
		haptics.set_inactive(_bridge_state())
	elif event.is_action_pressed("haptics_enable"):
		haptics_latch = true
	elif event.is_action_pressed("toggle_haptic_mode"):
		haptic_mode = "nearest" if haptic_mode == "interpolated" else "interpolated"
	elif event.is_action_pressed("toggle_hidden"):
		hidden_mode = not hidden_mode
		if state in ["playing", "paused"] and scenario != Scenario.TRIAL:
			_start_scenario(scenario)
	elif event.is_action_pressed("toggle_debug"):
		# Both trials force the widget (off / motors only); F1 cannot change it there.
		if not (scenario == Scenario.TRIAL and state in ["playing", "paused"]):
			_widget_override = (_widget_mode() + 1) % 3
			_widget_pref = _widget_override
	else:
		for s in SCENARIO_NAMES:
			if event.is_action_pressed("scenario_%d" % s):
				guided = false
				_start_scenario(s, s == Scenario.TRIAL and event is InputEventKey and event.shift_pressed)
				break
	_refresh_hud()


func _physics_process(delta: float) -> void:
	if state != "playing":
		return
	_play_time += delta
	if _end_hold_left > 0.0:
		_end_hold_left -= delta
		if _end_hold_left <= 0.0:
			_finish_hold()
		return
	match scenario:
		Scenario.SURVIVAL:
			_update_survival(delta)
		Scenario.TRIAL:
			_update_trial(delta)


func _process(delta: float) -> void:
	if state == "playing":
		_update_reveals()
		haptics.set_state("playing", haptics_latch, haptic_mode, _threat_targets())
	else:
		haptics.set_state(_bridge_state(), false, haptic_mode, [])
		if state == "title":
			player.rotate_y(-delta * 0.05)  # slow idle pan; no drones exist here
	_refresh_hud()


func _bridge_state() -> String:
	return state if state in BRIDGE_STATES else "paused"


# --- front end -------------------------------------------------------------

func _show_title() -> void:
	guided = false
	_enter_menu("title")
	var entries := [["guided", "Start guided demo", "GUIDED DEMO"]]
	for s in SCENARIO_NAMES:
		entries.append(["scenario:%d" % s, SCENARIO_NAMES[s], "SCENARIOS" if s == Scenario.STATIONARY_REAR else ""])
	entries.append(["practice", PRACTICE_NAME, ""])
	hud.menus.show_title(entries)


func _show_intro(s: Scenario, is_practice := false) -> void:
	_pending_scenario = s
	_pending_practice = is_practice
	_enter_menu("intro")
	var card: Array = INTRO_CARDS[s]
	hud.menus.show_intro(PRACTICE_NAME if is_practice else SCENARIO_NAMES[s], _step_text(), card[0],
		card[1] + (PRACTICE_FEEL if is_practice else ""))


## `end_state` is "results" or "game_over" (scenario 4 and health loss).
func _show_results(rows: Array, end_state := "results") -> void:
	_enter_menu(end_state)
	var next_label := ""
	if guided:
		next_label = "Finish" if _guided_index >= GUIDED_SEQUENCE.size() - 1 else "Next"
	hud.menus.show_results(_scenario_title(), _step_text(), rows, next_label)


## Leave play: no drones, no input, visible mouse, inactive snapshot now.
func _enter_menu(new_state: String) -> void:
	_finish_trial_file()
	_clear_drones()
	_end_hold_left = 0.0
	hud.clear_practice_feedback()
	state = new_state
	get_tree().paused = false
	player.input_enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.set_in_play(false)
	haptics.set_inactive(_bridge_state())


func _scenario_title() -> String:
	return PRACTICE_NAME if practice and scenario == Scenario.TRIAL else SCENARIO_NAMES[scenario]


func _step_text() -> String:
	return "Guided demo · %d of %d" % [_guided_index + 1, GUIDED_SEQUENCE.size()] if guided else ""


func _on_menu(action: String) -> void:
	match action:
		"guided":
			guided = true
			_guided_index = 0
			_show_intro(GUIDED_SEQUENCE[0])
		"start":
			_start_scenario(_pending_scenario, _pending_practice)
		"back", "title":
			_show_title()
		"next":
			_guided_index += 1
			if _guided_index >= GUIDED_SEQUENCE.size():
				_show_title()
			else:
				_show_intro(GUIDED_SEQUENCE[_guided_index])
		"retry", "restart":
			_start_scenario(scenario, practice)
		"practice":
			guided = false
			_show_intro(Scenario.TRIAL, true)
		"resume":
			_set_paused(false)
		"controls":
			hud.menus.show_controls()
		"controls_back":
			hud.menus.show_pause()
		_:
			if action.begins_with("scenario:"):
				guided = false
				_show_intro(int(action.get_slice(":", 1)))
	_refresh_hud()


# --- scenarios -------------------------------------------------------------

func _start_scenario(s: Scenario, is_practice := false) -> void:
	_finish_trial_file()
	_clear_drones()
	_end_hold_left = 0.0
	hud.clear_practice_feedback()
	scenario = s
	practice = is_practice and s == Scenario.TRIAL
	_widget_override = -1
	health = start_health
	score = 0
	_elapsed = 0.0
	_spawn_timer = 0.0
	time_left = round_length_s
	_play_time = 0.0
	player.reset_view()
	hud.menus.hide_all()
	_set_state_playing()
	match s:
		Scenario.STATIONARY_REAR:
			_spawn_drone(DroneScript.Behavior.STATIONARY, showcase_bearing_deg, showcase_distance_m)
		Scenario.ORBIT:
			var d := _spawn_drone(DroneScript.Behavior.ORBITING, 90.0, orbit_radius_m)
			d.orbit_speed_deg = orbit_speed_deg
		Scenario.HIDDEN_APPROACH:
			_spawn_drone(DroneScript.Behavior.APPROACHING, 180.0, spawn_radius_m)
		Scenario.TRIAL:
			_start_trial()
	haptics.send_snapshot()
	_refresh_hud()  # apply the widget mode now, not a frame later


func _set_state_playing() -> void:
	state = "playing"
	get_tree().paused = false
	player.input_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	hud.set_in_play(true)


func _set_paused(paused: bool) -> void:
	if paused and _end_hold_left > 0.0:
		_finish_hold()  # the round is already over; go straight to its results
		return
	if paused:
		state = "paused"
		get_tree().paused = true
		player.input_enabled = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		haptics.set_inactive("paused")
		hud.menus.show_pause()
	else:
		hud.menus.hide_all()
		_set_state_playing()


## Survival round over; haptics turn off and need E again.
func _game_over(outcome: String) -> void:
	haptics_latch = false
	_show_results([
		["Outcome", outcome],
		["Score", str(score)],
		["Time survived", "%.1f s" % _elapsed],
		["Hits taken", str(start_health - health)],
	], "game_over")


## Results for single-target scenarios 1-3: timings are from spawn, in play time.
func _single_target_rows(outcome: String, d: Area3D, destroyed: bool) -> Array:
	return [
		["Outcome", outcome],
		["Time to find", "%.1f s" % (d.found_at_s - d.spawned_at_s) if d.found_at_s >= 0.0 else "Not found"],
		["Time to destroy", "%.1f s" % (_play_time - d.spawned_at_s) if destroyed else "-"],
	]


## A contact ended the round: stay in play with no targets and no input for
## end_hold_s, so the bridge's damage buzz plays before the inactive snapshot.
func _hold_then(action: Callable) -> void:
	_clear_drones()
	player.input_enabled = false
	_end_hold_action = action
	_end_hold_left = end_hold_s


func _finish_hold() -> void:
	_end_hold_left = 0.0
	_end_hold_action.call()


func _update_survival(delta: float) -> void:
	_elapsed += delta
	time_left = maxf(round_length_s - _elapsed, 0.0)
	if time_left <= 0.0:
		_game_over("Time up")
		return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and drones.size() < max_live_drones:
		_spawn_timer = spawn_interval_s
		var d := _spawn_drone(DroneScript.Behavior.APPROACHING, _rng.randf_range(0.0, 360.0), spawn_radius_m)
		d.approach_speed_mps = minf(approach_speed_mps + speed_ramp_mps_per_s * _elapsed, max_approach_speed_mps)


# --- trial mode --------------------------------------------------------------

func _start_trial() -> void:
	_trial_queue.clear()
	for i in (1 if practice else trial_repeats):
		_trial_queue.append_array(trial_bearings_deg)
	_shuffle(_trial_queue)
	_trial_total = _trial_queue.size()
	_trial_errors.clear()
	_trial_gap_left = trial_gap_s
	_open_trial_file()


func _update_trial(delta: float) -> void:
	if not drones.is_empty():
		return
	_trial_gap_left -= delta
	if _trial_gap_left > 0.0:
		return
	hud.clear_practice_feedback()  # always cleared before the next target spawns
	if _trial_queue.is_empty():
		_finish_trial()
		return
	_trial_bearing = _trial_queue.pop_back()
	var d := _spawn_drone(DroneScript.Behavior.STATIONARY, _trial_bearing, trial_distance_m)
	d.reveal_allowed = false
	d.set_hidden(true)
	_trial_started_ms = Time.get_ticks_msec()


func _record_trial_response() -> void:
	if drones.is_empty():
		return
	var drone: Area3D = drones.values()[0]
	var at_click = HapticsClient.horizontal_bearing_deg(player.view_basis(), player.global_position, drone.global_position)
	if typeof(at_click) == TYPE_NIL:
		return
	var signed_error := _wrap180(-at_click)
	var response := fposmod(_trial_bearing + signed_error, 360.0)
	var seconds := (Time.get_ticks_msec() - _trial_started_ms) / 1000.0
	_trial_errors.append(absf(signed_error))
	_write_trial_row(response, signed_error, seconds)
	_remove_drone(drone)
	_play("click")
	_trial_gap_left = trial_gap_s
	if practice:
		# Feedback only after the response; it stays up through the longer gap.
		hud.show_practice_feedback(_trial_bearing, response, signed_error)
		_trial_gap_left = practice_gap_s
	elif _trial_queue.is_empty():
		_finish_trial()


func _finish_trial() -> void:
	var total := 0.0
	var within_octant := 0
	for e in _trial_errors:
		total += e
		if e <= 22.5:
			within_octant += 1
	var n := _trial_errors.size()
	_finish_trial_file()
	_show_results([
		["Responses", str(n)],
		["Mean absolute error", "%.1f°" % (total / maxf(n, 1))],
		["Within 22.5°", "%d of %d" % [within_octant, n]],
		["CSV", ProjectSettings.globalize_path(_trial_path)],
	])


func _open_trial_file() -> void:
	DirAccess.make_dir_recursive_absolute("user://trials")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	_trial_path = "user://trials/%s_%s.csv" % ["practice" if practice else "trial", stamp]
	_trial_file = FileAccess.open(_trial_path, FileAccess.WRITE)
	if _trial_file == null:
		push_error("cannot write trial log %s (error %d)" % [_trial_path, FileAccess.get_open_error()])
		return
	_trial_file.store_line("session_id,trial,true_bearing_deg,response_bearing_deg,signed_error_deg,abs_error_deg,response_time_s,haptic_mode,haptics_enabled,bridge_status,output_backend,motor_angles_deg,practice,dashboard_visible")


func _write_trial_row(response: float, signed_error: float, seconds: float) -> void:
	if _trial_file == null:
		return
	var t: Dictionary = haptics.telemetry
	var angles := " ".join(t.get("motor_angles_deg", []).map(func(a): return str(a)))
	# dashboard_visible records what was on screen at the response; the real
	# trial forces the widget off, so it is always false there.
	_trial_file.store_line("%s,%d,%.1f,%.1f,%.1f,%.1f,%.3f,%s,%s,%s,%s,%s,%s,%s" % [
		haptics.session_id, _trial_errors.size(), _trial_bearing, response, signed_error,
		absf(signed_error), seconds, haptic_mode, haptics_latch,
		haptics.status_text().replace(",", ";"), t.get("output_backend", "none"), angles,
		practice, hud.is_widget_visible()])
	_trial_file.flush()


func _finish_trial_file() -> void:
	if _trial_file != null:
		_trial_file.close()
		_trial_file = null


# --- drones ------------------------------------------------------------------

## Spawn at a bearing relative to the current view, clockwise from forward.
func _spawn_drone(behavior: int, view_bearing_deg: float, radius_m: float) -> Area3D:
	var d: Area3D = DRONE_SCENE.instantiate()
	d.drone_id = "drone_%03d" % _next_drone_number
	_next_drone_number += 1
	d.behavior = behavior
	d.approach_speed_mps = approach_speed_mps
	d.contact_radius_m = contact_radius_m
	d.center = player.global_position
	d.set_hidden(hidden_mode)
	d.spawned_at_s = _play_time
	d.add_to_group("drones")
	enemies.add_child(d)
	d.place(_view_world_angle_deg() + view_bearing_deg, radius_m, camera_height_m)
	d.defeated.connect(_on_drone_defeated)
	d.contacted.connect(_on_drone_contacted)
	drones[d.drone_id] = d
	return d


func _remove_drone(d: Area3D) -> void:
	drones.erase(d.drone_id)
	if d.alive:
		d.alive = false
		d.collision_layer = 0
		d.queue_free()
	haptics.set_state(_bridge_state(), haptics_latch and state == "playing", haptic_mode, _threat_targets())
	haptics.send_snapshot()


func _clear_drones() -> void:
	for d in drones.values():
		d.alive = false
		d.queue_free()
	drones.clear()


func _on_drone_defeated(d: Area3D) -> void:
	_remove_drone(d)
	score += 1
	_play("hit")
	hud.flash_hit()
	_spawn_burst(d.global_position)  # the drone is resolved, so this reveals nothing
	if drones.is_empty() and scenario in [Scenario.STATIONARY_REAR, Scenario.ORBIT, Scenario.HIDDEN_APPROACH]:
		_show_results(_single_target_rows("Target destroyed", d, true))


func _on_drone_contacted(d: Area3D) -> void:
	health -= 1
	haptics.damage_count += 1  # sent with the snapshot below; the bridge buzzes all motors
	_remove_drone(d)
	_play("damage")
	hud.flash_damage()
	if health <= 0:
		_hold_then(_game_over.bind("Out of health"))
	elif drones.is_empty() and scenario == Scenario.HIDDEN_APPROACH:
		_hold_then(_show_results.bind(_single_target_rows("The drone reached you", d, false)))


func _on_shot_fired(collider: Object) -> void:
	if state != "playing":
		return
	if scenario == Scenario.TRIAL:
		_record_trial_response()  # clicks are responses: no shot effects at all
		return
	_play("shot")
	_spawn_laser(player.muzzle_position(), player.last_shot_end)
	if collider is Area3D and collider.is_in_group("drones") and collider.alive:
		collider.resolve_defeat()


func _update_reveals() -> void:
	for d in drones.values():
		var b = HapticsClient.horizontal_bearing_deg(player.view_basis(), player.global_position, d.global_position)
		if typeof(b) == TYPE_NIL or minf(b, 360.0 - b) > reveal_cone_deg:
			continue
		if d.found_at_s < 0.0:
			d.found_at_s = _play_time
		if not d.revealed and d.reveal_allowed:
			d.reveal()


## Complete current target set, including hidden and offscreen drones.
func _threat_targets() -> Array:
	var list := []
	for d in drones.values():
		var b = HapticsClient.horizontal_bearing_deg(player.view_basis(), player.global_position, d.global_position)
		if typeof(b) == TYPE_NIL:
			continue  # no horizontal direction; contact resolves it
		var ttc = d.time_to_contact()
		list.append({
			"id": d.drone_id,
			"bearing_deg": b,
			"distance_m": snappedf(HapticsClient.horizontal_distance(player.global_position, d.global_position), 0.0001),
			"time_to_contact_s": snappedf(ttc, 0.0001) if typeof(ttc) != TYPE_NIL else null,
		})
	return list


## World angle of the view, clockwise from world -Z, matching drone.place().
func _view_world_angle_deg() -> float:
	var f: Vector3 = -player.view_basis().z
	return rad_to_deg(atan2(f.x, -f.z))


# --- HUD -----------------------------------------------------------------------

func _refresh_hud() -> void:
	if not is_node_ready():
		return
	var tag := "HIDDEN" if hidden_mode else ""
	if scenario == Scenario.TRIAL:
		tag = "TARGET %d / %d" % [_trial_total - _trial_queue.size(), _trial_total]
	var timer := time_left / round_length_s if scenario == Scenario.SURVIVAL else -1.0
	var trial := scenario == Scenario.TRIAL
	hud.update_round(_scenario_title(), tag, health, 0 if trial else start_health, -1 if trial else score, timer, time_left)
	hud.update_haptics(haptics_latch, state == "playing", haptic_mode, haptics.status_text(), haptics.telemetry)

	var mode := _widget_mode()
	hud.set_widget_mode(mode)
	var full := mode == Hud.Widget.FULL and state in ["playing", "paused"]
	hud.update_widget(haptics.telemetry, haptics.last_known_angles,
		_threat_targets().map(func(t): return t["bearing_deg"]) if full else [],
		"%s · %s" % [_backend_label(), "NEAREST" if haptic_mode == "nearest" else "BLEND"],
		_debug_text() if full else "")


## Off in the real trial, motors only in practice. In hidden scenarios 1 and 3
## it starts off on real serial hardware (so the audience feels rather than
## reads), motors only for the simulator and fake device. F1 overrides it.
func _widget_mode() -> int:
	if scenario == Scenario.TRIAL:
		return Hud.Widget.MOTORS if practice else Hud.Widget.OFF
	if _widget_override >= 0:
		return _widget_override
	if scenario in [Scenario.STATIONARY_REAR, Scenario.HIDDEN_APPROACH] and haptics.last_known_backend == "serial":
		return Hud.Widget.OFF
	return _widget_pref


func _backend_label() -> String:
	match haptics.last_known_backend:
		"simulator":
			return "SIMULATOR"
		"fake_serial":
			return "FAKE SERIAL"
		"serial":
			return "SERIAL"
	return "NO BRIDGE"


func _debug_text() -> String:
	var t: Dictionary = haptics.telemetry
	var lines := [
		"source: known in-game drone positions (not sound detection)",
		"session %s  sent seq %d" % [haptics.session_id, haptics.last_sent_seq()],
		"bridge: %s" % haptics.status_text(),
	]
	if haptics.socket_error != "":
		lines.append(haptics.socket_error)
	if t.is_empty():
		lines.append("motor output: unknown")
	else:
		var levels: Array = t["motor_levels"].map(func(l): return "%.2f" % l)
		lines.append("backend %s  link %s  output %s" % [t["output_backend"], t["link_state"], "on" if t["output_enabled"] else "off"])
		lines.append("selected %s  bearing %s" % [t.get("selected_target_id"), t.get("bearing_deg")])
		lines.append("commanded levels [%s]" % ", ".join(levels))
		lines.append("serial ack seq %s (acceptance, not vibration)" % t.get("last_ack_seq"))
	var nearest := ""
	for target in _threat_targets():
		nearest += "\n  %s  %.1f deg  %.1f m" % [target["id"], target["bearing_deg"], target["distance_m"]]
	lines.append("game targets:" + (nearest if nearest != "" else " none"))
	return "\n".join(lines)


# --- setup -----------------------------------------------------------------------

func _register_input_actions() -> void:
	var keys := {
		"pause": KEY_ESCAPE, "restart": KEY_R, "toggle_hidden": KEY_H,
		"toggle_haptic_mode": KEY_M, "toggle_debug": KEY_F1,
		"haptics_stop": KEY_S, "haptics_enable": KEY_E,
		"scenario_1": KEY_1, "scenario_2": KEY_2, "scenario_3": KEY_3,
		"scenario_4": KEY_4, "scenario_5": KEY_5,
	}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.physical_keycode = keys[action]
			InputMap.action_add_event(action, ev)
	if not InputMap.has_action("shoot"):
		InputMap.add_action("shoot")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("shoot", click)


## Night defence platform: emissive grid floor, gradient sky, light fog and
## identical, evenly spaced pylons. Nothing in it is unique, so no landmark
## can line up with a target.
func _build_arena() -> void:
	var horizon := Color(0.06, 0.1, 0.16)
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.008, 0.012, 0.03)
	sky_material.sky_horizon_color = horizon
	sky_material.ground_horizon_color = horizon
	sky_material.ground_bottom_color = Color(0.0, 0.0, 0.01)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = sky_material
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.5, 0.65)
	env.ambient_light_energy = 0.45
	env.fog_enabled = true
	env.fog_light_color = horizon
	env.fog_density = 0.035
	env.fog_sky_affect = 0.0
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)

	var moon := DirectionalLight3D.new()
	moon.rotation_degrees = Vector3(-50, 35, 0)
	moon.light_color = Color(0.65, 0.75, 1.0)
	moon.light_energy = 0.55
	moon.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY  # no moon disc in the sky
	add_child(moon)

	var floor_material := ShaderMaterial.new()
	floor_material.shader = GRID_SHADER
	floor_material.set_shader_parameter("radius_m", platform_radius_m)
	var platform := CylinderMesh.new()
	platform.top_radius = platform_radius_m
	platform.bottom_radius = platform_radius_m
	platform.height = 0.6
	platform.radial_segments = 96
	platform.rings = 1
	platform.material = floor_material
	var platform_shape := CylinderShape3D.new()
	platform_shape.radius = platform_radius_m
	platform_shape.height = 0.6
	_add_static(platform, platform_shape, Vector3(0, -0.3, 0))

	var ground := PlaneMesh.new()
	ground.size = Vector2(240, 240)
	ground.material = _flat_material(Color(0.015, 0.02, 0.03), 0.9)
	var ground_shape := BoxShape3D.new()
	ground_shape.size = Vector3(240, 0.2, 240)
	var ground_body := _add_static(ground, ground_shape, Vector3(0, -0.6, 0))
	ground_body.get_child(1).position.y = -0.1

	var hull := BoxMesh.new()
	hull.size = Vector3(0.4, 3.2, 0.4)
	hull.material = _flat_material(Color(0.1, 0.12, 0.15), 0.5)
	var hull_shape := BoxShape3D.new()
	hull_shape.size = hull.size
	var light := _flat_material(Color(0.22, 0.88, 1.0), 1.0)
	light.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var cap := BoxMesh.new()
	cap.size = Vector3(0.5, 0.1, 0.5)
	cap.material = light
	var band := BoxMesh.new()
	band.size = Vector3(0.42, 0.05, 0.42)
	band.material = light
	for i in pylon_count:
		# Offset half a step so no pylon sits on a scripted bearing.
		var a := deg_to_rad((i + 0.5) * 360.0 / pylon_count)
		var pylon := _add_static(hull, hull_shape, Vector3(sin(a), 0, -cos(a)) * pylon_radius_m + Vector3(0, 1.0, 0))
		for part in [[cap, 1.65], [band, 0.6]]:
			var m := MeshInstance3D.new()
			m.mesh = part[0]
			m.position.y = part[1]
			pylon.add_child(m)


func _add_static(mesh: Mesh, shape: Shape3D, pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	body.add_child(instance)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	add_child(body)
	return body


func _flat_material(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


# --- effects ---------------------------------------------------------------

func _build_effects() -> void:
	_effects = Node3D.new()
	_effects.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_effects)
	_laser_material = _flat_material(Color(0.5, 0.95, 1.0), 1.0)
	_laser_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var spark := BoxMesh.new()
	spark.size = Vector3(0.08, 0.08, 0.08)
	spark.material = _flat_material(Color(1.0, 0.45, 0.15), 1.0)
	spark.material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_burst_mesh = spark


## About 60 ms of laser from just below the camera to where the shot ended.
func _spawn_laser(from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	if length < 0.05:
		return
	var beam := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.006, 0.006, length)
	box.material = _laser_material
	beam.mesh = box
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_effects.add_child(beam)
	var up := Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.FORWARD
	beam.look_at_from_position(from.lerp(to, 0.5), to, up)
	var flash := MeshInstance3D.new()
	var bulb := SphereMesh.new()
	bulb.radius = 0.012
	bulb.height = 0.024
	bulb.material = _laser_material
	flash.mesh = bulb
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_effects.add_child(flash)
	flash.global_position = from
	for node in [beam, flash]:
		get_tree().create_timer(0.06).timeout.connect(node.queue_free)


## Short burst of sparks where a drone was destroyed.
func _spawn_burst(pos: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = 32
	p.lifetime = 0.7
	p.mesh = _burst_mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 5.5
	p.gravity = Vector3(0, -7, 0)
	p.damping_min = 1.0
	p.damping_max = 3.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.2
	var shrink := Curve.new()
	shrink.add_point(Vector2(0, 1))
	shrink.add_point(Vector2(1, 0))
	p.scale_amount_curve = shrink
	_effects.add_child(p)
	p.global_position = pos
	p.emitting = true
	get_tree().create_timer(1.2).timeout.connect(p.queue_free)


## Non-spatial generated tones: they carry no directional information.
func _build_sfx() -> void:
	var specs := {"shot": [880.0, 0.06], "hit": [520.0, 0.15], "damage": [140.0, 0.35], "click": [1000.0, 0.04]}
	for key in specs:
		var player_node := AudioStreamPlayer.new()
		player_node.stream = _make_tone(specs[key][0], specs[key][1])
		player_node.volume_db = -8.0
		add_child(player_node)
		_sfx[key] = player_node


func _make_tone(freq: float, seconds: float) -> AudioStreamWAV:
	var rate := 22050
	var count := int(rate * seconds)
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := float(i) / rate
		var envelope := 1.0 - float(i) / count
		data.encode_s16(i * 2, int(sin(TAU * freq * t) * envelope * 20000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	return wav


func _play(key: String) -> void:
	if _sfx.has(key):
		_sfx[key].play()


func _shuffle(list: Array[float]) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp := list[i]
		list[i] = list[j]
		list[j] = tmp


static func _wrap180(angle: float) -> float:
	var a := fposmod(angle + 180.0, 360.0) - 180.0
	return a
