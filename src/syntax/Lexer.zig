//! Source text to tokens. Comments and white space are dropped; everything else becomes a
//! token, or a diagnostic and a skip, so lexing always finishes and always ends in `eof`.
//! Type names (`vec3`, `half`, a struct's name) are plain identifiers: the checker resolves
//! them.

const std = @import("std");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Limits = @import("../limits.zig").Limits;
const Token = @import("Token.zig");
const Tag = Token.Tag;

pub const Error = error{OutOfMemory};

const preprocessor_hint =
    "BULG has no preprocessor: `alias NAME = expression;` for a value, `const` for a " ++
    "constant, `spec bool FLAG = false;` and `if (FLAG)` for a variant, `import \"file\";` " ++
    "for another file";

/// Tokens of `text`, ending in `eof`. Problems go to `diags`; the tokens are owned by the
/// caller.
pub fn tokenize(
    gpa: std.mem.Allocator,
    src: Source.Id,
    text: []const u8,
    limits: Limits,
    diags: *Diagnostic.List,
) Error![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    if (text.len > limits.source_bytes) {
        try diags.add(gpa, .{
            .severity = .@"error",
            .code = .source_too_large,
            .span = .{ .src = src, .start = 0, .end = 0 },
            .message = "source is larger than the session's limit",
        });
        try tokens.append(gpa, .{ .tag = .eof, .start = 0, .end = 0 });
        return tokens.toOwnedSlice(gpa);
    }
    var lx: Lexer = .{ .text = text, .src = src, .gpa = gpa, .diags = diags };
    while (true) {
        const t = try lx.next();
        if (tokens.items.len >= limits.tokens and t.tag != .eof) {
            try lx.report(.too_many_tokens, t.start, t.end, "more tokens than the session's limit", null);
            try tokens.append(gpa, .{ .tag = .eof, .start = t.start, .end = t.start });
            break;
        }
        try tokens.append(gpa, t);
        if (t.tag == .eof) break;
    }
    return tokens.toOwnedSlice(gpa);
}

const Lexer = @This();

text: []const u8,
src: Source.Id,
i: u32 = 0,
gpa: std.mem.Allocator,
diags: *Diagnostic.List,

fn report(lx: *Lexer, code: Diagnostic.Code, start: u32, end: u32, message: []const u8, hint: ?[]const u8) Error!void {
    try lx.diags.add(lx.gpa, .{
        .severity = .@"error",
        .code = code,
        .span = .{ .src = lx.src, .start = start, .end = end },
        .message = message,
        .hint = hint,
    });
}

fn peek(lx: *const Lexer, ahead: u32) u8 {
    const j = lx.i + ahead;
    return if (j < lx.text.len) lx.text[j] else 0;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The next token, after white space, comments and anything that is no token.
fn next(lx: *Lexer) Error!Token {
    while (true) {
        try lx.skipSpaceAndComments();
        if (lx.i >= lx.text.len) return .{ .tag = .eof, .start = lx.i, .end = lx.i };
        const start = lx.i;
        const c = lx.text[start];
        if (isIdentStart(c)) return lx.word();
        if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(lx.peek(1)))) return lx.number();
        if (c == '"') return lx.string();
        if (c == '#') {
            // the whole directive line is one problem, reported once
            while (lx.i < lx.text.len and lx.text[lx.i] != '\n') lx.i += 1;
            var end = start + 1;
            while (end < lx.i and isIdentChar(lx.text[end])) end += 1;
            try lx.report(.preprocessor_directive, start, end, "BULG has no preprocessor directives", preprocessor_hint);
            continue;
        }
        if (lx.punctuation()) |t| return t;
        lx.i += 1;
        try lx.report(.unexpected_character, start, lx.i, "this character starts no token", null);
    }
}

