#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform float u_strength;
uniform vec3 u_tone;
uniform float u_tone_amount;
uniform float u_texture_retention;
uniform float u_exposure;
uniform float u_skin_chroma;
uniform float u_local_contrast;
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
  // 复用已有 9 次采样做频率分离，不增加纹理读取。低能量色斑适度
  // 均匀化，毛孔、细纹和五官边缘等高能量细节则更完整地回填。
  vec3 high_frequency = center - edge_aware;
  float detail_energy = dot(abs(high_frequency), vec3(0.3333));
  float exposure_guard = smoothstep(0.16, 0.52, u_exposure);
  float contrast_guard = smoothstep(0.035, 0.18, u_local_contrast);
  float chroma_guard = smoothstep(0.035, 0.2, u_skin_chroma);
  float protected_retention = clamp(
    u_texture_retention + (1.0 - contrast_guard) * 0.065,
    0.56,
    0.93
  );
  float adaptive_retention = mix(
    protected_retention,
    0.94,
    smoothstep(0.012, 0.07, detail_energy)
  );
  vec3 refined = edge_aware + high_frequency * adaptive_retention;
  float environment_guard = mix(0.82, 1.0, exposure_guard) *
    mix(0.86, 1.0, contrast_guard);
  vec3 result = mix(
    center,
    refined,
    clamp(u_strength * environment_guard, 0.0, 0.34)
  );

  float luminance = dot(result, vec3(0.2126, 0.7152, 0.0722));
  // GLSL 对 edge0 >= edge1 的 smoothstep 结果未定义；显式反转确保
  // Android GLES 与 iOS Metal 转译后的暗部保护完全一致。
  float shadow_mask = 1.0 - smoothstep(0.12, 0.62, luminance);
  vec3 toned = result * mix(vec3(1.0), 0.82 + u_tone * 0.34, shadow_mask);
  float tone_guard = environment_guard * mix(0.9, 1.0, chroma_guard);
  result = mix(
    result,
    toned,
    clamp(u_tone_amount * tone_guard, 0.0, 0.12)
  );
  frag_color = vec4(clamp(result, 0.0, 1.0), source.a);
}
