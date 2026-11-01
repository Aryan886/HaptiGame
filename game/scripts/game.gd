extends Node3D
## Round state, scenarios, spawning, the drone registry and the trial logger.
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
const DRONE_SCENE := preload("res://scenes/drone.tscn")
const HapticsClient := preload("res://scripts/haptics_client.gd")
const DroneScript := preload("res://scripts/drone.gd")
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

@export_group("Showcase")
@export var showcase_bearing_deg := 135.0
@export var showcase_distance_m := 6.0
@export var orbit_radius_m := 7.0
@export var orbit_speed_deg := 25.0

@export_group("Trial")
@export var trial_bearings_deg: Array[float] = [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]
@export var trial_repeats := 3
@export var trial_distance_m := 6.0
@export var trial_gap_s := 1.5

@onready var player: Node3D = $player
@onready var hud: CanvasLayer = $hud
@onready var haptics: Node = $haptics_client
@onready var enemies: Node3D = $enemies

var drones := {}  # drone_id -> drone node; only unresolved drones
var scenario := Scenario.STATIONARY_REAR
var state := "playing"
var haptics_latch := false
var haptic_mode := "interpolated"
var hidden_mode := true
var health := 3
var score := 0
var time_left := 0.0
var message := ""

var _next_drone_number := 1
var _spawn_timer := 0.0
var _elapsed := 0.0
var _rng := RandomNumberGenerator.new()
var _sfx := {}

var _trial_queue: Array[float] = []
var _trial_total := 0
var _trial_bearing := 0.0
var _trial_started_ms := 0
var _trial_gap_left := 0.0
var _trial_errors: Array[float] = []
var _trial_file: FileAccess
var _trial_path := ""
var _debug_before_trial := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	enemies.process_mode = Node.PROCESS_MODE_PAUSABLE
	_rng.randomize()
	_register_input_actions()
	_build_arena()
	_build_sfx()
	player.shot_fired.connect(_on_shot_fired)
	haptics.telemetry_changed.connect(_refresh_hud)
	_start_scenario(Scenario.STATIONARY_REAR)


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# Focus loss pauses and disarms; resuming needs an explicit enable.
		haptics_latch = false
		if state == "playing":
			_set_paused(true)
		else:
			haptics.set_inactive(state)
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		haptics.set_inactive("paused")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if state == "playing":
			_set_paused(true)
		elif state == "paused":
			_set_paused(false)
	elif event.is_action_pressed("restart"):
		haptics.start_new_session()
		haptics_latch = false
		_next_drone_number = 1
		_start_scenario(scenario)
	elif event.is_action_pressed("haptics_stop"):
		haptics_latch = false
		haptics.set_inactive(state)
	elif event.is_action_pressed("haptics_enable"):
		haptics_latch = true
	elif event.is_action_pressed("toggle_haptic_mode"):
		haptic_mode = "nearest" if haptic_mode == "interpolated" else "interpolated"
	elif event.is_action_pressed("toggle_hidden"):
		hidden_mode = not hidden_mode
		if scenario != Scenario.TRIAL:
			_start_scenario(scenario)
	elif event.is_action_pressed("toggle_debug"):
		hud.set_debug_visible(not hud.is_debug_visible())
	else:
		for s in SCENARIO_NAMES:
			if event.is_action_pressed("scenario_%d" % s):
				_start_scenario(s)
				break
	_refresh_hud()


func _physics_process(delta: float) -> void:
	if state != "playing":
		return
	match scenario:
		Scenario.SURVIVAL:
			_update_survival(delta)
		Scenario.TRIAL:
			_update_trial(delta)


func _process(_delta: float) -> void:
	if state == "playing":
		_update_reveals()
		haptics.set_state("playing", haptics_latch, haptic_mode, _threat_targets())
	else:
		haptics.set_state(state, false, haptic_mode, [])
	_refresh_hud()


# --- scenarios -------------------------------------------------------------

