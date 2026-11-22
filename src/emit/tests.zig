//! The emitters' tests: programs in, exact texts out.

const std = @import("std");
const Session = @import("../Session.zig");
const emit = @import("emit.zig");
const testing = std.testing;

const File = struct { []const u8, []const u8 };

fn session(files: []const File) !Session {
    var s: Session = .init(testing.allocator, .{});
    errdefer s.deinit();
    for (files) |f| _ = try s.addSource(f[0], f[1]);
    try s.analyze();
    if (s.errorCount() != 0) {
        for (s.diagnostics()) |d| std.debug.print("{s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
    return s;
}

fn expectStage(files: []const File, program: []const u8, stage: @import("../ir/Ir.zig").Stage, dialect: emit.Dialect, want: []const u8) !void {
    var s = try session(files);
    defer s.deinit();
    var out = try emit.emit(&s, s.findProgram(program).?, stage, dialect, testing.allocator);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(want, out.text);
}

const world = [_]File{
    .{ "frame.bulg", "uniform block Frame { vec4 uRes4; float uTime; };\nalias uRes = (uRes4.xy);\n" },
    .{
        "fullscreen.bulg",
        \\out vec2 vUv;
        \\void main(){
        \\  vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));
        \\  vUv=p;
        \\  gl_Position=vec4(p*2.-1.,0.,1.);
        \\}
    },
    .{
        "world_main.bulg",
        \\import "frame";
        \\spec bool FADE = false;
        \\spec int STEPS = 48;
        \\extern vec3 scene(vec2 p);
        \\in vec2 vUv;
        \\out vec4 fragColor;
        \\float unused() { return 1.; }
        \\void main() {
        \\  vec3 c = scene(vUv * uRes / uRes.y);
        \\  if (FADE) { c *= .5; } else { c += 1e-3; }
        \\  for (int i = 0; i < STEPS; i++) c = c * c;
        \\  fragColor = vec4(FADE ? c : -c, 1.);
        \\}
        \\program template world { vertex "fullscreen"; fragment "world_main"; }
    },
    .{
        "reef.bulg",
        \\import "frame";
        \\float h(float x) { return fract(sin(x) * 43758.5453); }
        \\vec3 scene(vec2 p) { return vec3(p, h(uTime)); }
        \\program reef : world { spec FADE = true; spec STEPS = 96; }
        \\program plain : world;
    },
};

test "a stage: header, the reached declarations in order, specs folded" {
    // modules in link order with the imported first (frame, world_main, reef), and in each
    // module the source's order; an alias prints its expression (the tree of the macro it
    // was: `(uRes4.xy).y` and `uRes4.xy.y` are one tree)
    try expectStage(&world, "reef", .fragment, .es300,
        \\#version 300 es
        \\precision highp float;
        \\precision highp int;
        \\precision highp sampler2D;
        \\layout(std140) uniform Frame {
        \\  vec4 uRes4;
        \\  float uTime;
        \\};
        \\const int STEPS = 96;
        \\in vec2 vUv;
        \\out vec4 fragColor;
        \\float h(float x) {
        \\  return fract(sin(x) * 43758.5453);
        \\}
        \\vec3 scene(vec2 p) {
        \\  return vec3(p, h(uTime));
        \\}
        \\void main() {
        \\  vec3 c = scene(vUv * uRes4.xy / uRes4.xy.y);
        \\  {
        \\    c *= .5;
        \\  }
        \\  for (int i = 0; i < STEPS; i++) {
        \\    c = c * c;
        \\  }
        \\  fragColor = vec4(c, 1.);
        \\}
        \\
    );
    try expectStage(&world, "plain", .fragment, .glsl330,
        \\#version 330 core
        \\layout(std140) uniform Frame {
        \\  vec4 uRes4;
        \\  float uTime;
        \\};
        \\const int STEPS = 48;
        \\in vec2 vUv;
        \\out vec4 fragColor;
        \\float h(float x) {
        \\  return fract(sin(x) * 43758.5453);
        \\}
        \\vec3 scene(vec2 p) {
        \\  return vec3(p, h(uTime));
        \\}
        \\void main() {
        \\  vec3 c = scene(vUv * uRes4.xy / uRes4.xy.y);
        \\  {
        \\    c += 1e-3;
        \\  }
        \\  for (int i = 0; i < STEPS; i++) {
        \\    c = c * c;
        \\  }
        \\  fragColor = vec4(-c, 1.);
        \\}
        \\
    );
    try expectStage(&world, "reef", .vertex, .glsl330,
        \\#version 330 core
        \\out vec2 vUv;
        \\void main() {
        \\  vec2 p = vec2(float(gl_VertexID << 1 & 2), float(gl_VertexID & 2));
        \\  vUv = p;
        \\  gl_Position = vec4(p * 2. - 1., 0., 1.);
        \\}
        \\
    );
}

test "the line map takes a driver's log back to the sources" {
    var s = try session(&world);
    defer s.deinit();
    var out = try emit.emit(&s, s.findProgram("reef").?, .fragment, .glsl330, testing.allocator);
    defer out.deinit(testing.allocator);
    // the emitted line of `return fract(...)` comes from reef.bulg's line 2
    var line: u32 = 1;
    var it = std.mem.splitScalar(u8, out.text, '\n');
    const at = while (it.next()) |l| : (line += 1) {
        if (std.mem.indexOf(u8, l, "return fract") != null) break line;
    } else unreachable;
    const entry = out.lookup(at).?;
    try testing.expectEqualStrings("reef.bulg", s.source(entry.src).path);
    try testing.expectEqual(@as(u32, 2), entry.src_line);

    // Mesa writes `0:LINE(COL)`, ANGLE `0:LINE:`, others `0(LINE)`
    const log = try std.fmt.allocPrint(testing.allocator, "0:{d}(12): error: x\nERROR: 0:{d}: y\n0({d}) : z\nversion 330 at 10:20\n", .{ at, at, at });
    defer testing.allocator.free(log);
    var mapped: std.Io.Writer.Allocating = .init(testing.allocator);
    defer mapped.deinit();
    try emit.mapLog(&s, &out, log, &mapped.writer);
    try testing.expectEqualStrings("reef.bulg:2(12): error: x\nERROR: reef.bulg:2: y\nreef.bulg:2 : z\nversion 330 at 10:20\n", mapped.written());
}

