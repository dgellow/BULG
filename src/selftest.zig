//! The library's own check on a freestanding target: built for `wasm32-freestanding` and run
//! by node (tests/wasm_selftest.mjs), it parses a small program with a fixed-buffer
//! allocator, prints its tree, parses and prints that again (the same text), checks a
//! small program in a session, and reports the node count, or a negative number if
//! anything went wrong.

const std = @import("std");
const glint = @import("glint");

var memory: [256 * 1024]u8 = undefined;
var printed: [4 * 1024]u8 = undefined;
var reprinted: [4 * 1024]u8 = undefined;

const sample =
    \\import "common";
    \\alias uRes = uRes4.xy;
    \\spec bool FADE = false;
    \\float side = 0.;
    \\vec4 world(vec2 uv) { if (FADE) side = .5; return vec4(uv * 1e3, 0x7feb352du, 1.); }
    \\program template world { vertex "fullscreen"; fragment "world_main"; }
    \\program julia_bloom : world;
;

const world_main =
    \\spec bool FADE = false;
    \\uniform block Frame { vec4 uRes4; float uTime; };
    \\alias uRes = uRes4.xy;
    \\extern vec3 scene(vec2 p);
    \\out vec4 color;
    \\void main() { color = vec4(scene(gl_FragCoord.xy / uRes), 1.); if (FADE) discard; }
    \\program template world { vertex "fullscreen"; fragment "world_main"; }
;
const reef =
    \\import "world_main" : uTime;
    \\vec3 scene(vec2 p) { return vec3(p, sin(uTime)); }
    \\program reef : world { spec FADE = true; }
;

export fn glint_selftest() i32 {
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    const gpa = fba.allocator();
    var diags: glint.Diagnostic.List = .{ .limit = 16 };
    const ast = glint.parse(gpa, @fromBackingInt(@intCast(0)), sample, .{}, &diags) catch return -1;
    if (diags.errors != 0) return -2;
    var w: std.Io.Writer = .fixed(&printed);
    ast.print(&w) catch return -3;
    const again = glint.parse(gpa, @fromBackingInt(@intCast(0)), w.buffered(), .{}, &diags) catch return -4;
    if (diags.errors != 0) return -5;
    var w2: std.Io.Writer = .fixed(&reprinted);
    again.print(&w2) catch return -6;
    if (!std.mem.eql(u8, w.buffered(), w2.buffered())) return -7;

    var session: glint.Session = .init(gpa, .{});
    defer session.deinit();
    _ = session.addSource("fullscreen.glint", "void main() { gl_Position = vec4(0., 0., 0., 1.); }") catch return -8;
    _ = session.addSource("world_main.glint", world_main) catch return -8;
    _ = session.addSource("worlds/reef.glint", reef) catch return -8;
    session.analyze() catch return -9;
    if (session.errorCount() != 0) return -10;
    const p = session.findProgram("reef") orelse return -11;
    if (p.fragment == null or p.fragment.?.externs.len != 1) return -12;
    return @intCast(ast.nodes.len);
}