func _start_scenario(s: Scenario) -> void:
	_finish_trial_file()
	if scenario == Scenario.TRIAL and s != Scenario.TRIAL:
		hud.set_debug_visible(_debug_before_trial)
	_clear_drones()
	scenario = s
	health = start_health
	score = 0
	_elapsed = 0.0
	_spawn_timer = 0.0
	time_left = round_length_s
	message = ""
	player.reset_view()
	_set_state_playing()
	match s:
		Scenario.STATIONARY_REAR:
			_spawn_drone(DroneScript.Behavior.STATIONARY, showcase_bearing_deg, showcase_distance_m)
			message = "Find the drone and shoot it"
		Scenario.ORBIT:
			var d := _spawn_drone(DroneScript.Behavior.ORBITING, 90.0, orbit_radius_m)
			d.orbit_speed_deg = orbit_speed_deg
			message = "Follow the drone and shoot it"
		Scenario.HIDDEN_APPROACH:
			_spawn_drone(DroneScript.Behavior.APPROACHING, 180.0, spawn_radius_m)
			message = "Find the drone before it reaches you"
		Scenario.SURVIVAL:
			message = "Survive %d s" % int(round_length_s)
		Scenario.TRIAL:
			_start_trial()
	haptics.send_snapshot()


func _set_state_playing() -> void:
	state = "playing"
	get_tree().paused = false
	player.input_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _set_paused(paused: bool) -> void:
	if paused:
		state = "paused"
		get_tree().paused = true
		player.input_enabled = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		haptics.set_inactive("paused")
	else:
		_set_state_playing()


func _game_over(text: String) -> void:
	_finish_trial_file()
	state = "game_over"
	haptics_latch = false
	player.input_enabled = false
	_clear_drones()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	haptics.set_inactive("game_over")
	message = text + "\nPress R to restart or 1-5 for a scenario"


func _scenario_complete(text: String) -> void:
	message = "%s\nPress %d to repeat, or 1-5 for another scenario" % [text, scenario]


func _update_survival(delta: float) -> void:
	_elapsed += delta
	time_left = maxf(round_length_s - _elapsed, 0.0)
	if time_left <= 0.0:
		_game_over("Time! Score %d" % score)
		return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and drones.size() < max_live_drones:
		_spawn_timer = spawn_interval_s
		var d := _spawn_drone(DroneScript.Behavior.APPROACHING, _rng.randf_range(0.0, 360.0), spawn_radius_m)
		d.approach_speed_mps = minf(approach_speed_mps + speed_ramp_mps_per_s * _elapsed, max_approach_speed_mps)


# --- trial mode --------------------------------------------------------------

func _start_trial() -> void:
	_debug_before_trial = hud.is_debug_visible()
	hud.set_debug_visible(false)
	_trial_queue.clear()
	for i in trial_repeats:
		_trial_queue.append_array(trial_bearings_deg)
	_shuffle(_trial_queue)
	_trial_total = _trial_queue.size()
	_trial_errors.clear()
	_trial_gap_left = trial_gap_s
	_open_trial_file()
	message = "Direction trial: turn toward the vibration and click.\nTargets stay invisible."


func _update_trial(delta: float) -> void:
	if not drones.is_empty() or _trial_queue.is_empty():
		return
	_trial_gap_left -= delta
	if _trial_gap_left > 0.0:
		return
	_trial_bearing = _trial_queue.pop_back()
	var d := _spawn_drone(DroneScript.Behavior.STATIONARY, _trial_bearing, trial_distance_m)
	d.reveal_allowed = false
	d.set_hidden(true)
	_trial_started_ms = Time.get_ticks_msec()
	message = "Trial %d / %d" % [_trial_total - _trial_queue.size(), _trial_total]


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
	if _trial_queue.is_empty():
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
	hud.set_debug_visible(_debug_before_trial)
	_scenario_complete("Trial done: %d responses, mean abs error %.1f deg, %d within 22.5 deg\nSaved: %s" % [
		n, total / maxf(n, 1), within_octant, ProjectSettings.globalize_path(_trial_path)])


