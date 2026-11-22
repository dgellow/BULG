# Using Glint

There are three ways in. Each uses the one before it.

## At build time: `addShaderTree`

A directory of `.glint` files becomes a Zig module. `examples/hello` does this from start
to finish.

```zig
// build.zig.zon: .dependencies = .{ .glint = .{ .path = "lib/glint" } }
const glint_dep = b.dependency("glint", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
const shaders = @import("glint").addShaderTree(b, glint_dep, .{
    .root = b.path("shaders"),
    .dialects = &.{.es300}, // the texts this build needs
});
exe.root_module.addImport("shaders", shaders);
```

The module imports only `std`: a build that uses it links nothing of the compiler. For
each program `p` it has:

- `shaders.p.vertex` and `shaders.p.fragment`, an `EnumArray` of texts by dialect,
  complete and ready for `glShaderSource`;
- `shaders.p.samplers.uName`, each sampler's texture unit;
- `shaders.p.info`, and `shaders.programs.get(.p)` for code that picks a program at run
  time. It lists the blocks, samplers in slot order, loose uniforms, params (with
  defaults and metadata), spec constants (the variant's value, the default, and
  metadata), vertex inputs, and the files the program was made from.

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
const glint = @import("glint");
var s: glint.Session = .init(gpa, .{});
defer s.deinit();
_ = try s.addSource("common.glint", text);   // the path names the module
try s.analyze();
for (s.diagnostics()) |d| try d.render(w, s.source(d.span.src));
const p = s.findProgram("reef").?;
if (s.programChecked(p)) {
    var text = try glint.glsl.emit(&s, p, .fragment, .es300, gpa);
    defer text.deinit(gpa);
    // a driver's log, back to the sources:
    try glint.glsl.mapLog(&s, &text, driver_log, w);
    const r = try glint.reflect.reflect(&s, p, arena);
}
```

- Everything the session makes lives in its arena, freed by `deinit`. Results that
  `emit` returns are in the allocator given to it.
- The session needs only an allocator: no files, threads, clock or libc. It runs on
  `wasm32-freestanding` and inside an app for live editing. In a fixed buffer, the golden
  world tree (5 modules, two programs, both dialects and reflection) takes about 350 KiB.
- Bounds on the input are in `Limits`. Past one, the input gets a diagnostic, never a
  crash.

## From the command line: `glint`

```
glint parse FILE...                  diagnostics, and how many files parse
glint check FILE...                  the files as one session: how many modules check
                                     and programs link
glint emit --dialect es300 --out DIR FILE...   DIR/NAME.vert and DIR/NAME.frag
glint gen --root DIR --out FILE.zig  what addShaderTree runs
glint reflect FILE...                reflection as JSON (glint.reflection/1, see
                                     src/reflect/json.zig)
glint print [--shape] FILE           the syntax tree as canonical text
```
