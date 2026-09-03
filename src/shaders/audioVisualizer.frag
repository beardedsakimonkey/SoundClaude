precision mediump float;

uniform sampler2D u_audio;
uniform vec2 u_resolution;
uniform float u_energy;
uniform float u_time;

void main() {
  vec2 uv = gl_FragCoord.xy / u_resolution;
  float frequencyPosition = pow(uv.x, 1.7);
  float spectrum = texture2D(u_audio, vec2(frequencyPosition, 0.5)).r;
  spectrum = pow(spectrum, 1.35);

  float centerDistance = abs(uv.y - 0.5);
  float motion = sin(uv.x * 18.0 - u_time * 1.4) * (0.003 + u_energy * 0.008);
  float height = 0.012 + spectrum * 0.38 + motion;
  float body = 1.0 - smoothstep(height, height + 0.014, centerDistance);
  float glow = exp(-30.0 * abs(centerDistance - height)) * spectrum;

  vec3 orange = vec3(1.0, 0.25, 0.02);
  vec3 magenta = vec3(0.88, 0.05, 0.48);
  vec3 violet = vec3(0.35, 0.10, 0.95);
  vec3 color = mix(orange, magenta, smoothstep(0.0, 0.58, uv.x));
  color = mix(color, violet, smoothstep(0.58, 1.0, uv.x));

  float haze = u_energy * 0.08 * (1.0 - centerDistance);
  float alpha = body * (0.12 + spectrum * 0.28) + glow * 0.18 + haze;
  gl_FragColor = vec4(color, clamp(alpha, 0.0, 0.52));
}
