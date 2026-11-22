//! What a session says about its input: errors and warnings, each with a stable code, the
//! span it is about, a message, and an optional hint saying what to write instead.

const std = @import("std");
const Source = @import("Source.zig");

pub const Severity = enum { @"error", warning };

/// Stable codes: a code keeps its number and meaning across versions; new ones are added
/// at the end of their range. E0001-E0099: lexing; E0100-: parsing (later ranges follow).
pub const Code = enum(u16) {
    /// `#define`, `#ifdef` and the like: Glint has no preprocessor
    preprocessor_directive = 1,
    /// a byte that starts no token
    unexpected_character = 2,
    /// `/*` without `*/`
    unterminated_comment = 3,
    /// a number Glint cannot read (`1e`, `0x`, digits after a suffix, ...)
    malformed_number = 4,
    /// a source larger than `Limits.source_bytes`
    source_too_large = 5,
    /// more tokens than `Limits.tokens`
    too_many_tokens = 6,
    /// `"` without its closing `"` on the same line
    unterminated_string = 7,
    _,

    /// `E0001`
    pub fn format(c: Code, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("E{d:0>4}", .{@backingInt(c)});
    }
};

const Diagnostic = @This();

severity: Severity,
code: Code,
span: Source.Span,
message: []const u8,
/// what to write instead, when there is an obvious answer
hint: ?[]const u8 = null,

/// The diagnostics of a session: kept up to a limit, the rest counted.
pub const List = struct {
    items: std.ArrayList(Diagnostic) = .empty,
    /// diagnostics beyond the limit, not stored
    dropped: u32 = 0,
    errors: u32 = 0,
    limit: u16,

    pub fn add(l: *List, gpa: std.mem.Allocator, d: Diagnostic) error{OutOfMemory}!void {
        if (d.severity == .@"error") l.errors += 1;
        if (l.items.items.len >= l.limit) {
            l.dropped += 1;
            return;
        }
        try l.items.append(gpa, d);
    }

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        l.items.deinit(gpa);
    }
};

/// `path:line:col: error[E0001]: message`, the source line, a caret under the span, and the
/// hint if there is one.
pub fn render(d: Diagnostic, w: *std.Io.Writer, src: *const Source) std.Io.Writer.Error!void {
    const at = src.locate(d.span.start);
    try w.print("{s}:{d}:{d}: {s}[{f}]: {s}\n", .{ src.path, at.line, at.column, @tagName(d.severity), d.code, d.message });
    const line = src.lineText(at.line);
    try w.print("    {s}\n    ", .{line});
    var i: u32 = 1;
    while (i < at.column) : (i += 1) try w.writeByte(if (i - 1 < line.len and line[i - 1] == '\t') '\t' else ' ');
    const room: u32 = @intCast(line.len -| (at.column - 1));
    const n = @max(1, @min(d.span.len(), room));
    for (0..n) |_| try w.writeByte('^');
    try w.writeByte('\n');
    if (d.hint) |h| try w.print("    hint: {s}\n", .{h});
}

test "a diagnostic renders with its place, the line and a caret" {
    const gpa = std.testing.allocator;
    var src = try Source.init(gpa, "w.glint", "float a;\n#define X 1\n");
    defer src.deinit(gpa);
    const d: Diagnostic = .{
        .severity = .@"error",
        .code = .preprocessor_directive,
        .span = .{ .src = @fromBackingInt(@intCast(0)), .start = 9, .end = 16 },
        .message = "Glint has no preprocessor",
        .hint = "use `alias` or `const`",
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try d.render(&w, &src);
    try std.testing.expectEqualStrings(
        \\w.glint:2:1: error[E0001]: Glint has no preprocessor
        \\    #define X 1
        \\    ^^^^^^^
        \\    hint: use `alias` or `const`
        \\
    , w.buffered());
}

test "the list keeps diagnostics up to its limit and counts the rest" {
    const gpa = std.testing.allocator;
    var l: List = .{ .limit = 2 };
    defer l.deinit(gpa);
    const d: Diagnostic = .{ .severity = .@"error", .code = .unexpected_character, .span = .{ .src = @fromBackingInt(@intCast(0)), .start = 0, .end = 1 }, .message = "x" };
    for (0..5) |_| try l.add(gpa, d);
    try std.testing.expectEqual(@as(usize, 2), l.items.items.len);
    try std.testing.expectEqual(@as(u32, 3), l.dropped);
    try std.testing.expectEqual(@as(u32, 5), l.errors);
}
