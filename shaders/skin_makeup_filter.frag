#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform float u_strength;
uniform vec3 u_tone;
uniform float u_tone_amount;
uniform sampler2D u_texture;

out vec4 frag_color;

vec3 sample_input(vec2 uv) {
  return texture(u_texture, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

float edge_weight(vec3 center, vec3 sample_color) {
  vec3 difference = center - sample_color;
  return exp(-dot(difference, difference) * 46.0);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  vec4 source = texture(u_texture, uv);
  vec3 center = source.rgb;
  vec2 pixel = vec2(1.25) / u_size;

  vec3 accumulated = center * 1.8;
  float total_weight = 1.8;
  vec3 nearby = sample_input(uv + vec2(-pixel.x, 0.0));
  float weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;
  nearby = sample_input(uv + vec2(pixel.x, 0.0));
  weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;
  nearby = sample_input(uv + vec2(0.0, -pixel.y));
  weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;
  nearby = sample_input(uv + vec2(0.0, pixel.y));
  weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;
  nearby = sample_input(uv + vec2(-pixel.x, -pixel.y));
  weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;
  nearby = sample_input(uv + vec2(pixel.x, -pixel.y));
  weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;
  nearby = sample_input(uv + vec2(-pixel.x, pixel.y));
  weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;
  nearby = sample_input(uv + vec2(pixel.x, pixel.y));
  weight = edge_weight(center, nearby);
  accumulated += nearby * weight;
  total_weight += weight;

  vec3 edge_aware = accumulated / total_weight;
  // 大部分高频皮肤纹理被加回，避免传统高斯磨皮的塑料感。
  vec3 refined = edge_aware + (center - edge_aware) * 0.72;
  vec3 result = mix(center, refined, clamp(u_strength, 0.0, 0.34));

  float luminance = dot(result, vec3(0.2126, 0.7152, 0.0722));
  float shadow_mask = smoothstep(0.62, 0.12, luminance);
  vec3 toned = result * mix(vec3(1.0), 0.82 + u_tone * 0.34, shadow_mask);
  result = mix(result, toned, clamp(u_tone_amount, 0.0, 0.12));
  frag_color = vec4(clamp(result, 0.0, 1.0), source.a);
}
