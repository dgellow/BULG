#include <metal_stdlib>
using namespace metal;
struct bulg_Stage {
  float4 gl_Position;
  float gl_PointSize;
  int gl_InstanceID;
  float3 aPos;
  float2 aUv;
  int vKind;
  float2 vUv;
  void main() {
    vKind = gl_InstanceID;
    vUv = aUv;
    gl_PointSize = 4.f;
    gl_Position = float4(aPos, 1.f);
  }
};
struct bulg_VertexIn {
  float3 aPos [[attribute(0)]];
  float2 aUv [[attribute(1)]];
};
struct bulg_VertexOut {
  float4 gl_Position [[position]];
  float gl_PointSize [[point_size]];
  int vKind [[user(vKind)]];
  float2 vUv [[user(vUv)]];
};
vertex bulg_VertexOut bulg_main(
    bulg_VertexIn bulg_in [[stage_in]],
    uint bulg_instance_id [[instance_id]]) {
  bulg_Stage s;
  s.gl_InstanceID = int(bulg_instance_id);
  s.aPos = bulg_in.aPos;
  s.aUv = bulg_in.aUv;
  s.main();
  bulg_VertexOut bulg_out;
  bulg_out.gl_Position = float4(s.gl_Position.x, -s.gl_Position.y, (s.gl_Position.z + s.gl_Position.w) * 0.5f, s.gl_Position.w);
  bulg_out.gl_PointSize = s.gl_PointSize;
  bulg_out.vKind = s.vKind;
  bulg_out.vUv = s.vUv;
  return bulg_out;
}
