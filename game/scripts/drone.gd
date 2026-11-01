extends Area3D
## One drone scene with three behaviors. Resolution (defeat or contact) happens
## exactly once: alive is cleared and collision disabled before any signal.

signal defeated(drone: Area3D)
signal contacted(drone: Area3D)

enum Behavior { STATIONARY, APPROACHING, ORBITING }

const BEHAVIOR_NAMES := ["stationary", "approaching", "orbiting"]

var drone_id := ""
var behavior := Behavior.STATIONARY
var approach_speed_mps := 1.5
var contact_radius_m := 1.0
## Positive values move clockwise as seen from above (increasing bearing).
var orbit_speed_deg := 30.0
var center := Vector3.ZERO
var alive := true
var revealed := true
## False keeps the drone invisible for its whole life (trial mode).
var reveal_allowed := true

var _orbit_angle_deg := 0.0
var _orbit_radius_m := 0.0

@onready var mesh: MeshInstance3D = $mesh
@onready var shape: CollisionShape3D = $shape


func _ready() -> void:
	mesh.visible = revealed


## Place the drone at a world-clockwise angle (0 = world -Z) and radius
## around `center`, at camera height.
func place(world_angle_deg: float, radius_m: float, height_m: float) -> void:
	_orbit_angle_deg = world_angle_deg
	_orbit_radius_m = radius_m
	position = center + _circle_offset(world_angle_deg, radius_m) + Vector3(0, height_m, 0)


func set_hidden(is_hidden: bool) -> void:
	revealed = not is_hidden
	if is_node_ready():
		mesh.visible = revealed


func reveal() -> void:
	if alive and reveal_allowed and not revealed:
		revealed = true
		mesh.visible = true


func behavior_name() -> String:
	return BEHAVIOR_NAMES[behavior]


func horizontal_distance() -> float:
	var offset := position - center
	offset.y = 0.0
	return offset.length()


## Seconds until contact for a directly approaching drone, otherwise null.
func time_to_contact() -> Variant:
	if behavior != Behavior.APPROACHING or approach_speed_mps <= 0.0:
		return null
	return maxf(horizontal_distance() - contact_radius_m, 0.0) / approach_speed_mps


func _physics_process(delta: float) -> void:
	if not alive:
		return
	match behavior:
		Behavior.APPROACHING:
			var offset := center - position
			offset.y = 0.0
			var step := approach_speed_mps * delta
			if offset.length() > step:
				position += offset.normalized() * step
			else:
				position += offset
			if horizontal_distance() <= contact_radius_m:
				resolve_contact()
		Behavior.ORBITING:
			_orbit_angle_deg = fposmod(_orbit_angle_deg + orbit_speed_deg * delta, 360.0)
			var height := position.y
			position = center + _circle_offset(_orbit_angle_deg, _orbit_radius_m)
			position.y = height


func resolve_defeat() -> bool:
	if not _resolve():
		return false
	defeated.emit(self)
	queue_free()
	return true


func resolve_contact() -> bool:
	if not _resolve():
		return false
	contacted.emit(self)
	queue_free()
	return true


func _resolve() -> bool:
	if not alive:
		return false
	alive = false
	collision_layer = 0
	set_deferred("monitorable", false)
	shape.set_deferred("disabled", true)
	return true


static func _circle_offset(world_angle_deg: float, radius_m: float) -> Vector3:
	var a := deg_to_rad(world_angle_deg)
	return Vector3(sin(a), 0.0, -cos(a)) * radius_m