fn skipSpaceAndComments(lx: *Lexer) Error!void {
    while (lx.i < lx.text.len) {
        const c = lx.text[lx.i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0b' or c == '\x0c') {
            lx.i += 1;
        } else if (c == '/' and lx.peek(1) == '/') {
            while (lx.i < lx.text.len and lx.text[lx.i] != '\n') lx.i += 1;
        } else if (c == '/' and lx.peek(1) == '*') {
            const start = lx.i;
            lx.i += 2;
            while (lx.i < lx.text.len and !(lx.text[lx.i] == '*' and lx.peek(1) == '/')) lx.i += 1;
            if (lx.i >= lx.text.len) {
                try lx.report(.unterminated_comment, start, start + 2, "this comment never ends", "close it with `*/`");
                return;
            }
            lx.i += 2;
        } else return;
    }
}

fn word(lx: *Lexer) Token {
    const start = lx.i;
    while (lx.i < lx.text.len and isIdentChar(lx.text[lx.i])) lx.i += 1;
    const tag = Token.keywords.get(lx.text[start..lx.i]) orelse .identifier;
    return .{ .tag = tag, .start = start, .end = lx.i };
}

/// `"..."` on one line, quotes included in the token; without a closing quote, the token
/// runs to the end of the line and is reported.
fn string(lx: *Lexer) Error!Token {
    const start = lx.i;
    lx.i += 1;
    while (lx.i < lx.text.len and lx.text[lx.i] != '"' and lx.text[lx.i] != '\n') lx.i += 1;
    if (lx.i < lx.text.len and lx.text[lx.i] == '"') {
        lx.i += 1;
    } else {
        try lx.report(.unterminated_string, start, lx.i, "this string never ends on its line", "close it with `\"`");
    }
    return .{ .tag = .string_literal, .start = start, .end = lx.i };
}

/// A decimal or hexadecimal integer with an optional `u`, or a float with an optional `f`.
/// A number run straight into letters (`1x`, `1e`, `0x`) is one malformed token.
fn number(lx: *Lexer) Error!Token {
    const start = lx.i;
    var tag: Tag = .int_literal;
    var ok = true;
    if (lx.text[lx.i] == '0' and (lx.peek(1) == 'x' or lx.peek(1) == 'X')) {
        lx.i += 2;
        const digits = lx.i;
        while (lx.i < lx.text.len and std.ascii.isHex(lx.text[lx.i])) lx.i += 1;
        ok = lx.i > digits;
        if (lx.peek(0) == 'u' or lx.peek(0) == 'U') lx.i += 1;
    } else {
        while (lx.i < lx.text.len and std.ascii.isDigit(lx.text[lx.i])) lx.i += 1;
        if (lx.peek(0) == '.') {
            tag = .float_literal;
            lx.i += 1;
            while (lx.i < lx.text.len and std.ascii.isDigit(lx.text[lx.i])) lx.i += 1;
        }
        if (lx.peek(0) == 'e' or lx.peek(0) == 'E') {
            tag = .float_literal;
            lx.i += 1;
            if (lx.peek(0) == '+' or lx.peek(0) == '-') lx.i += 1;
            const digits = lx.i;
            while (lx.i < lx.text.len and std.ascii.isDigit(lx.text[lx.i])) lx.i += 1;
            ok = lx.i > digits;
        }
        if (tag == .float_literal and (lx.peek(0) == 'f' or lx.peek(0) == 'F')) {
            lx.i += 1;
        } else if (tag == .int_literal and (lx.peek(0) == 'u' or lx.peek(0) == 'U')) {
            lx.i += 1;
        }
    }
    if (isIdentChar(lx.peek(0)) or lx.peek(0) == '.') {
        ok = false;
        while (lx.i < lx.text.len and (isIdentChar(lx.text[lx.i]) or lx.text[lx.i] == '.')) lx.i += 1;
    }
    if (!ok) try lx.report(.malformed_number, start, lx.i, "this number cannot be read", null);
    return .{ .tag = tag, .start = start, .end = lx.i };
}

