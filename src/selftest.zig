//! The library's own check on a freestanding target: built for `wasm32-freestanding` and run
//! by node (tests/wasm_selftest.mjs), it lexes a small program with a fixed-buffer
//! allocator and reports the token count, or a negative number if anything went wrong.

const std = @import("std");
const glint = @import("glint");

var memory: [64 * 1024]u8 = undefined;

const sample =
    \\import "common";
    \\alias uRes = uRes4.xy;
    \\spec bool FADE = false;
    \\float side = 0.;
    \\vec4 world(vec2 uv) { if (FADE) side = .5; return vec4(uv * 1e3, 0x7feb352du, 1.); }
;

export fn glint_selftest() i32 {
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    const gpa = fba.allocator();
    var diags: glint.Diagnostic.List = .{ .limit = 16 };
    const tokens = glint.Lexer.tokenize(gpa, @fromBackingInt(@intCast(0)), sample, .{}, &diags) catch return -1;
    if (diags.errors != 0) return -2;
    if (tokens[tokens.len - 1].tag != .eof) return -3;
    return @intCast(tokens.len);
}
