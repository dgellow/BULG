//! A token: what it is and where it is. Its text is the source between `start` and `end`;
//! literals are kept as written, so that a GLSL emitter can print them back exactly.

const std = @import("std");

pub const Tag = enum(u8) {
    eof,
    identifier,
    /// `12`, `0x7feb352d`, with an optional `u`/`U` suffix (unsigned)
    int_literal,
    /// `1.`, `.5`, `1e3`, `1.5e-3`, with an optional `f`/`F` suffix
    float_literal,
    /// `"art/art_core"`: a path or a name in metadata; no escapes, on one line
    string_literal,

    // keywords: Glint's own declarations
    kw_import,
    kw_alias,
    kw_uniform,
    kw_block,
    kw_param,
    kw_spec,
    kw_extern,
    kw_program,
    kw_template,
    kw_link,
    // keywords shared with GLSL
    kw_const,
    kw_in,
    kw_out,
    kw_inout,
    kw_flat,
    kw_layout,
    kw_struct,
    kw_if,
    kw_else,
    kw_for,
    kw_break,
    kw_continue,
    kw_return,
    kw_discard,
    kw_true,
    kw_false,
    // GLSL keywords Glint leaves out of v0: lexed as keywords, so that using one gives a
    // diagnostic that names it rather than a confusing parse error
    kw_while,
    kw_do,
    kw_switch,
    kw_precision,

    // punctuation
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    semicolon,
    comma,
    period,
    question,
    colon,
    equal,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    percent_equal,
    ampersand_equal,
    pipe_equal,
    caret_equal,
    shl_equal,
    shr_equal,
    plus,
    minus,
    star,
    slash,
    percent,
    plus_plus,
    minus_minus,
    equal_equal,
    bang_equal,
    less,
    greater,
    less_equal,
    greater_equal,
    ampersand_ampersand,
    pipe_pipe,
    caret_caret,
    bang,
    tilde,
    ampersand,
    pipe,
    caret,
    shl,
    shr,

    /// How the tag is written, for messages (`;`, `import`, ...), or its kind.
    pub fn describe(t: Tag) []const u8 {
        return switch (t) {
            .eof => "end of file",
            .identifier => "a name",
            .int_literal => "an integer",
            .float_literal => "a number",
            .string_literal => "a string",
            else => lexeme(t).?,
        };
    }

    /// The fixed text of a keyword or punctuation tag.
    pub fn lexeme(t: Tag) ?[]const u8 {
        return switch (t) {
            .eof, .identifier, .int_literal, .float_literal, .string_literal => null,
            .l_paren => "(",
            .r_paren => ")",
            .l_bracket => "[",
            .r_bracket => "]",
            .l_brace => "{",
            .r_brace => "}",
            .semicolon => ";",
            .comma => ",",
            .period => ".",
            .question => "?",
            .colon => ":",
            .equal => "=",
            .plus_equal => "+=",
            .minus_equal => "-=",
            .star_equal => "*=",
            .slash_equal => "/=",
            .percent_equal => "%=",
            .ampersand_equal => "&=",
            .pipe_equal => "|=",
            .caret_equal => "^=",
            .shl_equal => "<<=",
            .shr_equal => ">>=",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .plus_plus => "++",
            .minus_minus => "--",
            .equal_equal => "==",
            .bang_equal => "!=",
            .less => "<",
            .greater => ">",
            .less_equal => "<=",
            .greater_equal => ">=",
            .ampersand_ampersand => "&&",
            .pipe_pipe => "||",
            .caret_caret => "^^",
            .bang => "!",
            .tilde => "~",
            .ampersand => "&",
            .pipe => "|",
            .caret => "^",
            .shl => "<<",
            .shr => ">>",
            else => @tagName(t)[3..],
        };
    }
};

/// Keywords by spelling.
pub const keywords = std.StaticStringMap(Tag).initComptime(blk: {
    @setEvalBranchQuota(10_000);
    const tags = std.enums.values(Tag);
    var n = 0;
    for (tags) |t| {
        if (std.mem.startsWith(u8, @tagName(t), "kw_")) n += 1;
    }
    var kv: [n]struct { []const u8, Tag } = undefined;
    var i = 0;
    for (tags) |t| {
        if (std.mem.startsWith(u8, @tagName(t), "kw_")) {
            kv[i] = .{ @tagName(t)[3..], t };
            i += 1;
        }
    }
    break :blk kv;
});

const Token = @This();

tag: Tag,
start: u32,
end: u32,

test "every keyword is found by its spelling and spells itself" {
    for (std.enums.values(Tag)) |t| {
        if (!std.mem.startsWith(u8, @tagName(t), "kw_")) continue;
        try std.testing.expectEqual(t, keywords.get(t.lexeme().?).?);
    }
    try std.testing.expectEqual(@as(?Tag, null), keywords.get("vec3"));
}
