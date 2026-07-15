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
