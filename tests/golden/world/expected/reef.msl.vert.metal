#include <metal_stdlib>
using namespace metal;
struct bulg_Stage {
  float4 gl_Position;
  int gl_VertexID;
  float2 vUv;
  void main() {
    float2 p = float2(float(gl_VertexID << 1 & 2), float(gl_VertexID & 2));
    vUv = p;
    gl_Position = float4(p * 2.f - 1.f, 0.f, 1.f);
  }
};
struct bulg_VertexOut {
  float4 gl_Position [[position]];
  float2 vUv [[user(vUv)]];
};
[[vertex]] bulg_VertexOut bulg_main(
    uint bulg_vertex_id [[vertex_id]]) {
  bulg_Stage s;
  s.gl_VertexID = int(bulg_vertex_id);
  s.main();
  bulg_VertexOut bulg_out;
  bulg_out.gl_Position = float4(s.gl_Position.x, -s.gl_Position.y, (s.gl_Position.z + s.gl_Position.w) * 0.5f, s.gl_Position.w);
  bulg_out.vUv = s.vUv;
  return bulg_out;
}
