#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
layout(std140) uniform Frame {
  vec4 uRes4;
  vec4 uBeat4;
  float uTime;
};
const float TAU = 6.28318530718;
mat2 rot(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat2(c, s, -s, c);
}
float h21(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
vec3 pal(float t) {
  return .5 + .5 * cos(TAU * (t + vec3(0., .33, .67)));
}
const int STEPS = 48;
const float GAIN = 1.;
in vec2 vUv;
out vec4 fragColor;
float side = 0.;
vec3 scene(vec2 p) {
  p *= rot(uTime * .1);
  float d = length(p) - .5 + .1 * h21(floor(p * 8.));
  return pal(d + uTime) * smoothstep(.02, 0., abs(d));
}
void main() {
  vec2 p = (vUv * uRes4.xy - .5 * uRes4.xy) / uRes4.xy.y;
  vec3 c = scene(p);
  for (int i = 0, j = 1; i < STEPS; i += j) {
    c = mix(c, pal(float(i) * .01), .01);
  }
  {
    side = 1.;
  }
  fragColor = vec4(c * GAIN, side);
}
