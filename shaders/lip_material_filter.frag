#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec3 u_color;
uniform float u_strength;
uniform float u_finish;
uniform float u_detail;
uniform float u_mouth_openness;
uniform sampler2D u_texture;

out vec4 frag_color;

vec3 sample_input(vec2 uv) {
  return texture(u_texture, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

vec3 soft_light(vec3 base, vec3 blend) {
  vec3 low = base - (1.0 - 2.0 * blend) * base * (1.0 - base);
  vec3 high = base + (2.0 * blend - 1.0) * (sqrt(max(base, 0.0)) - base);
  return mix(low, high, step(vec3(0.5), blend));
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
  float local_luminance = dot(local_average, vec3(0.2126, 0.7152, 0.0722));
  vec3 high_frequency = center - local_average;
  vec3 lit_pigment = u_color * (0.42 + luminance * 0.78);
  vec3 soft_pigment = soft_light(center, mix(u_color, lit_pigment, 0.56));
  vec3 multiplied = center * mix(vec3(1.0), u_color * 1.58, 0.38);
  vec3 material = mix(soft_pigment, multiplied, 0.34);
  float coverage = clamp(u_strength, 0.0, 1.0) *
    mix(0.58, 0.72, clamp(u_detail, 0.0, 1.0));
  vec3 result = mix(center, material, coverage);

  // 以原始唇纹的局部高频作为材质法线的近似。哑光只轻微柔化，水光
  // 完整保留纹理；任何档位都不制造固定在屏幕上的高光贴片。
  float detail_energy = dot(abs(high_frequency), vec3(0.3333));
  float texture_retention = mix(0.7, 0.94, u_finish);
  texture_retention = mix(
    texture_retention,
    0.98,
    smoothstep(0.018, 0.075, detail_energy)
  );
  result += high_frequency * texture_retention * coverage;

  float local_highlight = max(luminance - local_luminance, 0.0);
  float natural_highlight = smoothstep(0.012, 0.11, local_highlight) *
    smoothstep(0.36, 0.82, luminance);
  float gloss_stability = 1.0 - clamp(u_mouth_openness, 0.0, 1.0) * 0.34;
  result += natural_highlight * u_finish * gloss_stability * 0.085;
  frag_color = vec4(clamp(result, 0.0, 1.0), source.a);
}
