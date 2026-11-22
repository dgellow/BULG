//! What a session says about its input: errors and warnings, each with a stable code, the
//! span it is about, a message, and an optional hint saying what to write instead.

const std = @import("std");
const Source = @import("Source.zig");

pub const Severity = enum { @"error", warning };

/// Stable codes: a code keeps its number and meaning across versions; new ones are added
/// at the end of their range. E0001-E0099: lexing; E0100-E0199: parsing; E0200-E0299:
/// checking and linking.
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
    /// a token other than the one the grammar needs here
    expected_token = 100,
    /// `while`, `do` and `switch`: not in Glint v0
    unsupported_statement = 101,
    /// `precision ...;`: precision is the target's business
    precision_statement = 102,
    /// expressions, statements or blocks nested deeper than `Limits.nesting`
    nesting_too_deep = 103,
    /// no expression where one is needed
    expected_expression = 104,
    /// no declaration where a module item is needed
    expected_declaration = 105,
    /// `layout(...)` with something other than `location = n`
    unknown_layout = 106,
    /// qualifiers on a function, or `layout` on something that is not `in`/`out`
    misplaced_qualifier = 107,
    /// a name that nothing declares
    unknown_name = 200,
    /// a type name that nothing declares
    unknown_type = 201,
    /// a name declared twice in one scope
    duplicate_declaration = 202,
    /// a value of one type where another is needed (Glint converts nothing implicitly)
    type_mismatch = 203,
    /// a call no overload of the function takes
    no_overload = 204,
    /// an assignment, `++`, `--` or `out` argument to something that cannot be written
    not_assignable = 205,
    /// a value that must be known at compile time and is not
    not_constant = 206,
    /// a constructor with the wrong arguments
    bad_constructor = 207,
    /// an operator on operands it does not take
    bad_operands = 208,
    /// a swizzle with letters a vector does not have, or mixed sets
    bad_swizzle = 209,
    /// indexing something that has no elements, or with a non-integer
    bad_index = 210,
    /// a field a struct does not have
    unknown_field = 211,
    /// a call of something that is not a function or a type
    not_callable = 212,
    /// a `return` that does not match the function's type
    bad_return = 213,
    /// `break` or `continue` outside a loop
    outside_loop = 214,
    /// a function that calls itself, directly or not
    recursion = 215,
    /// an import or a stage of a module that is not in the session
    unknown_module = 216,
    /// a name two imported modules declare
    ambiguous_name = 217,
    /// a declaration in a place it cannot be (a uniform in a function, `layout` on a
    /// constant, a sampler in a local, ...)
    misplaced_declaration = 218,
    /// a struct that contains itself, or aliases that name each other
    declaration_cycle = 219,
    /// a function with the name of a built-in function, or a name reserved for them
    reserved_name = 220,
    /// an array size that is not a positive constant integer
    bad_array_size = 221,
    /// a constant index past the end of an array, a vector or a matrix
    index_out_of_range = 222,
    /// a prototype without its definition in the module (an `extern` is the way to
    /// leave a function to another module)
    missing_definition = 223,
    /// a declaration that needs an initialiser and has none, or has one it cannot have
    bad_initializer = 224,
    /// a `program` that names an unknown parent, or is its own ancestor
    bad_program = 225,
    /// a program stage without `void main()`
    missing_main = 226,
    /// an `extern` that no module of the stage defines, or more than one does
    unresolved_extern = 227,
    /// a stage that uses what only the other stage has (`discard` in a vertex stage)
    wrong_stage = 228,
    /// `spec NAME = value;` in a program, for a NAME that is no spec constant
    unknown_spec = 229,
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
