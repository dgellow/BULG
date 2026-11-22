# Glint

A small shading language and its compiler, written in Zig: one shader source for Metal
(MSL), WebGPU (WGSL) and OpenGL ES 3.0 / WebGL 2 (GLSL ES 3.00), with reflection that
generates the host's uniform structs, and a CPU interpreter as a reference. It is built for
programs that render mostly with fragment shaders (generative visuals, post-processing
chains) and want to tweak them live, on the device.

Glint is a library first: the compiler runs at build time (a build step turns a shader
tree into a generated Zig module) and, when a host wants live editing, inside the app, on
any target including `wasm32-freestanding`. It never calls a GPU API: it describes, the
host executes.

## Status

v0.1: sources, spans, diagnostics and the lexer. The parser, the checker and IR, the GLSL
emitters, reflection and the build helper, the interpreter, then WGSL and MSL follow, in
that order (see CHANGELOG.md).

## The language, in one example

The syntax is GLSL's, with a preprocessor replaced by declarations. This is where v0 is
going, not what v0.1 parses yet:

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

`param` metadata is opaque to Glint beyond a small core (`range`, `step`, `label`,
`group`, `unit`, `color`, `tiers`): a host gives its own keys meaning, and can pass a
schema so that a misspelt key is an error.

## Using it

```
zig build test     # unit tests
zig build check    # formatting, tests, the freestanding self-test under node, an iOS compile
```

As a dependency: `.glint = .{ .path = "lib/glint" }` (or a URL and hash), then
`b.dependency("glint", .{}).module("glint")`.

## Rules the code keeps

- The core uses only the allocator it is given: no globals, I/O, threads, clock or libc.
- No input can crash it or exhaust its stack: bounds in `Limits`, diagnostics past them.
- Diagnostic codes are stable (`E0001` keeps its meaning).
- It knows nothing about any host: see docs/non-goals.md.
