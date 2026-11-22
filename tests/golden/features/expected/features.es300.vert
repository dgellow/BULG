#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
layout(location=0) in vec3 aPos;
layout(location=1) in vec2 aUv;
flat out int vKind;
out vec2 vUv;
void main() {
  vKind = gl_InstanceID;
  vUv = aUv;
  gl_PointSize = 4.;
  gl_Position = vec4(aPos, 1.);
}
