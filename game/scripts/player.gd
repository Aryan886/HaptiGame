extends Node3D
## Fixed-position first-person view. This node is the unscaled yaw-only root
## used as the haptic reference; pitch lives on the child pivot.

signal shot_fired(collider: Object)

@export var mouse_sensitivity := 0.0025
@export var max_pitch_deg := 60.0
@export var shot_cooldown_s := 0.2
@export var weapon_range_m := 25.0

@onready var pitch_pivot: Node3D = $pitch_pivot
@onready var camera: Camera3D = $pitch_pivot/camera
@onready var ray: RayCast3D = $pitch_pivot/camera/ray

var input_enabled := false
## World point where the last shot ended: the hit, or the end of its range.
var last_shot_end := Vector3.ZERO
var _cooldown := 0.0


func _ready() -> void:
	ray.target_position = Vector3(0, 0, -weapon_range_m)


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-(event as InputEventMouseMotion).relative.x * mouse_sensitivity)
		var pitch: float = pitch_pivot.rotation.x - event.relative.y * mouse_sensitivity
		var limit := deg_to_rad(max_pitch_deg)
		pitch_pivot.rotation.x = clampf(pitch, -limit, limit)
	elif event.is_action_pressed("shoot") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		try_shoot()


func try_shoot() -> void:
	if _cooldown > 0.0:
		return
	_cooldown = shot_cooldown_s
	# Ray results are cached between physics steps; refresh after camera motion.
	ray.force_raycast_update()
	last_shot_end = ray.get_collision_point() if ray.is_colliding() else ray.to_global(ray.target_position)
	shot_fired.emit(ray.get_collider() if ray.is_colliding() else null)


## Where shot effects start: just below and right of the camera.
func muzzle_position() -> Vector3:
	return camera.to_global(Vector3(0.1, -0.13, -0.5))


## Yaw-only view basis used for haptic bearings.
func view_basis() -> Basis:
	return global_basis


func reset_view() -> void:
	rotation = Vector3.ZERO
	pitch_pivot.rotation = Vector3.ZERO
