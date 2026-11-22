//! A source file the session was given, and positions in it. BULG never reads files
//! itself (that is `fs.zig`, for the CLI and the build): sources arrive as text.

const std = @import("std");

/// Which source, in the order the session was given them.
pub const Id = enum(u32) { _ };

/// A byte range in one source. Every token, syntax node, IR node and diagnostic has one.
pub const Span = struct {
    src: Id,
    start: u32,
    end: u32,

    pub fn len(s: Span) u32 {
        return s.end - s.start;
    }
};

/// A 1-based line and column (columns count bytes).
pub const Location = struct { line: u32, column: u32 };

const Source = @This();

path: []const u8,
text: []const u8,
/// byte offset where each line starts; line 1 starts at 0
line_starts: []const u32,

/// Index `text`'s lines. `path` and `text` are borrowed; the table is allocated.
pub fn init(gpa: std.mem.Allocator, path: []const u8, text: []const u8) error{OutOfMemory}!Source {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);
    for (text, 0..) |c, i| {
        if (c == '\n') try starts.append(gpa, @intCast(i + 1));
    }
    return .{ .path = path, .text = text, .line_starts = try starts.toOwnedSlice(gpa) };
}

pub fn deinit(s: *Source, gpa: std.mem.Allocator) void {
    gpa.free(s.line_starts);
    s.* = undefined;
}

/// The line and column of a byte offset (an offset past the end is on the last line).
pub fn locate(s: *const Source, offset: u32) Location {
    // the last line start at or before the offset
    var lo: usize = 0;
    var hi: usize = s.line_starts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (s.line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return .{ .line = @intCast(lo + 1), .column = offset - s.line_starts[lo] + 1 };
}

/// The text of a 1-based line, without its newline.
pub fn lineText(s: *const Source, line: u32) []const u8 {
    const i = line - 1;
    const start = s.line_starts[i];
    var end: usize = if (i + 1 < s.line_starts.len) s.line_starts[i + 1] else s.text.len;
    while (end > start and (s.text[end - 1] == '\n' or s.text[end - 1] == '\r')) end -= 1;
    return s.text[start..end];
}

pub fn slice(s: *const Source, span: Span) []const u8 {
    return s.text[span.start..span.end];
}

test "lines and columns, including the last line without a newline" {
    const gpa = std.testing.allocator;
    var s = try Source.init(gpa, "a.bulg", "ab\n\ncd\r\nef");
    defer s.deinit(gpa);
    try std.testing.expectEqual(Location{ .line = 1, .column = 1 }, s.locate(0));
    try std.testing.expectEqual(Location{ .line = 1, .column = 3 }, s.locate(2));
    try std.testing.expectEqual(Location{ .line = 2, .column = 1 }, s.locate(3));
    try std.testing.expectEqual(Location{ .line = 3, .column = 2 }, s.locate(5));
    try std.testing.expectEqual(Location{ .line = 4, .column = 2 }, s.locate(9));
    try std.testing.expectEqualStrings("cd", s.lineText(3));
    try std.testing.expectEqualStrings("", s.lineText(2));
    try std.testing.expectEqualStrings("ef", s.lineText(4));
}