/// Longest match first: `<<=` before `<<` before `<=` before `<`.
fn punctuation(lx: *Lexer) ?Token {
    const table = [_]struct { []const u8, Tag }{
        .{ "<<=", .shl_equal },      .{ ">>=", .shr_equal },  .{ "<<", .shl },
        .{ ">>", .shr },             .{ "<=", .less_equal },  .{ ">=", .greater_equal },
        .{ "==", .equal_equal },     .{ "!=", .bang_equal },  .{ "&&", .ampersand_ampersand },
        .{ "||", .pipe_pipe },       .{ "^^", .caret_caret }, .{ "++", .plus_plus },
        .{ "--", .minus_minus },     .{ "+=", .plus_equal },  .{ "-=", .minus_equal },
        .{ "*=", .star_equal },      .{ "/=", .slash_equal }, .{ "%=", .percent_equal },
        .{ "&=", .ampersand_equal }, .{ "|=", .pipe_equal },  .{ "^=", .caret_equal },
        .{ "(", .l_paren },          .{ ")", .r_paren },      .{ "[", .l_bracket },
        .{ "]", .r_bracket },        .{ "{", .l_brace },      .{ "}", .r_brace },
        .{ ";", .semicolon },        .{ ",", .comma },        .{ ".", .period },
        .{ "?", .question },         .{ ":", .colon },        .{ "=", .equal },
        .{ "+", .plus },             .{ "-", .minus },        .{ "*", .star },
        .{ "/", .slash },            .{ "%", .percent },      .{ "<", .less },
        .{ ">", .greater },          .{ "!", .bang },         .{ "~", .tilde },
        .{ "&", .ampersand },        .{ "|", .pipe },         .{ "^", .caret },
    };
    const rest = lx.text[lx.i..];
    for (table) |e| {
        if (std.mem.startsWith(u8, rest, e[0])) {
            const start = lx.i;
            lx.i += @intCast(e[0].len);
            return .{ .tag = e[1], .start = start, .end = lx.i };
        }
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Lexed = struct {
    tokens: []Token,
    diags: Diagnostic.List,

    fn deinit(l: *Lexed) void {
        testing.allocator.free(l.tokens);
        l.diags.deinit(testing.allocator);
    }
};

fn lex(text: []const u8) !Lexed {
    var diags: Diagnostic.List = .{ .limit = 64 };
    const tokens = try tokenize(testing.allocator, @fromBackingInt(@intCast(0)), text, .{}, &diags);
    return .{ .tokens = tokens, .diags = diags };
}

fn expectTags(text: []const u8, want: []const Tag) !void {
    var l = try lex(text);
    defer l.deinit();
    try testing.expectEqual(@as(u32, 0), l.diags.errors);
    var got: [64]Tag = undefined;
    for (l.tokens, 0..) |t, i| got[i] = t.tag;
    try testing.expectEqualSlices(Tag, want, got[0..l.tokens.len]);
}

test "a function lexes into names, keywords, literals and punctuation" {
    try expectTags(
        \\float side = 0.; // a mutable global
        \\vec3 scrub(inout vec3 c) { /* NaN-proof */ if (c.x != c.x) return vec3(0.); c.xz *= 2u; }
    , &.{
        .identifier, .identifier,    .equal,      .float_literal, .semicolon,
        .identifier, .identifier,    .l_paren,    .kw_inout,      .identifier,
        .identifier, .r_paren,       .l_brace,    .kw_if,         .l_paren,
        .identifier, .period,        .identifier, .bang_equal,    .identifier,
        .period,     .identifier,    .r_paren,    .kw_return,     .identifier,
        .l_paren,    .float_literal, .r_paren,    .semicolon,     .identifier,
        .period,     .identifier,    .star_equal, .int_literal,   .semicolon,
        .r_brace,    .eof,
    });
}

test "strings: an import path, and one that never ends" {
    try expectTags("import \"art/art_core\" : artLoad;", &.{ .kw_import, .string_literal, .colon, .identifier, .semicolon, .eof });
    var l = try lex("import \"common;\nfloat x;");
    defer l.deinit();
    try testing.expectEqual(@as(u32, 1), l.diags.errors);
    try testing.expectEqual(Diagnostic.Code.unterminated_string, l.diags.items.items[0].code);
    try testing.expectEqual(@as(u32, 15), l.tokens[1].end);
    try testing.expectEqual(@as(usize, 6), l.tokens.len);
}

test "BULG's declarations are keywords; GLSL type names are not" {
    try expectTags("import alias uniform block param spec extern program template link vec3 half", &.{ .kw_import, .kw_alias, .kw_uniform, .kw_block, .kw_param, .kw_spec, .kw_extern, .kw_program, .kw_template, .kw_link, .identifier, .identifier, .eof });
}

test "every operator, longest match first" {
    try expectTags("<<= >>= << >> <= >= == != && || ^^ ++ -- += -= *= /= %= &= |= ^= < > = ! ~ & | ^ ? : %", &.{
        .shl_equal,       .shr_equal,  .shl,                 .shr,        .less_equal,  .greater_equal,
        .equal_equal,     .bang_equal, .ampersand_ampersand, .pipe_pipe,  .caret_caret, .plus_plus,
        .minus_minus,     .plus_equal, .minus_equal,         .star_equal, .slash_equal, .percent_equal,
        .ampersand_equal, .pipe_equal, .caret_equal,         .less,       .greater,     .equal,
        .bang,            .tilde,      .ampersand,           .pipe,       .caret,       .question,
        .colon,           .percent,    .eof,
    });
}

test "the literal forms the shaders use keep their spelling" {
    const cases = [_]struct { []const u8, Tag }{
        .{ "0", .int_literal },      .{ "16u", .int_literal },         .{ "0x7feb352dU", .int_literal },
        .{ "0X1F", .int_literal },   .{ "1.", .float_literal },        .{ ".5", .float_literal },
        .{ "1e3", .float_literal },  .{ "3e38", .float_literal },      .{ "1.5e-3", .float_literal },
        .{ "2E+2", .float_literal }, .{ "6.2831853", .float_literal }, .{ "1.0f", .float_literal },
    };
    for (cases) |c| {
        var l = try lex(c[0]);
        defer l.deinit();
        try testing.expectEqual(@as(u32, 0), l.diags.errors);
        try testing.expectEqual(@as(usize, 2), l.tokens.len);
        try testing.expectEqual(c[1], l.tokens[0].tag);
        try testing.expectEqualStrings(c[0], c[0][l.tokens[0].start..l.tokens[0].end]);
    }
    // `1<<20` is three tokens, `v.x` after a literal-free name is a field access
    try expectTags("1<<20", &.{ .int_literal, .shl, .int_literal, .eof });
}

test "malformed numbers are one token and one diagnostic each" {
    for ([_][]const u8{ "1e", "1e+", "0x", "12ab", "1.5.2", "3uu" }) |text| {
        var l = try lex(text);
        defer l.deinit();
        try testing.expectEqual(@as(u32, 1), l.diags.errors);
        try testing.expectEqual(Diagnostic.Code.malformed_number, l.diags.items.items[0].code);
        try testing.expectEqual(@as(usize, 2), l.tokens.len);
        try testing.expectEqual(@as(u32, @intCast(text.len)), l.tokens[0].end);
    }
}

test "spans map to lines and columns" {
    const text = "float a;\n  vec3 b = c;\n";
    var l = try lex(text);
    defer l.deinit();
    var src = try Source.init(testing.allocator, "t.bulg", text);
    defer src.deinit(testing.allocator);
    // `b` is token 5: float a ; vec3 b
    const b = l.tokens[4];
    try testing.expectEqualStrings("b", text[b.start..b.end]);
    try testing.expectEqual(Source.Location{ .line = 2, .column = 8 }, src.locate(b.start));
    try testing.expectEqual(@as(u32, @intCast(text.len)), l.tokens[l.tokens.len - 1].start);
}

test "a preprocessor line is one diagnostic with a hint, and lexing goes on" {
    var l = try lex("#define uRes (uRes4.xy)\n#ifdef FADE\nfloat x;\n#endif\n");
    defer l.deinit();
    try testing.expectEqual(@as(u32, 3), l.diags.errors);
    const d = l.diags.items.items[0];
    try testing.expectEqual(Diagnostic.Code.preprocessor_directive, d.code);
    try testing.expectEqual(@as(u32, 0), d.span.start);
    try testing.expectEqual(@as(u32, 7), d.span.end);
    try testing.expect(std.mem.indexOf(u8, d.hint.?, "alias") != null);
    try testing.expectEqual(@as(usize, 4), l.tokens.len); // float x ; eof
}

test "an unterminated comment and a stray character are reported" {
    var l = try lex("float a; @ /* never closed");
    defer l.deinit();
    try testing.expectEqual(@as(u32, 2), l.diags.errors);
    try testing.expectEqual(Diagnostic.Code.unexpected_character, l.diags.items.items[0].code);
    try testing.expectEqual(Diagnostic.Code.unterminated_comment, l.diags.items.items[1].code);
    try testing.expectEqual(Tag.eof, l.tokens[l.tokens.len - 1].tag);
}

test "limits: a source too large, too many tokens" {
    var diags: Diagnostic.List = .{ .limit = 8 };
    defer diags.deinit(testing.allocator);
    const t1 = try tokenize(testing.allocator, @fromBackingInt(@intCast(0)), "a b c", .{ .source_bytes = 3 }, &diags);
    defer testing.allocator.free(t1);
    try testing.expectEqual(Diagnostic.Code.source_too_large, diags.items.items[0].code);
    const t2 = try tokenize(testing.allocator, @fromBackingInt(@intCast(0)), "a b c d", .{ .tokens = 2 }, &diags);
    defer testing.allocator.free(t2);
    try testing.expectEqual(Diagnostic.Code.too_many_tokens, diags.items.items[1].code);
    try testing.expectEqual(@as(usize, 3), t2.len);
    try testing.expectEqual(Tag.eof, t2[2].tag);
}

test "10,000 random inputs never crash, and every token stays inside its source" {
    var prng = std.Random.DefaultPrng.init(0x6c696e74);
    const r = prng.random();
    const alphabet = "abcxyzuUeEfF019._#/*+-<>=!&|^~?:;,(){}[]\n \t\"@$\\\x00\xff";
    var buf: [96]u8 = undefined;
    for (0..10_000) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*c| c.* = if (r.boolean()) alphabet[r.uintLessThan(usize, alphabet.len)] else r.int(u8);
        var diags: Diagnostic.List = .{ .limit = 8 };
        defer diags.deinit(testing.allocator);
        const tokens = try tokenize(testing.allocator, @fromBackingInt(@intCast(0)), buf[0..n], .{}, &diags);
        defer testing.allocator.free(tokens);
        try testing.expectEqual(Tag.eof, tokens[tokens.len - 1].tag);
        var last: u32 = 0;
        for (tokens) |t| {
            try testing.expect(t.start <= t.end and t.end <= n and t.start >= last);
            last = t.end;
        }
    }
}

test "every allocation failure is reported, not a crash or a leak" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var diags: Diagnostic.List = .{ .limit = 64 };
            defer diags.deinit(gpa);
            const tokens = try tokenize(gpa, @fromBackingInt(@intCast(0)), "#define X 1\nfloat x = 1e; @ vec3 y;", .{}, &diags);
            gpa.free(tokens);
        }
    }.run, .{});
}
