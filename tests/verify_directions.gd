extends SceneTree
## Game-side bearing checks against tests/direction_cases.json.
## Run: godot --headless --path game --script ../tests/verify_directions.gd

const HapticsClient := preload("res://scripts/haptics_client.gd")
const DroneScript := preload("res://scripts/drone.gd")
const GameScript := preload("res://scripts/game.gd")

var failures := 0
var checks := 0


func _init() -> void:
	var fixture_path := ProjectSettings.globalize_path("res://").path_join("../tests/direction_cases.json").simplify_path()
	var text := FileAccess.get_file_as_string(fixture_path)
	if text == "":
		printerr("cannot read fixtures at %s" % fixture_path)
		quit(2)
		return
	var fixtures: Dictionary = JSON.parse_string(text)
	var origin := Vector3.ZERO

	for case in fixtures["bearing_cases"]:
		var yaw := Basis(Vector3.UP, -deg_to_rad(case["yaw_deg"]))
		var camera := yaw * Basis(Vector3.RIGHT, deg_to_rad(case["pitch_deg"]))
		var t: Array = case["target"]
		var target := Vector3(t[0], t[1], t[2])
		for basis_name in ["yaw_root", "pitched_camera"]:
			var b = HapticsClient.horizontal_bearing_deg(yaw if basis_name == "yaw_root" else camera, origin, target)
			_expect_bearing("%s (%s)" % [case["name"], basis_name], b, case["expected_bearing_deg"])

	# Spawning at a view-relative bearing must report that bearing back.
	for yaw_deg in [0.0, 37.0, 90.0, 200.0, 359.0]:
		var yaw := Basis(Vector3.UP, -deg_to_rad(yaw_deg))
		var f := -yaw.z
		var view_world := rad_to_deg(atan2(f.x, -f.z))
		for bearing in [0.0, 45.0, 135.0, 180.0, 300.0]:
			var pos := DroneScript._circle_offset(view_world + bearing, 6.0) + Vector3(0, 1.6, 0)
			_expect_bearing("spawn yaw %s bearing %s" % [yaw_deg, bearing], HapticsClient.horizontal_bearing_deg(yaw, origin, pos), bearing)

	# Trial signed error wraps into [-180, 180).
	for pair in [[10.0, 10.0], [350.0, -10.0], [180.0, -180.0], [-190.0, 170.0]]:
		_expect_close("wrap180(%s)" % pair[0], GameScript._wrap180(pair[0]), pair[1])

	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _expect_bearing(label: String, got, want) -> void:
	checks += 1
	if want == null:
		if got != null:
			_fail(label, got, want)
		return
	if got == null:
		_fail(label, got, want)
		return
	var diff := absf(fposmod(float(got) - float(want) + 180.0, 360.0) - 180.0)
	if diff > 0.001 or float(got) < 0.0 or float(got) >= 360.0:
		_fail(label, got, want)


func _expect_close(label: String, got: float, want: float) -> void:
	checks += 1
	if absf(got - want) > 0.0001:
		_fail(label, got, want)


func _fail(label: String, got, want) -> void:
	failures += 1
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
