#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec3 u_blush_primary;
uniform vec3 u_blush_secondary;
uniform float u_blush_strength;
uniform float u_blush_detail;
uniform vec4 u_blush_shape_a;
uniform vec4 u_blush_shape_b;
uniform vec2 u_rotation;
uniform vec2 u_blush_side_strength;
uniform vec3 u_eye_primary;
uniform vec3 u_eye_secondary;
uniform float u_eye_strength;
uniform float u_eye_detail;
uniform vec4 u_eye_shape_a;
uniform vec4 u_eye_shape_b;
uniform vec2 u_eye_side_strength;
uniform sampler2D u_texture;

out vec4 frag_color;

vec3 soft_light(vec3 base, vec3 blend) {
  vec3 low = base - (1.0 - 2.0 * blend) * base * (1.0 - base);
  vec3 high = base + (2.0 * blend - 1.0) * (sqrt(max(base, 0.0)) - base);
  return mix(low, high, step(vec3(0.5), blend));
}

float ellipse_mask(
  vec2 screen_uv,
  vec4 shape,
  mat2 inverse_rotation,
  float feather_start
) {
  vec2 delta = inverse_rotation * ((screen_uv - shape.xy) * u_size);
  float distance_to_center = length(
    delta / max(shape.zw * u_size, vec2(0.5))
  );
  return 1.0 - smoothstep(feather_start, 1.0, distance_to_center);
}

vec3 apply_material(
  vec3 base,
  vec3 primary,
  vec3 secondary,
  float strength,
  float detail,
  float mask,
  float mode
) {
  float luminance = dot(base, vec3(0.2126, 0.7152, 0.0722));
  vec3 pigment = mix(primary, secondary, smoothstep(0.28, 0.72, luminance));
  vec3 soft = soft_light(base, pigment);
  vec3 multiplied = base * mix(vec3(1.0), pigment * 1.45, 0.42);
  vec3 material = mix(soft, multiplied, mode);
  float chroma = max(base.r, max(base.g, base.b)) - min(base.r, min(base.g, base.b));
  float skin_guard = 1.0 - smoothstep(0.32, 0.62, chroma);
  float coverage = clamp(strength, 0.0, 0.48) *
    mix(skin_guard, 1.0, 0.36) * mask;
  vec3 result = mix(base, material, coverage);
  float natural_highlight = smoothstep(0.58, 0.86, luminance) * detail;
  return mix(result, base + (1.0 - base) * 0.08, natural_highlight * 0.16 * mask);
}

void main() {
  vec2 screen_uv = FlutterFragCoord().xy / u_size;
  vec2 uv = screen_uv;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec4 source = texture(u_texture, uv);
  mat2 inverse_rotation = mat2(
    u_rotation.x, -u_rotation.y,
    u_rotation.y, u_rotation.x
  );

  float blush_a = ellipse_mask(screen_uv, u_blush_shape_a, inverse_rotation, 0.48) *
    u_blush_side_strength.x;
  float blush_b = ellipse_mask(screen_uv, u_blush_shape_b, inverse_rotation, 0.48) *
    u_blush_side_strength.y;
  float blush_mask = max(blush_a, blush_b);

  float eye_a = ellipse_mask(screen_uv, u_eye_shape_a, inverse_rotation, 0.66) *
    u_eye_side_strength.x;
  float eye_b = ellipse_mask(screen_uv, u_eye_shape_b, inverse_rotation, 0.66) *
    u_eye_side_strength.y;
  float eye_mask = max(eye_a, eye_b);

  vec3 result = apply_material(
    source.rgb,
    u_blush_primary,
    u_blush_secondary,
    u_blush_strength,
    u_blush_detail,
    blush_mask,
    0.0
  );
  result = apply_material(
    result,
    u_eye_primary,
    u_eye_secondary,
    u_eye_strength,
    u_eye_detail,
    eye_mask,
    1.0
  );
  frag_color = vec4(clamp(result, 0.0, 1.0), source.a);
}
