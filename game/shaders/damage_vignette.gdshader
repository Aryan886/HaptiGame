shader_type canvas_item;
// Damage flash: a red vignette that is radially symmetric, so every screen
// edge flashes equally and the flash never hints at a direction.

uniform float strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 tint : source_color = vec4(1.0, 0.23, 0.23, 0.85);

void fragment() {
	float r = length((UV - 0.5) * 2.0);  // 0 at the centre, 1 at edge midpoints
	float v = smoothstep(0.55, 1.35, r);
	COLOR = vec4(tint.rgb, tint.a * v * strength);
}