func _open_trial_file() -> void:
	DirAccess.make_dir_recursive_absolute("user://trials")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	_trial_path = "user://trials/trial_%s.csv" % stamp
	_trial_file = FileAccess.open(_trial_path, FileAccess.WRITE)
	if _trial_file == null:
		push_error("cannot write trial log %s (error %d)" % [_trial_path, FileAccess.get_open_error()])
		return
	_trial_file.store_line("session_id,trial,true_bearing_deg,response_bearing_deg,signed_error_deg,abs_error_deg,response_time_s,haptic_mode,haptics_enabled,bridge_status,output_backend,motor_angles_deg")


func _write_trial_row(response: float, signed_error: float, seconds: float) -> void:
	if _trial_file == null:
		return
	var t: Dictionary = haptics.telemetry
	var angles := " ".join(t.get("motor_angles_deg", []).map(func(a): return str(a)))
	_trial_file.store_line("%s,%d,%.1f,%.1f,%.1f,%.1f,%.3f,%s,%s,%s,%s,%s" % [
		haptics.session_id, _trial_errors.size(), _trial_bearing, response, signed_error,
		absf(signed_error), seconds, haptic_mode, haptics_latch,
		haptics.status_text().replace(",", ";"), t.get("output_backend", "none"), angles])
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
	haptics.set_state(state, haptics_latch, haptic_mode, _threat_targets())
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
	if drones.is_empty() and scenario in [Scenario.STATIONARY_REAR, Scenario.ORBIT, Scenario.HIDDEN_APPROACH]:
		_scenario_complete("Target destroyed")


func _on_drone_contacted(d: Area3D) -> void:
	_remove_drone(d)
	health -= 1
	_play("damage")
	if health <= 0:
		_game_over("Destroyed! Score %d" % score)
	elif drones.is_empty() and scenario == Scenario.HIDDEN_APPROACH:
		_scenario_complete("The drone reached you")


func _on_shot_fired(collider: Object) -> void:
	if state != "playing":
		return
	if scenario == Scenario.TRIAL:
		_record_trial_response()
		return
	_play("shot")
	if collider is Area3D and collider.is_in_group("drones") and collider.alive:
		collider.resolve_defeat()


func _update_reveals() -> void:
	for d in drones.values():
		if d.revealed or not d.reveal_allowed:
			continue
		var b = HapticsClient.horizontal_bearing_deg(player.view_basis(), player.global_position, d.global_position)
		if typeof(b) != TYPE_NIL and minf(b, 360.0 - b) <= reveal_cone_deg:
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
	var tag := "HIDDEN" if hidden_mode and scenario != Scenario.TRIAL else ""
	if state == "paused":
		tag = "PAUSED · ESC"
	var timer := time_left / round_length_s if scenario == Scenario.SURVIVAL else -1.0
	hud.update_round(SCENARIO_NAMES[scenario], tag, health, start_health, score, timer, time_left)
	hud.update_haptics(haptics_latch, state == "playing", haptic_mode, haptics.status_text(), haptics.telemetry)
	hud.show_message(message)

	if hud.is_debug_visible():
		hud.update_debug(_debug_text(), haptics.telemetry, haptics.last_known_angles, _threat_targets().map(func(t): return t["bearing_deg"]))


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


func _build_arena() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.05, 0.06, 0.1)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.55, 0.65)
	env.environment.ambient_light_energy = 0.6
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 0.9
	add_child(sun)

	_add_static_box(Vector3(40, 0.2, 40), Vector3(0, -0.1, 0), Color(0.22, 0.24, 0.28))
	# Pillars give rotation a visual reference; they carry no target information.
	for i in 12:
		var a := deg_to_rad(i * 30.0)
		var tall := i % 3 == 0
		var color := Color(0.35, 0.55, 0.85) if tall else Color(0.45, 0.47, 0.5)
		var height := 4.0 if tall else 2.5
		_add_static_box(Vector3(1, height, 1), Vector3(sin(a) * 16.0, height / 2.0, -cos(a) * 16.0), color)


func _add_static_box(size: Vector3, pos: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	box.material = mat
	mesh.mesh = box
	body.add_child(mesh)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	add_child(body)


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