test "a stage whose modules have errors is not emitted" {
    var s: Session = .init(testing.allocator, .{});
    defer s.deinit();
    _ = try s.addSource("v.bulg", "void main() { gl_Position = vec4(1.); }");
    _ = try s.addSource("f.bulg", "out vec4 c; void main() { c = 1; } program p { vertex \"v\"; fragment \"f\"; }");
    try s.analyze();
    try testing.expect(s.errorCount() > 0);
    try testing.expectError(error.NotChecked, emit.emit(&s, s.findProgram("p").?, .fragment, .es300, testing.allocator));
    try testing.expect(!s.programChecked(s.findProgram("p").?));
}

test "emitting runs out of memory cleanly" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var s: Session = .init(testing.allocator, .{});
            defer s.deinit();
            for (world) |f| _ = try s.addSource(f[0], f[1]);
            try s.analyze();
            var out = try emit.emit(&s, s.findProgram("reef").?, .fragment, .es300, gpa);
            out.deinit(gpa);
        }
    }.run, .{});
}

test "constant vectors and matrices, component by component" {
    var s = try session(&.{.{ "c.bulg", "const vec3 A = vec3(1., vec2(2, 3)); const mat2 M = mat2(2.); const vec4 B = -vec4(A, 4.); const ivec2 I = ivec2(vec2(1.5, -2.5));" }});
    defer s.deinit();
    const eval = @import("../ir/eval.zig");
    var buf: [16]@import("../ir/Ir.zig").Const = undefined;
    const m = s.modules[0];
    const want = [_][]const f32{ &.{ 1, 2, 3 }, &.{ 2, 0, 0, 2 }, &.{ -1, -2, -3, -4 } };
    for (want, 0..) |w, gi| {
        const got = eval.components(s.modules, 0, m.globals[gi].init, .{ .values = &.{} }, &buf).?;
        try testing.expectEqual(w.len, got.len);
        for (w, got) |x, y| try testing.expectEqual(x, y.float);
    }
    const ints = eval.components(s.modules, 0, m.globals[3].init, .{ .values = &.{} }, &buf).?;
    try testing.expectEqual(@as(i32, 1), ints[0].int);
    try testing.expectEqual(@as(i32, -2), ints[1].int);
}

test "MSL spells out what Metal lacks" {
    var s = try session(&.{
        .{ "frame.bulg", "uniform block Frame { vec4 uRes4; vec3 uSun; float uTime; };\n" },
        .{ "v.bulg", "out vec2 vUv;\nvoid main(){ vUv = vec2(0.); gl_Position = vec4(0., 0., 0., 1.); }\n" },
        .{
            "f.bulg",
            \\import "frame";
            \\in vec2 vUv;
            \\out vec4 o;
            \\uniform mat4 uM;
            \\void main(){
            \\  float c = cos(uTime), s = sin(uTime);
            \\  mat2 r = mat2(c, -s, s, c);
            \\  mat3 m = mat3(uM);
            \\  vec3 v = vec3(vec4(uSun, 1.));
            \\  bool x = (c > 0.) ^^ (s > 0.);
            \\  bvec2 n = not(lessThan(vUv, vec2(.5)));
            \\  o = vec4(min(m * v, 0.), mod(atan(vUv.t, vUv.s), 2.)) + vec4(r * vUv.st, float(x), float(n.x));
            \\}
            \\program p { vertex "v"; fragment "f"; }
        },
    });
    defer s.deinit();
    var out = try emit.emit(&s, s.findProgram("p").?, .fragment, .msl, testing.allocator);
    defer out.deinit(testing.allocator);
    const want = [_][]const u8{
        "float2x2 r = float2x2(float2(c, -s), float2(s, c));",
        "float3x3 m = bulg_mat3(bulg_params->uM);",
        "float3 v = float3(float4(bulg_Frame->uSun, 1.f).xyz);",
        "bool x = c > 0.f != s > 0.f;",
        "bool2 n = (!lessThan(vUv, float2(.5f)));",
        "min(m * v, float3(0.f))",
        "mod(atan2(vUv.y, vUv.x), 2.f)",
        "r * vUv.xy",
        "packed_float3 uSun;",
        "template<typename T> inline T mod(T x, T y)",
        "inline float3x3 bulg_mat3(float4x4 m)",
        "constant Frame& bulg_Frame_buffer [[buffer(0)]]",
        "constant bulg_Params& bulg_params_buffer [[buffer(1)]]",
    };
    for (want) |w| if (std.mem.indexOf(u8, out.text, w) == null) {
        std.debug.print("missing `{s}` in:\n{s}\n", .{ w, out.text });
        return error.TestUnexpectedResult;
    };

    // and what a host binds for it
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try emit.metalStage(&s, s.findProgram("p").?, .fragment, arena.allocator());
    try testing.expectEqual(@as(usize, 1), m.blocks.len);
    try testing.expectEqualStrings("Frame", m.blocks[0]);
    try testing.expectEqual(@as(usize, 1), m.params.len);
    try testing.expectEqualStrings("uM", m.params[0].name);
    try testing.expectEqual(@as(u32, 64), m.params_size);
    try testing.expectEqual(@as(usize, 0), m.textures.len);
}
