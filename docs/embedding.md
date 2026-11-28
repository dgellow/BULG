# Using BULG

There are three ways in. Each uses the one before it.

## At build time: `addShaderTree`

A directory of `.bulg` files becomes a Zig module. `examples/hello` does this from start
to finish.

```zig
// build.zig.zon: .dependencies = .{ .bulg = .{ .path = "lib/bulg" } }
const bulg_dep = b.dependency("bulg", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
const shaders = @import("bulg").addShaderTree(b, bulg_dep, .{
    .root = b.path("shaders"),
    .dialects = &.{.es300}, // the texts this build needs (es300, glsl330, msl)
});
exe.root_module.addImport("shaders", shaders);
```

The module imports only `std`: a build that uses it links nothing of the compiler. For
each program `p` it has:

- `shaders.p.vertex` and `shaders.p.fragment`, an `EnumArray` of texts by dialect,
  complete and ready for `glShaderSource`;
- `shaders.p.samplers.uName`, each sampler's texture unit;
- `shaders.p.Params`, the program's `bulg_Params` block as an `extern struct` (std140,
  with the params' defaults), and `shaders.p.params`, each member's offset and size, for
  code that fills it by name;
- `shaders.p.info`, and `shaders.programs.get(.p)` for code that picks a program at run
  time. It lists the blocks, samplers in slot order, loose uniforms, params (with
  defaults and metadata), spec constants (the variant's value, the default, and
  metadata), vertex inputs, and the files the program was made from.
- with `msl` among the dialects, `shaders.p.metal.vertex` and `.fragment`: what a Metal
  host binds. That is each block's buffer index, the `bulg_Params` fields' offsets and
  strides (std140, as on GL) and its size, the texture and sampler indices, and the vertex
  attributes (docs/targets.md, MSL).

Shared by every program:

- `shaders.blocks.Name`, an `extern struct` per uniform block. It is laid out by std140,
  with padding fields and the members' defaults, and its offsets are checked at compile
  time. Upload `std.mem.asBytes(&value)`.
- The std140 shapes: a `vec3` is `[3]f32` and the padding after it is explicit. A
  `matN` is `[N][4]f32` (columns). An array of scalars or `vec2`/`vec3` is `[N][4]T`, its
  elements rounded up to 16 bytes.

The tree is read again at every build. It takes milliseconds, and it means a new file is
never missed. The module is recompiled only when its text changes. A tree with errors
fails the build, with the diagnostics.

## As a library: `Session`

```zig
const bulg = @import("bulg");
var s: bulg.Session = .init(gpa, .{});
defer s.deinit();
_ = try s.addSource("common.bulg", text);   // the path names the module
try s.analyze();
for (s.diagnostics()) |d| try d.render(w, s.source(d.span.src));
const p = s.findProgram("reef").?;
if (s.programChecked(p)) {
    var text = try bulg.emit.emit(&s, p, .fragment, .es300, gpa); // or .glsl330, .msl
    defer text.deinit(gpa);
    // a driver's log, back to the sources:
    try bulg.emit.mapLog(&s, &text, driver_log, w);
    // what a Metal host binds for the MSL text
    const m = try bulg.emit.metalStage(&s, p, .fragment, arena);
    const r = try bulg.reflect.reflect(&s, p, arena);
}
```

- Everything the session makes lives in its arena, freed by `deinit`. Results that
  `emit` returns are in the allocator given to it.
- The session needs only an allocator: no files, threads, clock or libc. It runs on
  `wasm32-freestanding` and inside an app for live editing. In a fixed buffer, the golden
  world tree (5 modules, two programs, both dialects and reflection) takes about 350 KiB.
- Bounds on the input are in `Limits`. Past one, the input gets a diagnostic, never a
  crash.

## From the command line: `bulg`

```
bulg parse FILE...                  diagnostics, and how many files parse
bulg check FILE...                  the files as one session: how many modules check
                                     and programs link
bulg emit --dialect D --out DIR FILE...   DIR/NAME.vert and DIR/NAME.frag (es300, glsl330),
                                     DIR/NAME.vert.metal and .frag.metal (msl)
bulg gen --root DIR --out FILE.zig  what addShaderTree runs
bulg reflect FILE...                reflection as JSON (bulg.reflection/1, see
                                     src/reflect/json.zig)
bulg print [--shape] FILE           the syntax tree as canonical text
```
