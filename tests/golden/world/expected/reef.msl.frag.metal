#include <metal_stdlib>
using namespace metal;
struct Frame {
  float4 uRes4;
  float4 uBeat4;
  float uTime;
  char bulg_pad0[12];
};
constant float TAU = 6.28318530718f;
constant int STEPS = 96;
constant float GAIN = -0.5f;
struct bulg_Stage {
  constant Frame* bulg_Frame;
  float2x2 rot(float a) {
    float c = cos(a);
    float s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
  }
  float h21(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
  }
  float3 pal(float t) {
    return .5f + .5f * cos(TAU * (t + float3(0.f, .33f, .67f)));
  }
  float2 vUv;
  float4 fragColor;
  float3 scene(float2 p) {
    p *= rot(bulg_Frame->uTime * .1f);
    float d = length(p) - .5f + .1f * h21(floor(p * 8.f));
    return pal(d + bulg_Frame->uTime) * smoothstep(.02f, 0.f, abs(d));
  }
  void main() {
    float2 p = (vUv * bulg_Frame->uRes4.xy - .5f * bulg_Frame->uRes4.xy) / bulg_Frame->uRes4.xy.y;
    float3 c = scene(p);
    for (int i = 0, j = 1; i < STEPS; i += j) {
      c = mix(c, pal(float(i) * .01f), float3(.01f));
    }
    {
      c *= .5f + .5f * bulg_Frame->uBeat4.x;
    }
    fragColor = float4(c * GAIN, 1.f);
  }
};
struct bulg_FragmentIn {
  float2 vUv [[user(vUv)]];
};
struct bulg_FragmentOut {
  float4 fragColor [[color(0)]];
};
fragment bulg_FragmentOut bulg_main(
    bulg_FragmentIn bulg_in [[stage_in]],
    constant Frame& bulg_Frame_buffer [[buffer(0)]]) {
  bulg_Stage s;
  s.bulg_Frame = &bulg_Frame_buffer;
  s.vUv = bulg_in.vUv;
  s.main();
  bulg_FragmentOut bulg_out;
  bulg_out.fragColor = s.fragColor;
  return bulg_out;
}
