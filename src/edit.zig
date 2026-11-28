//! Edits of source text that keep everything else as it was written: comments, spacing,
//! the other declarations. Pure: text in, text out.
//!
//! `setDefault` is what a tool calls when someone has tuned a `param` by eye and wants the
//! value kept: `param float zoom = 1.6 { range(.5, 4.) };` becomes
//! `param float zoom = 1.3 { range(.5, 4.) };`. The new text is not checked here; the
//! caller analyses it (the default may now be outside its range).

const std = @import("std");
const Ast = @import("syntax/Ast.zig");
const Parser = @import("syntax/Parser.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Error = error{OutOfMemory};

pub const Problem = enum {
    /// the text does not parse
    not_parsed,
    /// no module-level `param` of that name
    no_param,
    /// the param's type takes another number of values (`want`)
    wrong_count,
    /// a type `setDefault` cannot write (a matrix, an array, a struct)
    unsupported_type,
    /// a value that is no finite number, or not an integer for an integer type
    bad_value,
};

pub const Result = union(enum) {
    /// the whole new text, in the caller's allocator
    text: []u8,
    problem: struct { why: Problem, want: u8 = 0 },
};

/// The default of the module-level `param` named `name` in `text`, rewritten to `values`
/// (one per component: `vec3` takes three). Numbers are written as the corpus writes them
/// (`.5`, `1.`, `-.25`), as short as they can be while reading back as the same `f32`.
pub fn setDefault(gpa: std.mem.Allocator, text: []const u8, name: []const u8, values: []const f64) Error!Result {
    var diags: Diagnostic.List = .{ .limit = 1 };
    defer diags.deinit(gpa);
    var ast = try Parser.parse(gpa, @fromBackingInt(@intCast(0)), text, .{}, &diags);
    defer ast.deinit(gpa);
    if (diags.errors > 0) return .{ .problem = .{ .why = .not_parsed } };

    const found = find(&ast, name) orelse return .{ .problem = .{ .why = .no_param } };
    const shape = Shape.of(ast.tokenText(found.type_tok)) orelse return .{ .problem = .{ .why = .unsupported_type } };
    if (values.len != shape.n) return .{ .problem = .{ .why = .wrong_count, .want = shape.n } };

    const old = text[found.start..found.end];
    const sep: []const u8 = if (std.mem.indexOf(u8, old, ", ") != null) ", " else ",";
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll(text[0..found.start]) catch return error.OutOfMemory;
    if (shape.n > 1) w.print("{s}(", .{ast.tokenText(found.type_tok)}) catch return error.OutOfMemory;
    // a vector whose components are all one value is written once: vec3(.5)
    const same = for (values[1..]) |v| {
        if (v != values[0]) break false;
    } else true;
    const count: usize = if (shape.n > 1 and same) 1 else values.len;
    for (values[0..count], 0..) |v, i| {
        if (i > 0) w.writeAll(sep) catch return error.OutOfMemory;
        writeValue(w, shape.scalar, v) catch |e| switch (e) {
            error.WriteFailed => return error.OutOfMemory,
            error.BadValue => return .{ .problem = .{ .why = .bad_value } },
        };
    }
    if (shape.n > 1) w.writeAll(")") catch return error.OutOfMemory;
    w.writeAll(text[found.end..]) catch return error.OutOfMemory;
    return .{ .text = try out.toOwnedSlice() };
}

const Scalar = enum { float, int, uint, bool };

const Shape = struct {
    scalar: Scalar,
    n: u8,

    fn of(type_name: []const u8) ?Shape {
        const scalars = [_]struct { []const u8, Scalar }{ .{ "float", .float }, .{ "half", .float }, .{ "int", .int }, .{ "uint", .uint }, .{ "bool", .bool } };
        for (scalars) |s| if (std.mem.eql(u8, type_name, s[0])) return .{ .scalar = s[1], .n = 1 };
        const vectors = [_]struct { []const u8, Scalar }{ .{ "vec", .float }, .{ "hvec", .float }, .{ "ivec", .int }, .{ "uvec", .uint }, .{ "bvec", .bool } };
        for (vectors) |v| {
            if (type_name.len == v[0].len + 1 and std.mem.startsWith(u8, type_name, v[0])) {
                const n = type_name[v[0].len];
                if (n >= '2' and n <= '4') return .{ .scalar = v[1], .n = n - '0' };
            }
        }
        return null;
    }
};

/// Where a param's default is: the bytes of its initialiser, and its type's name token.
const Found = struct { start: u32, end: u32, type_tok: u32 };

fn find(ast: *const Ast, name: []const u8) ?Found {
    for (ast.list(ast.items)) |item| {
        const n = ast.node(@fromBackingInt(@intCast(item)));
        if (n.data != .var_decl) continue;
        const d = n.data.var_decl;
        if (!d.quals.param) continue;
        const tn = ast.node(d.type).data.type_name;
        if (tn.array_len != .none) continue;
        for (ast.list(d.declarators)) |di| {
            const dd = ast.node(@fromBackingInt(@intCast(di))).data.declarator;
            if (!std.mem.eql(u8, ast.tokenText(dd.name), name) or dd.init == .none) continue;
            // the initialiser: from the token after `=` to the `,`, `;` or `{` that ends
            // it, outside brackets
            var t = dd.name + 1;
            if (ast.tokens[t].tag != .equal) return null;
            t += 1;
            const first = t;
            var depth: u32 = 0;
            while (t < ast.tokens.len) : (t += 1) switch (ast.tokens[t].tag) {
                .l_paren, .l_bracket => depth += 1,
                .r_paren, .r_bracket => depth -|= 1,
                .comma, .semicolon, .l_brace => if (depth == 0) break,
                .eof => break,
                else => {},
            };
            if (t == first) return null;
            return .{ .start = ast.tokens[first].start, .end = ast.tokens[t - 1].end, .type_tok = tn.name };
        }
    }
    return null;
}

fn writeValue(w: *std.Io.Writer, s: Scalar, v: f64) (std.Io.Writer.Error || error{BadValue})!void {
    if (!std.math.isFinite(v)) return error.BadValue;
    switch (s) {
        .float => {
            const f: f32 = @floatCast(v);
            if (!std.math.isFinite(f)) return error.BadValue;
            try writeFloat(w, f);
        },
        .int => {
            if (v != @round(v) or v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.BadValue;
            try w.print("{d}", .{@as(i32, @intFromFloat(v))});
        },
        .uint => {
            if (v != @round(v) or v < 0 or v > std.math.maxInt(u32)) return error.BadValue;
            try w.print("{d}u", .{@as(u32, @intFromFloat(v))});
        },
        .bool => try w.writeAll(if (v != 0) "true" else "false"),
    }
}

/// The shortest decimal that reads back as `f`, written as the corpus writes numbers:
/// no leading zero before the point, always a point (`1.`, `.5`, `-.25`).
fn writeFloat(w: *std.Io.Writer, f: f32) std.Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    var s = t;
    if (std.mem.startsWith(u8, s, "-")) {
        try w.writeByte('-');
        s = s[1..];
    }
    if (std.mem.startsWith(u8, s, "0.")) s = s[1..];
    try w.writeAll(s);
    if (std.mem.indexOfScalar(u8, s, '.') == null) try w.writeByte('.');
}

test setDefault {
    const gpa = std.testing.allocator;
    const src =
        \\// a world
        \\param float zoom = 1.6 { range(.5, 4.), label("Zoom") }; // how near
        \\param vec3 tint = vec3(.2, .4, .9) { color };
        \\param int n = 3, m = 4;
        \\param uint mask = 7u;
        \\param bool on = true;
        \\param mat2 r = mat2(1.);
        \\float zoomed = 2.;
    ;
    const Case = struct { []const u8, []const f64, []const u8 };
    for ([_]Case{
        .{ "zoom", &.{1.3}, "param float zoom = 1.3 { range(.5, 4.), label(\"Zoom\") }; // how near" },
        .{ "zoom", &.{0.05}, "param float zoom = .05 {" },
        .{ "zoom", &.{-0.25}, "param float zoom = -.25 {" },
        .{ "zoom", &.{2}, "param float zoom = 2. {" },
        .{ "zoom", &.{0.1}, "param float zoom = .1 {" },
        .{ "tint", &.{ 0.25, 0.5, 1 }, "param vec3 tint = vec3(.25, .5, 1.) { color };" },
        .{ "tint", &.{ 0.5, 0.5, 0.5 }, "param vec3 tint = vec3(.5) { color };" },
        .{ "m", &.{9}, "param int n = 3, m = 9;" },
        .{ "n", &.{-2}, "param int n = -2, m = 4;" },
        .{ "mask", &.{15}, "param uint mask = 15u;" },
        .{ "on", &.{0}, "param bool on = false;" },
    }) |c| {
        const r = try setDefault(gpa, src, c[0], c[1]);
        defer if (r == .text) gpa.free(r.text);
        if (std.mem.indexOf(u8, r.text, c[2]) == null) {
            std.debug.print("{s} = {any}:\n{s}\n", .{ c[0], c[1], r.text });
            return error.TestUnexpectedResult;
        }
        // nothing else moved
        try std.testing.expect(std.mem.startsWith(u8, r.text, "// a world\n"));
        try std.testing.expect(std.mem.endsWith(u8, r.text, "float zoomed = 2.;"));
    }
    const P = struct { []const u8, []const f64, Problem };
    for ([_]P{
        .{ "zoomed", &.{1}, .no_param },
        .{ "nope", &.{1}, .no_param },
        .{ "tint", &.{1}, .wrong_count },
        .{ "r", &.{1}, .unsupported_type },
        .{ "n", &.{1.5}, .bad_value },
        .{ "mask", &.{-1}, .bad_value },
        .{ "zoom", &.{std.math.nan(f64)}, .bad_value },
        .{ "zoom", &.{1e40}, .bad_value },
    }) |c| {
        const r = try setDefault(gpa, src, c[0], c[1]);
        defer if (r == .text) gpa.free(r.text);
        try std.testing.expectEqual(c[2], r.problem.why);
    }
    const r = try setDefault(gpa, "param float = ;", "x", &.{1});
    try std.testing.expectEqual(Problem.not_parsed, r.problem.why);
    // the shortest text that is the same f32
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFloat(&w, 1.15);
    try std.testing.expectEqualStrings("1.15", w.buffered());
}
