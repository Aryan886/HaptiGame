shader_type spatial;
// Defence platform floor: dark metal with emissive cyan grid lines and a rim.
// Lines are offset half a cell so none runs through the player's position.

uniform vec3 base_color : source_color = vec3(0.03, 0.045, 0.07);
uniform vec3 line_color : source_color = vec3(0.22, 0.88, 1.0);
uniform float cell_m = 1.0;
uniform float line_width_m = 0.025;
uniform float radius_m = 12.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid(vec2 p, float cell, float width) {
	vec2 d = abs(fract(p / cell) - 0.5) * cell;  // distance to the nearest line
	vec2 aa = fwidth(p);
	vec2 l = 1.0 - smoothstep(vec2(width) - aa, vec2(width) + aa, d);
	return max(l.x, l.y);
}

void fragment() {
	vec2 p = world_pos.xz;
	float r = length(p);
	float minor = grid(p, cell_m, line_width_m);
	float major = grid(p, cell_m * 4.0, line_width_m * 1.8);
	float fade = 1.0 - 0.6 * smoothstep(radius_m * 0.4, radius_m, r);
	float rim = 1.0 - smoothstep(0.05, 0.18, abs(r - (radius_m - 0.25)));
	ALBEDO = base_color;
	METALLIC = 0.5;
	ROUGHNESS = 0.35;
	EMISSION = line_color * (max(minor * 0.22, major * 0.6) * fade + rim * 1.2);
}
