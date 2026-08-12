#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec3 u_primary;
uniform vec3 u_secondary;
uniform float u_strength;
uniform float u_mode;
uniform float u_detail;
uniform vec4 u_shape_a;
uniform vec4 u_shape_b;
uniform vec2 u_rotation;
uniform vec2 u_side_strength;
uniform sampler2D u_texture;

out vec4 frag_color;

vec3 soft_light(vec3 base, vec3 blend) {
  vec3 low = base - (1.0 - 2.0 * blend) * base * (1.0 - base);
  vec3 high = base + (2.0 * blend - 1.0) * (sqrt(max(base, 0.0)) - base);
  return mix(low, high, step(vec3(0.5), blend));
}

void main() {
  vec2 screen_uv = FlutterFragCoord().xy / u_size;
  vec2 uv = screen_uv;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec4 source = texture(u_texture, uv);
  vec3 base = source.rgb;
  float luminance = dot(base, vec3(0.2126, 0.7152, 0.0722));
  vec3 pigment = mix(u_primary, u_secondary, smoothstep(0.28, 0.72, luminance));
  vec3 soft = soft_light(base, pigment);
  vec3 multiplied = base * mix(vec3(1.0), pigment * 1.45, 0.42);
  vec3 material = mix(soft, multiplied, step(0.5, u_mode));
  float chroma = max(base.r, max(base.g, base.b)) - min(base.r, min(base.g, base.b));
  float skin_guard = 1.0 - smoothstep(0.32, 0.62, chroma);
  mat2 inverse_rotation = mat2(
    u_rotation.x, -u_rotation.y,
    u_rotation.y, u_rotation.x
  );
  // Work in physical pixels before rotation. Rotating normalized UVs directly
  // distorts the ellipse on portrait camera surfaces.
  vec2 shape_a_delta = inverse_rotation * ((screen_uv - u_shape_a.xy) * u_size);
  vec2 shape_b_delta = inverse_rotation * ((screen_uv - u_shape_b.xy) * u_size);
  float shape_a_distance = length(
    shape_a_delta / max(u_shape_a.zw * u_size, vec2(0.5))
  );
  float shape_b_distance = length(
    shape_b_delta / max(u_shape_b.zw * u_size, vec2(0.5))
  );
  float feather_start = mix(0.48, 0.66, step(0.5, u_mode));
  float material_mask = max(
    (1.0 - smoothstep(feather_start, 1.0, shape_a_distance)) * u_side_strength.x,
    (1.0 - smoothstep(feather_start, 1.0, shape_b_distance)) * u_side_strength.y
  );
  float coverage = clamp(u_strength, 0.0, 0.48) *
    mix(skin_guard, 1.0, 0.36) * material_mask;
  vec3 result = mix(base, material, coverage);
  float natural_highlight = smoothstep(0.58, 0.86, luminance) * u_detail;
  result = mix(result, base + (1.0 - base) * 0.08, natural_highlight * 0.16);
  frag_color = vec4(clamp(result, 0.0, 1.0), source.a);
}
