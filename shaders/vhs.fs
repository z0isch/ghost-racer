#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform float u_time;
uniform vec2 u_resolution;

out vec4 finalColor;

// Rotate hue by `a` radians (Rodrigues rotation around the gray axis).
vec3 hue_shift(vec3 color, float a) {
  const vec3 k = vec3(0.57735);
  float c = cos(a);
  return color * c + cross(k, color) * sin(a) + k * dot(k, color) * (1.0 - c);
}

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Bloom tuning: what counts as "bright", how far it spreads, how strong.
const float BLOOM_LO       = 0.45;
const float BLOOM_HI       = 0.95;
const float BLOOM_RADIUS   = 1.1; // in game pixels; outer ring is 2x
const float BLOOM_STRENGTH = 0.6;

// Keep only what's bright enough to glow (soft knee, not a hard cut).
vec3 bloom_tap(vec2 uv) {
  vec3 s = texture(texture0, uv).rgb;
  float lum = dot(s, vec3(0.299, 0.587, 0.114));
  return s * smoothstep(BLOOM_LO, BLOOM_HI, lum);
}

// Two 6-tap rings (outer rotated 30 deg) around a center tap.
vec3 bloom(vec2 uv, vec2 texel) {
  vec3 acc = bloom_tap(uv);
  for (int i = 0; i < 6; i++) {
    float a = float(i) * 1.0471976;
    vec2 dir = vec2(cos(a), sin(a));
    vec2 dir2 = vec2(cos(a + 0.5235988), sin(a + 0.5235988));
    acc += bloom_tap(uv + dir * texel * BLOOM_RADIUS);
    acc += bloom_tap(uv + dir2 * texel * BLOOM_RADIUS * 2.0) * 0.6;
  }
  return acc / 10.6 * BLOOM_STRENGTH;
}

void main() {
  vec2 center = vec2(0.5);

  // Drunken camera sway: slow, tiny rotation + zoom to hide the edges.
  float sway = sin(u_time * 0.31) * 0.0035 + sin(u_time * 0.47) * 0.0025;
  float cs = cos(sway);
  float sn = sin(sway);
  vec2 uv = fragTexCoord - center;
  uv = vec2(uv.x * cs - uv.y * sn, uv.x * sn + uv.y * cs);
  uv = uv / 1.006 + center;

  // Chromatic aberration, stronger toward the edges.
  vec2 off = (uv - center) * 0.0035;
  vec3 col;
  col.r = texture(texture0, uv + off).r;
  col.g = texture(texture0, uv).g;
  col.b = texture(texture0, uv - off).b;

  // Glow: bright spots (headlights, flames) bleed into their neighbors.
  col += bloom(uv, 1.0 / u_resolution);

  // Slow hue drift over the whole frame -- the Hotline Miami signature.
  col = hue_shift(col, sin(u_time * 0.13) * 0.30);

  // Scanlines on the game's pixel grid.
  float scan = 0.92 + 0.08 * sin(uv.y * u_resolution.y * 3.14159 * 2.0);
  col *= scan;

  // Vignette.
  float d = distance(uv, center);
  col *= 1.0 - 0.38 * d * d * 2.2;

  // Film grain.
  col += (hash(uv * u_resolution + fract(u_time) * 100.0) - 0.5) * 0.045;

  finalColor = vec4(col, 1.0);
}
