extends Node
## Sends version-1 threat_snapshot packets to the haptic bridge and reads its
## motor_state telemetry. Owns no motor mapping, arbitration or serial logic:
## the game only reports camera-yaw-relative bearings of known in-game targets.

signal telemetry_changed

const SCHEMA_VERSION := 1
const MAX_TARGETS := 16
const MAX_DATAGRAM_BYTES := 4096
const TELEMETRY_STALE_MS := 250
const GAME_STATES := ["playing", "paused", "game_over"]
const LINK_STATES := ["simulated", "ready", "disconnected", "stale", "error"]
const OUTPUT_BACKENDS := ["simulator", "serial", "fake_serial"]

@export var bridge_host := "127.0.0.1"
@export var bridge_port := 9000
@export var telemetry_port := 9001
@export var send_hz := 20.0

var session_id := ""
var game_state := "paused"
var haptics_enabled := false
var haptic_mode := "interpolated"
var targets: Array = []
## Health lost in this session. A counter, not an event flag, so a dropped
## datagram cannot lose a hit; the bridge buzzes all motors when it rises.
var damage_count := 0

## Latest accepted telemetry, or an empty Dictionary if none is fresh.
var telemetry: Dictionary = {}
## Last layout the bridge reported in this run; kept only to draw grey markers.
var last_known_angles: Array = []
## Last output backend the bridge reported in this run ("" if none yet).
var last_known_backend := ""
var socket_error := ""

var _udp := PacketPeerUDP.new()
var _seq := 0
var _send_accumulator := 0.0
var _last_telemetry_ms := -1
var _last_input_seq := -1
var _was_fresh := false
var _last_error_log_ms := -100000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var err := _udp.bind(telemetry_port, "127.0.0.1")
	if err != OK:
		socket_error = "cannot bind telemetry port %d (error %d); is another game instance running?" % [telemetry_port, err]
		push_error(socket_error)
	else:
		_udp.set_dest_address(bridge_host, bridge_port)
	start_new_session()


func _exit_tree() -> void:
	# Best effort; the bridge watchdog covers crashes.
	set_inactive("paused")
	_udp.close()


func _process(delta: float) -> void:
	_poll_telemetry()
	_send_accumulator += delta
	var interval := 1.0 / send_hz
	if _send_accumulator >= interval:
		_send_accumulator = fmod(_send_accumulator, interval)
		send_snapshot()
	var fresh := is_telemetry_fresh()
	if fresh != _was_fresh:
		_was_fresh = fresh
		if not fresh:
			telemetry = {}
		telemetry_changed.emit()


## Fresh opaque session ID; sequence restarts. The bridge treats this as a new
## producer and stays disarmed until it sees disabled followed by enabled.
func start_new_session() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	session_id = "game_%d_%06x" % [Time.get_unix_time_from_system(), rng.randi() & 0xFFFFFF]
	_seq = 0
	_last_input_seq = -1
	telemetry = {}
	_last_telemetry_ms = -1
	haptics_enabled = false
	targets = []
	damage_count = 0
	telemetry_changed.emit()


func set_state(new_game_state: String, enabled: bool, mode: String, new_targets: Array) -> void:
	assert(new_game_state in GAME_STATES)
	game_state = new_game_state
	haptics_enabled = enabled
	haptic_mode = mode
	targets = new_targets


## Clear output now: inactive snapshot with no targets, sent immediately.
func set_inactive(new_game_state: String) -> void:
	game_state = new_game_state
	haptics_enabled = false
	targets = []
	send_snapshot()


func send_snapshot() -> void:
	if socket_error != "":
		return
	var active := game_state == "playing" and haptics_enabled
	var packet := {
		"schema_version": SCHEMA_VERSION,
		"type": "threat_snapshot",
		"session_id": session_id,
		"seq": _seq,
		"source": "game_state",
		"reference_frame": "camera_yaw",
		"game_state": game_state,
		"haptics_enabled": active,
		"haptic_mode": haptic_mode,
		"targets": _bounded_targets() if game_state == "playing" else [],
		"damage_count": damage_count,
	}
	var bytes := JSON.stringify(packet).to_utf8_buffer()
	if bytes.size() > MAX_DATAGRAM_BYTES:
		_log_error("snapshot of %d bytes exceeds %d; not sent" % [bytes.size(), MAX_DATAGRAM_BYTES])
		return
	_seq += 1
	var err := _udp.put_packet(bytes)
	# Success only means the OS accepted the datagram, not that a bridge exists.
	if err != OK:
		_log_error("UDP send to %s:%d failed (error %d)" % [bridge_host, bridge_port, err])


func last_sent_seq() -> int:
	return _seq - 1


func is_telemetry_fresh() -> bool:
	return _last_telemetry_ms >= 0 and Time.get_ticks_msec() - _last_telemetry_ms <= TELEMETRY_STALE_MS


