# BULG

The Backend-Unified Language for Graphics: a shading language and its compiler, in Zig.
One source for GLSL ES 3.00 / WebGL 2 and GLSL 3.30 today, WGSL and MSL next, with
reflection that generates the host's uniform structs.

GLSL-shaped, with the preprocessor replaced by declarations:

```glsl
import "common";                          // a module is a file
import "sdf" : sdSphere, opSmoothUnion;   // or some of its names

alias uRes = uRes4.xy;                    // a typed name for an expression (was #define)
param float zoom = 1.6 { range(0.5, 4.0), curve(exp), mod("audio.level") };
spec int STEPS = 96 { tiers(48, 72, 96) };// a constant fixed per variant
extern float map(vec3 p);                 // defined by another module of the program

vec4 world(vec2 uv) { ... }

program template world { vertex "fullscreen"; fragment "world_main"; }
program julia_bloom : world;
```

```
zig build check        # tests, golden texts, the example, a wasm32-freestanding self-test
zig build check-gpu    # the golden ES 3.00 texts linked in Chromium's WebGL 2
zig build              # the bulg command
```

`docs/` has the language, the targets, how to embed it, and what it is not.
`examples/hello` shows the build helper, `addShaderTree`. Needs Zig 0.17.1.
