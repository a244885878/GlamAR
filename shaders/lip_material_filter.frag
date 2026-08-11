#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec3 u_color;
uniform float u_strength;
uniform float u_finish;
uniform sampler2D u_texture;

out vec4 frag_color;

vec3 sample_input(vec2 uv) {
  return texture(u_texture, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  vec4 source = texture(u_texture, uv);
  vec3 center = source.rgb;
  vec2 pixel = vec2(1.0) / u_size;
  vec3 local_average = (
    sample_input(uv + vec2(pixel.x, 0.0)) +
    sample_input(uv - vec2(pixel.x, 0.0)) +
    sample_input(uv + vec2(0.0, pixel.y)) +
    sample_input(uv - vec2(0.0, pixel.y))
  ) * 0.25;

  float luminance = dot(center, vec3(0.2126, 0.7152, 0.0722));
  vec3 lip_detail = (center - local_average) * 0.82;
  vec3 pigment = u_color * (0.38 + luminance * 0.82) + lip_detail;
  float coverage = clamp(u_strength, 0.0, 1.0) * 0.72;
  vec3 result = mix(center, pigment, coverage);

  // 缎光和镜面只增强原本就存在的唇部高光，不绘制固定白色贴片。
  float natural_highlight = smoothstep(0.48, 0.82, luminance);
  result += natural_highlight * u_finish * 0.075;
  frag_color = vec4(clamp(result, 0.0, 1.0), source.a);
}
