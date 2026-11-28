#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
struct Hit {
  float d;
  vec3 n;
};
const float W[3] = float[3](.25, .5, .25);
layout(std140) uniform bulg_Params {
  vec4 uSite[4];
};
uniform sampler2D uPrev;
float hh(float x) {
  return x * 2.;
}
uint hash(uint x) {
  x ^= x >> 16u;
  x *= 0x7feb352du;
  return x ^ x >> 15u;
}
bool hit(vec3 p, out Hit h) {
  h = Hit(length(p) - 1., normalize(p));
  h.n.zx = h.n.xz;
  return h.d < 0.;
}
float soft(float x) {
  return x * float(.5);
}
float blur(vec2 uv) {
  float s = 0.;
  for (int i = 0; i < W.length(); i++) {
    s += W[i] * texture(uPrev, uv + vec2(float(i - 1), 0.) / 512.).r;
  }
  return hh(s);
}
float hh_2(float x) {
  return x + 1.;
}
flat in int vKind;
layout(location=0) out vec4 color;
in vec2 vUv;
void main() {
  Hit h;
  bool inside = hit(vec3(vUv, 0.), h);
  float k = hh_2(1.) + blur(vUv) + float(soft(float(h.d)));
  uint u = hash(uint(vKind));
  vec4 site = uSite[vKind & 3];
  color = inside ? vec4(h.n, k) : site * float(u & 255u) / 255.;
  if (color.a < .01) {
    discard;
  }
}
