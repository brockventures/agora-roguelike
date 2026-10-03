shader_type canvas_item;

// CRT Retro Shader for Agora Roguelike (Steam Deck 1280x800) (#23)
// Stylized retro-futuristic CRT scanlines, phosphor glow, curvature, and chromatic aberration.

uniform float scanline_count : hint_range(100.0, 1200.0, 10.0) = 400.0;
uniform float scanline_intensity : hint_range(0.0, 1.0, 0.05) = 0.25;
uniform float curvature : hint_range(0.0, 0.2, 0.005) = 0.03;
uniform float vignette_intensity : hint_range(0.0, 2.0, 0.05) = 0.4;
uniform float vignette_opacity : hint_range(0.0, 1.0, 0.05) = 0.5;
uniform float aberration_amount : hint_range(0.0, 0.02, 0.001) = 0.003;
uniform float phosphor_glow : hint_range(0.0, 1.0, 0.05) = 0.15;
uniform float flicker_speed : hint_range(0.0, 50.0, 1.0) = 15.0;
uniform float flicker_intensity : hint_range(0.0, 0.1, 0.005) = 0.015;
uniform vec4 phosphor_tint : source_color = vec4(0.92, 1.0, 0.94, 1.0);
uniform bool enabled = true;

vec2 curve(vec2 uv) {
	vec2 delta = uv - 0.5;
	float dist = dot(delta, delta);
	return uv + delta * dist * curvature * 4.0;
}

void fragment() {
	if (!enabled) {
		COLOR = texture(TEXTURE, UV);
	} else {
		vec2 curved_uv = curve(UV);

		// Screen edge clipping for tube curvature
		if (curved_uv.x < 0.0 || curved_uv.x > 1.0 || curved_uv.y < 0.0 || curved_uv.y > 1.0) {
			COLOR = vec4(0.0, 0.0, 0.0, 1.0);
		} else {
			// Chromatic aberration (RGB split)
			float r = texture(TEXTURE, curved_uv + vec2(aberration_amount, 0.0)).r;
			float g = texture(TEXTURE, curved_uv).g;
			float b = texture(TEXTURE, curved_uv - vec2(aberration_amount, 0.0)).b;
			float a = texture(TEXTURE, curved_uv).a;
			vec4 col = vec4(r, g, b, a);

			// Phosphor boost
			col.rgb += col.rgb * phosphor_glow;

			// Scanlines
			float scanline = sin(curved_uv.y * scanline_count * 3.14159265);
			scanline = (scanline + 1.0) * 0.5;
			col.rgb -= col.rgb * scanline * scanline_intensity;

			// Subtle high-frequency flicker
			float flicker = sin(TIME * flicker_speed) * flicker_intensity;
			col.rgb += col.rgb * flicker;

			// Edge vignette
			vec2 vig_uv = curved_uv * (1.0 - curved_uv.yx);
			float vig = vig_uv.x * vig_uv.y * 15.0;
			vig = clamp(pow(vig, vignette_intensity), 0.0, 1.0);
			col.rgb = mix(col.rgb * vig, col.rgb, 1.0 - vignette_opacity);

			// Phosphor monitor tint
			col.rgb *= phosphor_tint.rgb;

			COLOR = col;
		}
	}
}
