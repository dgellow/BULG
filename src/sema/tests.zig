//! The checker's tests: sources in, the diagnostics' codes out.

const std = @import("std");
const Session = @import("../Session.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ir = @import("../ir/Ir.zig");
const testing = std.testing;

const File = struct { []const u8, []const u8 };

fn analyze(files: []const File) !Session {
    var s: Session = .init(testing.allocator, .{});
    errdefer s.deinit();
    for (files) |f| _ = try s.addSource(f[0], f[1]);
    try s.analyze();
    return s;
}

/// The codes `files` give, in order (and each message printed when they differ).
fn expectCodes(files: []const File, codes: []const Diagnostic.Code) !void {
    var s = try analyze(files);
    defer s.deinit();
    var got: std.ArrayList(Diagnostic.Code) = .empty;
    defer got.deinit(testing.allocator);
    for (s.diagnostics()) |d| try got.append(testing.allocator, d.code);
    testing.expectEqualSlices(Diagnostic.Code, codes, got.items) catch |e| {
        for (s.diagnostics()) |d| {
            var buf: [1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            d.render(&w, s.source(d.span.src)) catch {};
            std.debug.print("{s}", .{w.buffered()});
        }
        return e;
    };
}

fn ok(text: []const u8) !void {
    return expectCodes(&.{.{ "m.bulg", text }}, &.{});
}

fn bad(text: []const u8, codes: []const Diagnostic.Code) !void {
    return expectCodes(&.{.{ "m.bulg", text }}, codes);
}

test "types, operators and constructors" {
    try ok(
        \\struct Hit { float d; vec3 n; };
        \\const int N = 4;
        \\const float TAU = 6.28318530718;
        \\uniform vec4 uSite[8];
        \\uniform sampler2D uPrev;
        \\float side = 0.;
        \\vec3 f(vec3 p, inout float k, out Hit h) {
        \\    mat3 m = mat3(1.);
        \\    vec3 q = m * p + p * m - 2. * p / vec3(1, 2, 3);
        \\    vec4 c = vec4(q.xy, 0., 1.) + texture(uPrev, q.zx) + uSite[N - 1];
        \\    float[9] w = float[9](1., 2., 1., 2., 4., 2., 1., 2., 1.);
        \\    k += w[4] * float(w.length());
        \\    uint u = 0x7feb352du;
        \\    u ^= u >> 16u;
        \\    ivec2 ip = ivec2(gl_FragCoord.xy) % 2;
        \\    bool b = all(lessThan(q, vec3(1.))) && !(k > 1.) ^^ true;
        \\    h = Hit(length(q), normalize(q));
        \\    h.n.yz = q.zy;
        \\    side = b ? 1. : 0.;
        \\    for (int i = 0; i < N; i++) { if (i == 2) continue; k *= .5; }
        \\    return q.xyz * c.rgb + vec3(float(ip.x), float(u & 1u), 0.);
        \\}
        \\void main() { float k = 1.; Hit h; vec3 r = f(vec3(0.), k, h); if (r.x > 0.) discard; }
    );
}

test "no implicit conversions" {
    try bad("float f() { return 1; }", &.{.bad_return});
    try bad("void f() { float a = 1; }", &.{.type_mismatch});
    try bad("void f() { float a = 1. + 1; }", &.{.bad_operands});
    try bad("void f() { vec3 a = vec3(1.) * 2; }", &.{.bad_operands});
    try bad("void f() { float a = sin(1); }", &.{.no_overload});
    try bad("void f() { if (1) {} }", &.{.type_mismatch});
}

test "names, scopes and declarations" {
    try bad("void f() { a = 1.; }", &.{.unknown_name});
    try bad("void f() { float a; float a; }", &.{.duplicate_declaration});
    try bad("void f(float a) { float a; }", &.{.duplicate_declaration});
    try ok("void f(float a) { { float a = 2.; } }");
    try bad("void f() { { float a; } a = 1.; }", &.{.unknown_name});
    try bad("float x; float x;", &.{.duplicate_declaration});
    try bad("float sin(float x) { return x; }", &.{.reserved_name});
    try bad("float gl_Mine;", &.{.reserved_name});
    try bad("struct vec3 { float x; };", &.{.reserved_name});
    try bad("void f() { Nope n; }", &.{.unknown_type});
    try ok("float f(float x) { return x; } float f(vec2 x) { return x.x; } void g() { float a = f(1.) + f(vec2(1.)); }");
    try bad("float f(float x) { return x; } void g() { f(vec2(1.)); }", &.{.no_overload});
    // order is free
    try ok("void g() { float a = later(K); } const float K = 2.; float later(float x) { return x; }");
}

test "what can be written" {
    try bad("uniform float u; void f() { u = 1.; }", &.{.not_assignable});
    try bad("const float k = 1.; void f() { k += 1.; }", &.{.not_assignable});
    try bad("void f() { vec3 v; v.xx = vec2(1.); }", &.{.not_assignable});
    try bad("void f(const float a) { a = 1.; }", &.{.not_assignable});
    try bad("void g(out float a) {} void f() { g(1.); }", &.{.not_assignable});
    try bad("void f() { gl_FragCoord = vec4(1.); }", &.{.not_assignable});
    try ok("void f() { vec3 v; v.zx = vec2(1.); v[1] += 1.; gl_Position = vec4(v, 1.); }");
}

test "constructors" {
    try ok("void f() { vec4 a = vec4(vec2(1.), vec2(2.)); mat2 m = mat2(a); mat3 n = mat3(m); vec3 b = vec3(a); ivec2 i = ivec2(a.xy); }");
    try bad("void f() { vec3 a = vec3(1., 2.); }", &.{.bad_constructor});
    try bad("void f() { vec2 a = vec2(1., 2., 3.); }", &.{.bad_constructor});
    try bad("void f() { float[3] a = float[3](1., 2.); }", &.{.bad_constructor});
    try bad("struct S { float a; }; void f() { S s = S(1); }", &.{.bad_constructor});
}

test "swizzles, indices, fields" {
    try bad("void f() { vec2 a; float b = a.z; }", &.{.bad_swizzle});
    try bad("void f() { vec4 a; vec2 b = a.xg; }", &.{.bad_swizzle});
    try bad("void f() { float a; float b = a.x; }", &.{.unknown_field});
    try bad("void f() { float a[3]; float b = a[3]; }", &.{.index_out_of_range});
    try bad("void f() { vec3 a; float b = a[1.]; }", &.{.bad_index});
    try bad("struct S { float a; }; void f() { S s; float b = s.b; }", &.{.unknown_field});
}

test "constants and array sizes" {
    try ok("const int N = 2 * 4; float a[N]; const float k = sin(1.) * 2.;");
    try bad("int n = 3; float a[n];", &.{.bad_array_size});
    try bad("float a[0];", &.{.bad_array_size});
    try bad("void f() { float x = 1.; const float k = x; }", &.{.not_constant});
    try bad("float g() { return 1.; } float side = g();", &.{.not_constant});
    try bad("const float k;", &.{.bad_initializer});
    try bad("uniform float u = 1.;", &.{.bad_initializer});
    // a spec value is the variant's: it cannot size an array
    try bad("spec int N = 4; float a[N];", &.{.bad_array_size});
    try ok("const uint M = 0x10u >> 2u; float a[M]; const int O = 010; float b[O];");
    try bad("float a[2147483648];", &.{.bad_array_size});
    // halves convert only through constructors
    try ok("void f() { half h = half(1.); hvec3 v = hvec3(h) * h; vec3 w = vec3(v); }");
    try bad("void f() { half h = half(1.); float x = h + 1.; }", &.{.bad_operands});
}

test "metadata" {
    try ok("param float zoom = 1.6 { range(0.5, 4.0), curve(exp), label(\"Zoom\"), mod(\"audio.level\") }; spec int STEPS = 96 { tiers(48, 72, 96) };");
    try bad("float x = 1. { range(0., 1.) };", &.{.misplaced_declaration});
    try bad("float y; param float p = 1. { range(0., y) };", &.{.not_constant});
    try ok("const float MAX = 4.; param float p = 1. { range(0., MAX), curve(exp) };");
}

test "statements" {
    try bad("void f() { break; }", &.{.outside_loop});
    try bad("void f() { return 1.; }", &.{.bad_return});
    try bad("float f() { return; }", &.{.bad_return});
}

test "cycles" {
    try bad("float f(float x) { return g(x); } float g(float x) { return f(x); }", &.{.recursion});
    try bad("struct A { B b; }; struct B { A a; };", &.{.declaration_cycle});
    try bad("alias a = b; alias b = a;", &.{.declaration_cycle});
    try bad("float m(vec3 p);", &.{.missing_definition});
    try ok("float m(vec3 p); float m(vec3 p) { return p.x; } float n() { return m(vec3(1.)); }");
}

test "aliases, imports, uniform blocks" {
    try expectCodes(&.{
        .{ "frame.bulg", "uniform block Frame { vec4 uRes4; float uTime; mat4 uHyp[2]; }; alias uRes = uRes4.xy;" },
        .{ "common.bulg", "import \"frame\"; float aspect() { return uRes.x / uRes.y; } float hidden() { return 1.; }" },
        .{ "w.bulg", "import \"common\" : aspect; import \"frame\"; void main() { float a = aspect() * uTime; }" },
    }, &.{});
    try expectCodes(&.{
        .{ "a.bulg", "float hidden() { return 1.; }" },
        .{ "w.bulg", "import \"a\" : other; import \"nope\"; void f() { hidden(); }" },
    }, &.{ .unknown_name, .unknown_module, .unknown_name });
    try expectCodes(&.{
        .{ "a.bulg", "const float K = 1.;" },
        .{ "b.bulg", "const float K = 2.;" },
        .{ "w.bulg", "import \"a\"; import \"b\"; float k = K;" },
    }, &.{.ambiguous_name});
    // std140 offsets
    var s = try analyze(&.{.{ "f.bulg", "uniform block F { float a; vec3 b; float c; mat3 m; vec2 d; };" }});
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.diagnostics().len);
    const b = s.modules[0].blocks[0];
    try testing.expectEqualSlices(u32, &.{ 0, 16, 28, 32, 80 }, b.offsets);
    try testing.expectEqual(@as(u32, 96), b.size);
}

test "programs: stages, externs and spec values" {
    const files = [_]File{
        .{ "fullscreen.bulg", "void main() { gl_Position = vec4(0., 0., 0., 1.); }" },
        .{ "world_main.bulg", "spec bool FADE = false; extern vec3 scene(vec2 p); out vec4 color; void main() { color = vec4(scene(gl_FragCoord.xy), 1.); if (FADE) discard; }" },
        .{ "worlds/reef.bulg", "vec3 scene(vec2 p) { return vec3(p, 0.); } program reef : world { spec FADE = true; }" },
        .{ "programs.bulg", "program template world { vertex \"fullscreen\"; fragment \"world_main\"; }" },
    };
    var s = try analyze(&files);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.diagnostics().len);
    const p = s.findProgram("reef").?;
    try testing.expect(p.vertex != null and p.fragment != null);
    try testing.expectEqual(@as(usize, 1), p.fragment.?.externs.len);
    try testing.expect(p.fragment.?.uses.discard and p.fragment.?.uses.frag_coord);
    try testing.expectEqual(@as(usize, 1), p.specs.len);
    try testing.expect(p.specs[0].value.eql(.{ .bool = true }));
    try testing.expect(s.findProgram("world").?.is_template);

    // an unfilled extern, a vertex stage that discards, an unknown spec
    try expectCodes(&.{
        .{ "v.bulg", "void main() { discard; }" },
        .{ "f.bulg", "extern vec3 scene(vec2 p); void main() { vec3 c = scene(vec2(0.)); }" },
        .{ "p.bulg", "program p { vertex \"v\"; fragment \"f\"; spec NOPE = 1; }" },
    }, &.{ .wrong_stage, .unresolved_extern, .unknown_spec });
    try expectCodes(&.{.{ "p.bulg", "program a : b; program b : a;" }}, &.{.bad_program});
    try expectCodes(&.{.{ "p.bulg", "void f() {} program p { vertex \"p\"; fragment \"p\"; }" }}, &.{ .missing_main, .missing_main });
}

test "out of memory anywhere is reported, never leaked" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var s: Session = .init(gpa, .{});
            defer s.deinit();
            _ = try s.addSource("a.bulg", "struct H { float d; }; uniform block F { vec4 r; }; alias R = r.xy; float f(vec2 p) { H h = H(p.x); return h.d + R.x; }");
            _ = try s.addSource("b.bulg", "import \"a\"; void main() { float x = f(vec2(1.)); } program p { vertex \"b\"; fragment \"b\"; }");
            try s.analyze();
        }
    }.run, .{});
}
