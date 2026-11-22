#include <metal_stdlib>
using namespace metal;
struct sampler2D { texture2d<float> t; sampler s; };
static inline float4 texture(sampler2D x, float2 uv) { return x.t.sample(x.s, uv); }
struct Hit {
  float d;
  float3 n;
};
constant array<float, 3> W = array<float, 3>{.25f, .5f, .25f};
struct bulg_Params {
  array<float4, 4> uSite;
};
struct bulg_Stage {
  constant bulg_Params* bulg_params;
  sampler2D uPrev;
  float hh(float x) {
    return x * 2.f;
  }
  uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    return x ^ (x >> 15u);
  }
  bool hit(float3 p, thread Hit& h) {
    h = Hit{length(p) - 1.f, normalize(p)};
    h.n.zx = h.n.xz;
    return h.d < 0.f;
  }
  float soft(float x) {
    return x * float(.5f);
  }
  float blur(float2 uv) {
    float s = 0.f;
    for (int i = 0; i < 3; i++) {
      s += W[i] * texture(uPrev, uv + float2(float(i - 1), 0.f) / 512.f).x;
    }
    return hh(s);
  }
  float hh_2(float x) {
    return x + 1.f;
  }
  int vKind;
  float4 color;
  float2 vUv;
  void main() {
    Hit h;
    bool inside = hit(float3(vUv, 0.f), h);
    float k = hh_2(1.f) + blur(vUv) + float(soft(float(h.d)));
    uint u = hash(uint(vKind));
    float4 site = bulg_params->uSite[vKind & 3];
    color = inside ? float4(h.n, k) : site * float(u & 255u) / 255.f;
    if (color.w < .01f) {
      discard_fragment();
    }
  }
};
struct bulg_FragmentIn {
  int vKind [[user(vKind), flat]];
  float2 vUv [[user(vUv)]];
};
struct bulg_FragmentOut {
  float4 color [[color(0)]];
};
[[fragment]] bulg_FragmentOut bulg_main(
    bulg_FragmentIn bulg_in [[stage_in]],
    constant bulg_Params& bulg_params_buffer [[buffer(0)]],
    texture2d<float> bulg_uPrev_texture [[texture(0)]],
    sampler bulg_uPrev_sampler [[sampler(0)]]) {
  bulg_Stage s;
  s.bulg_params = &bulg_params_buffer;
  s.uPrev = {bulg_uPrev_texture, bulg_uPrev_sampler};
  s.vKind = bulg_in.vKind;
  s.vUv = bulg_in.vUv;
  s.main();
  bulg_FragmentOut bulg_out;
  bulg_out.color = s.color;
  return bulg_out;
}