## True while the bridge reports the all-motor damage buzz.
func pulse_active() -> bool:
	return telemetry.get("pulse_active", false) == true


func status_text() -> String:
	if socket_error != "":
		return "telemetry socket error"
	if not is_telemetry_fresh():
		return "bridge unavailable"
	match telemetry.get("link_state", ""):
		"simulated":
			return "simulated output"
		"ready":
			if telemetry.get("output_backend") == "fake_serial":
				return "fake serial device (no hardware)"
			return "serial ready (commands acknowledged, vibration not measured)"
		var other:
			return "serial %s" % other


func _bounded_targets() -> Array:
	var list := targets.duplicate()
	if list.size() > MAX_TARGETS:
		list.sort_custom(func(a, b): return a["distance_m"] < b["distance_m"])
		list.resize(MAX_TARGETS)
	return list


func _poll_telemetry() -> void:
	if socket_error != "":
		return
	var newest: Dictionary = {}
	while _udp.get_available_packet_count() > 0:
		var bytes := _udp.get_packet()
		if bytes.size() > MAX_DATAGRAM_BYTES:
			_log_error("telemetry datagram too large (%d bytes)" % bytes.size())
			continue
		var parsed = JSON.parse_string(bytes.get_string_from_utf8())
		var problem := _telemetry_problem(parsed)
		if problem != "":
			_log_error("ignored telemetry: " + problem)
			continue
		if not parsed["session_id"] in [session_id]:
			continue
		if int(parsed["input_seq"]) < _last_input_seq:
			continue
		_last_input_seq = int(parsed["input_seq"])
		newest = parsed
	if not newest.is_empty():
		telemetry = newest
		last_known_angles = newest["motor_angles_deg"]
		last_known_backend = newest["output_backend"]
		_last_telemetry_ms = Time.get_ticks_msec()
		telemetry_changed.emit()


func _telemetry_problem(msg) -> String:
	if typeof(msg) != TYPE_DICTIONARY:
		return "not a JSON object"
	if not _is_number(msg.get("schema_version")) or float(msg["schema_version"]) != 1.0:
		return "wrong schema_version"
	if not msg.get("type") in ["motor_state"]:
		return "wrong type"
	if typeof(msg.get("session_id")) != TYPE_STRING:
		return "missing session_id"
	if not _is_number(msg.get("input_seq")) or msg["input_seq"] < 0:
		return "bad input_seq"
	if not msg.get("output_backend") in OUTPUT_BACKENDS or not msg.get("link_state") in LINK_STATES:
		return "unknown backend or link_state"
	if typeof(msg.get("output_enabled")) != TYPE_BOOL:
		return "bad output_enabled"
	var angles = msg.get("motor_angles_deg")
	var levels = msg.get("motor_levels")
	if typeof(angles) != TYPE_ARRAY or typeof(levels) != TYPE_ARRAY:
		return "missing layout arrays"
	if angles.is_empty() or angles.size() != levels.size() or angles.size() > 64:
		return "layout arrays have mismatched or invalid sizes"
	for a in angles:
		if not _is_number(a) or a < 0.0 or a >= 360.0:
			return "bad motor angle"
	for l in levels:
		if not _is_number(l) or l < 0.0 or l > 1.0:
			return "bad motor level"
	if msg.has("pulse_active") and typeof(msg["pulse_active"]) != TYPE_BOOL:
		return "bad pulse_active"
	var b = msg.get("bearing_deg")
	if typeof(b) != TYPE_NIL and (not _is_number(b) or b < 0.0 or b >= 360.0):
		return "bad bearing_deg"
	return ""


func _is_number(v) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


func _log_error(message: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_error_log_ms >= 2000:
		_last_error_log_ms = now
		push_warning("haptics_client: " + message)


## Horizontal bearing in [0, 360), clockwise from the view's forward (-Z),
## or null when the target has no horizontal offset. Pitch in `view_basis`
## is discarded by flattening forward onto the horizontal plane.
static func horizontal_bearing_deg(view_basis: Basis, origin: Vector3, target: Vector3) -> Variant:
	var offset := target - origin
	offset.y = 0.0
	var distance := offset.length()
	if distance < 0.001:
		return null
	var forward := -view_basis.z
	forward.y = 0.0
	if forward.length() < 0.001:
		return null
	forward = forward.normalized()
	var right := Vector3(-forward.z, 0.0, forward.x)
	var direction := offset / distance
	var angle := rad_to_deg(atan2(direction.dot(right), direction.dot(forward)))
	var bearing := snappedf(fposmod(angle, 360.0), 0.0001)
	if bearing >= 360.0:
		bearing = 0.0
	return bearing


static func horizontal_distance(origin: Vector3, target: Vector3) -> float:
	var offset := target - origin
	offset.y = 0.0
	return offset.length()
