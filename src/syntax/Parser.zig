//! Tokens to a syntax tree. Recursive descent, one token of look-ahead (a few more to tell
//! a declaration from an expression), and recovery: an error is reported, the parser skips
//! to the end of the statement or module item it was in and goes on, so one mistake gives
//! one diagnostic and the rest of the file is still checked.
//!
//! Nesting is bounded by `Limits.nesting`, so no input can exhaust the stack.

const std = @import("std");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Limits = @import("../limits.zig").Limits;
const Token = @import("Token.zig");
const Lexer = @import("Lexer.zig");
const Ast = @import("Ast.zig");
const Tag = Token.Tag;
const Index = Ast.Index;
const Range = Ast.Range;
const Data = Ast.Data;

pub const Error = error{OutOfMemory};
const ParseError = error{ OutOfMemory, Syntax };

/// The tree of `text`. Always returns a tree (with `invalid` nodes and missing items where
/// the text was wrong); `diags.errors` says whether it can be trusted. The tree's arrays
/// are owned by the caller (`Ast.deinit`); it refers to `text`, which must outlive it.
pub fn parse(
    gpa: std.mem.Allocator,
    src: Source.Id,
    text: []const u8,
    limits: Limits,
    diags: *Diagnostic.List,
) Error!Ast {
    const tokens = try Lexer.tokenize(gpa, src, text, limits, diags);
    errdefer gpa.free(tokens);
    var p: Parser = .{ .gpa = gpa, .src = src, .text = text, .tokens = tokens, .limits = limits, .diags = diags };
    defer p.scratch.deinit(gpa);
    errdefer p.nodes.deinit(gpa);
    errdefer p.extra.deinit(gpa);
    const items = try p.module();
    const nodes = try p.nodes.toOwnedSlice(gpa);
    errdefer gpa.free(nodes);
    return .{
        .src = src,
        .text = text,
        .tokens = tokens,
        .nodes = nodes,
        .extra = try p.extra.toOwnedSlice(gpa),
        .items = items,
    };
}

const Parser = @This();

gpa: std.mem.Allocator,
src: Source.Id,
text: []const u8,
tokens: []const Token,
limits: Limits,
diags: *Diagnostic.List,
i: u32 = 0,
depth: u16 = 0,
nodes: std.ArrayList(Ast.Node) = .empty,
extra: std.ArrayList(u32) = .empty,
/// lists being built; nested lists share it as a stack
scratch: std.ArrayList(u32) = .empty,
/// the token of the last error, so that one place gives one diagnostic
last_error: u32 = std.math.maxInt(u32),

// ---------------------------------------------------------------- tokens

fn tag(p: *const Parser) Tag {
    return p.tokens[p.i].tag;
}

fn tagAt(p: *const Parser, ahead: u32) Tag {
    const j = @min(p.i + ahead, @as(u32, @intCast(p.tokens.len - 1)));
    return p.tokens[j].tag;
}

fn text_(p: *const Parser, t: u32) []const u8 {
    return p.text[p.tokens[t].start..p.tokens[t].end];
}

fn next(p: *Parser) u32 {
    const t = p.i;
    if (p.tokens[t].tag != .eof) p.i += 1;
    return t;
}

fn eat(p: *Parser, t: Tag) ?u32 {
    return if (p.tag() == t) p.next() else null;
}

const expected_messages = blk: {
    const tags = std.enums.values(Tag);
    var m: [tags.len][]const u8 = undefined;
    for (tags) |t| m[@backingInt(t)] = "expected " ++ (if (t.lexeme() != null) "`" ++ t.lexeme().? ++ "`" else t.describe());
    break :blk m;
};

fn expect(p: *Parser, t: Tag) ParseError!u32 {
    if (p.eat(t)) |k| return k;
    return p.fail(.expected_token, expected_messages[@backingInt(t)], null);
}

fn isKeyword(t: Tag) bool {
    return std.mem.startsWith(u8, @tagName(t), "kw_");
}

const keyword_hint = "BULG's own declarations (`import`, `alias`, `block`, `param`, `spec`, " ++
    "`extern`, `program`, `template`, `link`) are keywords: rename the variable";

fn expectName(p: *Parser) ParseError!u32 {
    if (p.eat(.identifier)) |k| return k;
    if (isKeyword(p.tag())) {
        try p.report(.expected_token, p.i, "expected a name; this word is a keyword", keyword_hint);
        _ = p.next(); // so that recovery does not take it for the start of an item
        return error.Syntax;
    }
    return p.fail(.expected_token, "expected a name", null);
}

// ---------------------------------------------------------------- diagnostics

fn report(p: *Parser, code: Diagnostic.Code, t: u32, message: []const u8, hint: ?[]const u8) Error!void {
    if (t == p.last_error) return;
    p.last_error = t;
    const tok = p.tokens[t];
    try p.diags.add(p.gpa, .{
        .severity = .@"error",
        .code = code,
        .span = .{ .src = p.src, .start = tok.start, .end = tok.end },
        .message = message,
        .hint = hint,
    });
}

/// Reports at the current token and unwinds to the nearest recovery point.
fn fail(p: *Parser, code: Diagnostic.Code, message: []const u8, hint: ?[]const u8) ParseError {
    try p.report(code, p.i, message, hint);
    return error.Syntax;
}

fn enter(p: *Parser) ParseError!void {
    if (p.depth >= p.limits.nesting)
        return p.fail(.nesting_too_deep, "nested deeper than the session's limit", null);
    p.depth += 1;
}

fn leave(p: *Parser) void {
    p.depth -= 1;
}

// ---------------------------------------------------------------- building

fn add(p: *Parser, tok: u32, data: Data) Error!Index {
    const i: Index = @fromBackingInt(@intCast(@as(u32, @intCast(p.nodes.items.len))));
    try p.nodes.append(p.gpa, .{ .tok = tok, .data = data });
    return i;
}

/// Where a list starts on the scratch stack.
fn mark(p: *const Parser) u32 {
    return @intCast(p.scratch.items.len);
}

fn push(p: *Parser, v: anytype) Error!void {
    const x: u32 = switch (@TypeOf(v)) {
        Index => @backingInt(v),
        else => v,
    };
    try p.scratch.append(p.gpa, x);
}

/// Moves the scratch entries from `start` into `extra` as one list.
fn list(p: *Parser, start: u32) Error!Range {
    const items = p.scratch.items[start..];
    const r: Range = .{ .start = @intCast(p.extra.items.len), .len = @intCast(items.len) };
    try p.extra.appendSlice(p.gpa, items);
    p.scratch.shrinkRetainingCapacity(start);
    return r;
}

// ---------------------------------------------------------------- recovery

/// After an error in a statement: skips to just after its `;`, or to the `}` that closes
/// the block it is in (not consumed), keeping braces and parentheses balanced.
fn syncStatement(p: *Parser) void {
    var braces: u32 = 0;
    var parens: u32 = 0;
    while (true) switch (p.tag()) {
        .eof => return,
        .l_paren => {
            parens += 1;
            _ = p.next();
        },
        .r_paren => {
            parens -|= 1;
            _ = p.next();
        },
        .l_brace => {
            braces += 1;
            _ = p.next();
        },
        .r_brace => {
            if (braces == 0) return;
            braces -= 1;
            _ = p.next();
            if (braces == 0 and parens == 0) return;
        },
        .semicolon => {
            _ = p.next();
            if (braces == 0 and parens == 0) return;
        },
        else => _ = p.next(),
    };
}

fn startsItem(t: Tag) bool {
    return switch (t) {
        .kw_import, .kw_alias, .kw_uniform, .kw_struct, .kw_program, .kw_extern, .kw_param, .kw_spec, .kw_const, .kw_layout, .kw_in, .kw_out, .kw_flat => true,
        else => false,
    };
}

/// After an error in a module item: skips past its end (a `;` or a `}` at the top level),
/// or to the next keyword that starts an item, always moving at least one token.
fn syncItem(p: *Parser, from: u32) void {
    if (p.i == from) _ = p.next();
    var braces: u32 = 0;
    while (true) switch (p.tag()) {
        .eof => return,
        .l_brace => {
            braces += 1;
            _ = p.next();
        },
        .r_brace => {
            _ = p.next();
            braces -|= 1;
            if (braces == 0) {
                _ = p.eat(.semicolon);
                return;
            }
        },
        .semicolon => {
            _ = p.next();
            if (braces == 0) return;
        },
        else => |t| {
            if (braces == 0 and startsItem(t)) return;
            _ = p.next();
        },
    };
}

// ---------------------------------------------------------------- module

fn module(p: *Parser) Error!Range {
    const start = p.mark();
    while (p.tag() != .eof) {
        const from = p.i;
        const m = p.mark();
        if (p.item()) |it| {
            if (it != .none) try p.push(it);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                // drop the lists the failed item had started
                p.scratch.shrinkRetainingCapacity(m);
                p.syncItem(from);
            },
        }
    }
    return p.list(start);
}

fn item(p: *Parser) ParseError!Index {
    switch (p.tag()) {
        .kw_import => return p.import(),
        .kw_alias => {
            const kw = p.next();
            const name = try p.expectName();
            _ = try p.expect(.equal);
            const value = try p.expr();
            _ = try p.expect(.semicolon);
            return p.add(kw, .{ .alias = .{ .name = name, .value = value } });
        },
        .kw_struct => {
            const kw = p.next();
            const name = try p.expectName();
            const fields = try p.members();
            return p.add(kw, .{ .struct_decl = .{ .name = name, .fields = fields } });
        },
        .kw_program => return p.program(),
        .kw_precision => {
            try p.report(.precision_statement, p.i, "BULG has no precision statements", "precision is chosen for each target by the emitter; remove the line");
            p.syncStatement();
            return .none;
        },
        .kw_uniform => if (p.tagAt(1) == .kw_block) {
            const kw = p.next();
            _ = p.next();
            const name = try p.expectName();
            const ms = try p.members();
            return p.add(kw, .{ .uniform_block = .{ .name = name, .members = ms } });
        },
        .semicolon => {
            _ = p.next();
            return .none;
        },
        else => {},
    }
    return p.declaration(.module);
}

fn import(p: *Parser) ParseError!Index {
    const kw = p.next();
    const path = try p.expect(.string_literal);
    const start = p.mark();
    if (p.eat(.colon) != null) {
        try p.push(try p.expectName());
        while (p.eat(.comma) != null) try p.push(try p.expectName());
    }
    _ = try p.expect(.semicolon);
    return p.add(kw, .{ .import = .{ .path = path, .names = try p.list(start) } });
}

/// `{ type name; ... };` for a struct or a uniform block
fn members(p: *Parser) ParseError!Range {
    _ = try p.expect(.l_brace);
    const start = p.mark();
    while (p.tag() != .r_brace and p.tag() != .eof) {
        const m = p.mark();
        if (p.declaration(.member)) |d| {
            try p.push(d);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                p.scratch.shrinkRetainingCapacity(m);
                p.syncStatement();
            },
        }
    }
    _ = try p.expect(.r_brace);
    _ = try p.expect(.semicolon);
    return p.list(start);
}

fn program(p: *Parser) ParseError!Index {
    const kw = p.next();
    const is_template = p.eat(.kw_template) != null;
    const name = try p.expectName();
    var parent: u32 = 0;
    if (p.eat(.colon) != null) parent = try p.expectName();
    const start = p.mark();
    if (p.eat(.semicolon) == null) {
        _ = try p.expect(.l_brace);
        while (p.tag() != .r_brace and p.tag() != .eof) {
            if (p.programItem()) |it| {
                try p.push(it);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => p.syncStatement(),
            }
        }
        _ = try p.expect(.r_brace);
        _ = p.eat(.semicolon);
    }
    return p.add(kw, .{ .program = .{ .name = name, .parent = parent, .is_template = is_template, .items = try p.list(start) } });
}

fn programItem(p: *Parser) ParseError!Index {
    const t = p.i;
    const kind: Ast.ProgramItemKind = switch (p.tag()) {
        .kw_link => .link,
        .kw_spec => .spec,
        .identifier => if (std.mem.eql(u8, p.text_(t), "vertex"))
            .vertex
        else if (std.mem.eql(u8, p.text_(t), "fragment"))
            .fragment
        else
            return p.fail(.expected_token, "expected `vertex`, `fragment`, `link` or `spec`", null),
        else => return p.fail(.expected_token, "expected `vertex`, `fragment`, `link` or `spec`", null),
    };
    _ = p.next();
    if (kind == .spec) {
        const name = try p.expectName();
        _ = try p.expect(.equal);
        const value = try p.expr();
        _ = try p.expect(.semicolon);
        return p.add(t, .{ .program_item = .{ .kind = kind, .name = name, .value = value } });
    }
    const file = try p.expect(.string_literal);
    _ = try p.expect(.semicolon);
    return p.add(t, .{ .program_item = .{ .kind = kind, .name = file, .value = .none } });
}

// ---------------------------------------------------------------- declarations

const DeclContext = enum { module, member, local, for_init };

/// A variable declaration, or at module level also a function or a prototype.
fn declaration(p: *Parser, ctx: DeclContext) ParseError!Index {
    const first = p.i;
    var location: Index = .none;
    if (p.tag() == .kw_layout) {
        const lt = p.next();
        _ = try p.expect(.l_paren);
        const key = try p.expectName();
        if (!std.mem.eql(u8, p.text_(key), "location")) {
            try p.report(.unknown_layout, key, "unknown layout qualifier", "BULG knows `layout(location = n)`");
            return error.Syntax;
        }
        _ = try p.expect(.equal);
        location = try p.expr();
        _ = try p.expect(.r_paren);
        _ = lt;
    }
    var quals: Ast.Qualifier = .{};
    var is_extern = false;
    var any_qual = false;
    while (true) {
        switch (p.tag()) {
            .kw_const => quals.@"const" = true,
            .kw_uniform => quals.uniform = true,
            .kw_in => quals.in = true,
            .kw_out => quals.out = true,
            .kw_flat => quals.flat = true,
            .kw_param => quals.param = true,
            .kw_spec => quals.spec = true,
            .kw_extern => is_extern = true,
            else => break,
        }
        any_qual = true;
        _ = p.next();
    }
    if (p.tag() != .identifier) {
        if (ctx == .module and !any_qual and location == .none)
            return p.fail(.expected_declaration, "expected a declaration", null);
        return p.fail(.expected_token, "expected a type", null);
    }
    const ty = try p.typeName();
    const name = try p.expectName();

    if (p.tag() == .l_paren and ctx == .module) {
        if (location != .none or (any_qual and !(is_extern and @as(u8, @bitCast(quals)) == 0)))
            try p.report(.misplaced_qualifier, first, "a function takes no qualifiers but `extern`", null);
        return p.function(ty, name, is_extern);
    }
    if (is_extern) {
        try p.report(.misplaced_qualifier, first, "`extern` is for functions", "an `extern` function is a hole another file fills: `extern float map(vec3 p);`");
    }

    const start = p.mark();
    try p.push(try p.declarator(name));
    while (p.eat(.comma) != null) try p.push(try p.declarator(try p.expectName()));
    const declarators = try p.list(start);

    const meta_start = p.mark();
    if (p.tag() == .l_brace and ctx != .for_init) {
        _ = p.next();
        while (p.tag() != .r_brace and p.tag() != .eof) {
            const key = try p.expectName();
            var has_parens = false;
            const args_start = p.mark();
            if (p.eat(.l_paren) != null) {
                has_parens = true;
                if (p.tag() != .r_paren) {
                    try p.push(try p.expr());
                    while (p.eat(.comma) != null) try p.push(try p.expr());
                }
                _ = try p.expect(.r_paren);
            }
            const args = try p.list(args_start);
            try p.push(try p.add(key, .{ .meta_entry = .{ .key = key, .args = args, .has_parens = has_parens } }));
            if (p.eat(.comma) == null) break;
        }
        _ = try p.expect(.r_brace);
    }
    const meta = try p.list(meta_start);
    if (ctx != .for_init) _ = try p.expect(.semicolon);
    return p.add(first, .{ .var_decl = .{ .quals = quals, .location = location, .type = ty, .declarators = declarators, .meta = meta } });
}

fn typeName(p: *Parser) ParseError!Index {
    const name = try p.expectName();
    var len: Index = .none;
    if (p.eat(.l_bracket) != null) {
        len = try p.expr();
        _ = try p.expect(.r_bracket);
    }
    return p.add(name, .{ .type_name = .{ .name = name, .array_len = len } });
}

fn declarator(p: *Parser, name: u32) ParseError!Index {
    var len: Index = .none;
    if (p.eat(.l_bracket) != null) {
        len = try p.expr();
        _ = try p.expect(.r_bracket);
    }
    var init: Index = .none;
    // a member's initialiser is its default (a uniform block's); the checker says where
    // one is allowed
    if (p.eat(.equal) != null) init = try p.assignment();
    return p.add(name, .{ .declarator = .{ .name = name, .array_len = len, .init = init } });
}

fn function(p: *Parser, ret: Index, name: u32, is_extern: bool) ParseError!Index {
    _ = try p.expect(.l_paren);
    const start = p.mark();
    // `(void)` is an empty list
    if (p.tag() == .identifier and std.mem.eql(u8, p.text_(p.i), "void") and p.tagAt(1) == .r_paren) _ = p.next();
    if (p.tag() != .r_paren) {
        try p.push(try p.param());
        while (p.eat(.comma) != null) try p.push(try p.param());
    }
    _ = try p.expect(.r_paren);
    const params = try p.list(start);
    var body_: Index = .none;
    if (p.eat(.semicolon) == null) {
        if (is_extern) return p.fail(.expected_token, "expected `;`: an `extern` function has no body", null);
        body_ = try p.block();
    }
    return p.add(name, .{ .function = .{ .ret = ret, .name = name, .params = params, .body = body_, .is_extern = is_extern } });
}

fn param(p: *Parser) ParseError!Index {
    const first = p.i;
    const is_const = p.eat(.kw_const) != null;
    const dir: Ast.ParamDir = switch (p.tag()) {
        .kw_in => .in,
        .kw_out => .out,
        .kw_inout => .inout,
        else => .none,
    };
    if (dir != .none) _ = p.next();
    const ty = try p.typeName();
    var name: u32 = 0;
    var len: Index = .none;
    if (isKeyword(p.tag()) and p.tag() != .kw_true and p.tag() != .kw_false) _ = try p.expectName();
    if (p.eat(.identifier)) |n| {
        name = n;
        if (p.eat(.l_bracket) != null) {
            len = try p.expr();
            _ = try p.expect(.r_bracket);
        }
    }
    return p.add(first, .{ .param = .{ .dir = dir, .is_const = is_const, .type = ty, .name = name, .array_len = len } });
}

// ---------------------------------------------------------------- statements

fn block(p: *Parser) ParseError!Index {
    const open = try p.expect(.l_brace);
    try p.enter();
    defer p.leave();
    const start = p.mark();
    while (p.tag() != .r_brace and p.tag() != .eof) {
        const m = p.mark();
        if (p.statement()) |s| {
            try p.push(s);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                p.scratch.shrinkRetainingCapacity(m);
                p.syncStatement();
            },
        }
    }
    const stmts = try p.list(start);
    _ = try p.expect(.r_brace);
    return p.add(open, .{ .block = .{ .stmts = stmts } });
}

/// Whether the tokens from here are a declaration: `T name`, `T[n] name`, or a qualifier.
fn atDeclaration(p: *const Parser) bool {
    switch (p.tag()) {
        .kw_const, .kw_uniform, .kw_in, .kw_out, .kw_flat, .kw_param, .kw_spec, .kw_layout => return true,
        .identifier => {},
        else => return false,
    }
    if (p.tagAt(1) == .identifier) return true;
    // `float spec = 1.;`: no expression is a name followed by a keyword, so this is a
    // declaration whose name is a keyword, and the diagnostic can say so
    if (isKeyword(p.tagAt(1)) and p.tagAt(1) != .kw_true and p.tagAt(1) != .kw_false) return true;
    if (p.tagAt(1) != .l_bracket) return false;
    // `T[...] name`: find the matching `]`
    var j = p.i + 2;
    var depth: u32 = 1;
    while (j < p.tokens.len) : (j += 1) switch (p.tokens[j].tag) {
        .l_bracket => depth += 1,
        .r_bracket => {
            depth -= 1;
            if (depth == 0) return j + 1 < p.tokens.len and p.tokens[j + 1].tag == .identifier;
        },
        .eof, .semicolon, .l_brace, .r_brace => return false,
        else => {},
    };
    return false;
}

fn statement(p: *Parser) ParseError!Index {
    try p.enter();
    defer p.leave();
    const t = p.i;
    switch (p.tag()) {
        .l_brace => return p.block(),
        .semicolon => {
            _ = p.next();
            return p.add(t, .empty_stmt);
        },
        .kw_if => {
            _ = p.next();
            _ = try p.expect(.l_paren);
            const cond = try p.expr();
            _ = try p.expect(.r_paren);
            const then = try p.statement();
            var else_: Index = .none;
            if (p.eat(.kw_else) != null) else_ = try p.statement();
            return p.add(t, .{ .if_stmt = .{ .cond = cond, .then = then, .@"else" = else_ } });
        },
        .kw_for => {
            _ = p.next();
            _ = try p.expect(.l_paren);
            var init: Index = .none;
            if (p.tag() != .semicolon) {
                if (p.atDeclaration()) {
                    init = try p.declaration(.for_init);
                } else {
                    const e = try p.expr();
                    init = try p.add(p.nodes.items[@backingInt(e)].tok, .{ .expr_stmt = .{ .expr = e } });
                }
            }
            _ = try p.expect(.semicolon);
            var cond: Index = .none;
            if (p.tag() != .semicolon) cond = try p.expr();
            _ = try p.expect(.semicolon);
            var step: Index = .none;
            if (p.tag() != .r_paren) step = try p.expr();
            _ = try p.expect(.r_paren);
            const body_ = try p.statement();
            return p.add(t, .{ .for_stmt = .{ .init = init, .cond = cond, .step = step, .body = body_ } });
        },
        .kw_return => {
            _ = p.next();
            var value: Index = .none;
            if (p.tag() != .semicolon) value = try p.expr();
            _ = try p.expect(.semicolon);
            return p.add(t, .{ .return_stmt = .{ .value = value } });
        },
        .kw_break, .kw_continue, .kw_discard => {
            const k = p.tag();
            _ = p.next();
            _ = try p.expect(.semicolon);
            return p.add(t, switch (k) {
                .kw_break => .break_stmt,
                .kw_continue => .continue_stmt,
                else => .discard_stmt,
            });
        },
        .kw_while, .kw_do, .kw_switch => return p.unsupported(),
        .kw_precision => {
            try p.report(.precision_statement, t, "BULG has no precision statements", "precision is chosen for each target by the emitter; remove the line");
            return error.Syntax;
        },
        else => {},
    }
    if (p.atDeclaration()) return p.declaration(.local);
    const e = try p.expr();
    _ = try p.expect(.semicolon);
    return p.add(t, .{ .expr_stmt = .{ .expr = e } });
}

/// `while`, `do` and `switch`: reported, then read through so that their bodies do not
/// cause more errors.
fn unsupported(p: *Parser) ParseError!Index {
    const t = p.i;
    const k = p.tag();
    try p.report(.unsupported_statement, t, switch (k) {
        .kw_while => "`while` is not in BULG v0",
        .kw_do => "`do` is not in BULG v0",
        else => "`switch` is not in BULG v0",
    }, switch (k) {
        .kw_switch => "use `if` / `else if`",
        else => "use a counted loop, `for (int i = 0; i < N; i++)`, with `break`",
    });
    _ = p.next();
    switch (k) {
        .kw_while => {
            _ = try p.expect(.l_paren);
            _ = try p.expr();
            _ = try p.expect(.r_paren);
            _ = try p.statement();
        },
        .kw_do => {
            _ = try p.statement();
            _ = try p.expect(.kw_while);
            _ = try p.expect(.l_paren);
            _ = try p.expr();
            _ = try p.expect(.r_paren);
            _ = try p.expect(.semicolon);
        },
        else => {
            _ = try p.expect(.l_paren);
            _ = try p.expr();
            _ = try p.expect(.r_paren);
            if (p.tag() != .l_brace) return p.fail(.expected_token, "expected `{`", null);
            p.syncStatement(); // the braced body, balanced
        },
    }
    return p.add(t, .invalid);
}

// ---------------------------------------------------------------- expressions

pub fn expr(p: *Parser) ParseError!Index {
    return p.assignment();
}

fn isAssignOp(t: Tag) bool {
    return switch (t) {
        .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .ampersand_equal, .pipe_equal, .caret_equal, .shl_equal, .shr_equal => true,
        else => false,
    };
}

fn assignment(p: *Parser) ParseError!Index {
    try p.enter();
    defer p.leave();
    const lhs = try p.ternary();
    if (isAssignOp(p.tag())) {
        const op = p.next();
        const rhs = try p.assignment();
        return p.add(op, .{ .assign = .{ .lhs = lhs, .rhs = rhs } });
    }
    return lhs;
}

fn ternary(p: *Parser) ParseError!Index {
    const cond = try p.binary(1);
    if (p.tag() != .question) return cond;
    const q = p.next();
    try p.enter();
    defer p.leave();
    const then = try p.assignment();
    _ = try p.expect(.colon);
    const else_ = try p.assignment();
    return p.add(q, .{ .ternary = .{ .cond = cond, .then = then, .@"else" = else_ } });
}

fn binary(p: *Parser, min: u8) ParseError!Index {
    var lhs = try p.unary();
    while (Ast.binaryPrecedence(p.tag())) |prec| {
        if (prec < min) break;
        const op = p.next();
        try p.enter();
        defer p.leave();
        const rhs = try p.binary(prec + 1);
        lhs = try p.add(op, .{ .binary = .{ .lhs = lhs, .rhs = rhs } });
    }
    return lhs;
}

fn unary(p: *Parser) ParseError!Index {
    switch (p.tag()) {
        .minus, .plus, .bang, .tilde, .plus_plus, .minus_minus => {
            const op = p.next();
            try p.enter();
            defer p.leave();
            const operand = try p.unary();
            return p.add(op, .{ .prefix = .{ .operand = operand } });
        },
        else => return p.postfix(),
    }
}

fn postfix(p: *Parser) ParseError!Index {
    var e = try p.primary();
    while (true) switch (p.tag()) {
        .l_paren => {
            const open = p.next();
            _ = open;
            const start = p.mark();
            if (p.tag() != .r_paren) {
                try p.push(try p.assignment());
                while (p.eat(.comma) != null) try p.push(try p.assignment());
            }
            _ = try p.expect(.r_paren);
            const callee_tok = p.nodes.items[@backingInt(e)].tok;
            e = try p.add(callee_tok, .{ .call = .{ .callee = e, .args = try p.list(start) } });
        },
        .l_bracket => {
            const open = p.next();
            const ix = try p.expr();
            _ = try p.expect(.r_bracket);
            e = try p.add(open, .{ .index = .{ .base = e, .index = ix } });
        },
        .period => {
            _ = p.next();
            const name = try p.expectName();
            e = try p.add(name, .{ .field = .{ .base = e } });
        },
        .plus_plus, .minus_minus => {
            const op = p.next();
            e = try p.add(op, .{ .postfix = .{ .operand = e } });
        },
        else => return e,
    };
}

fn primary(p: *Parser) ParseError!Index {
    const t = p.i;
    switch (p.tag()) {
        // a string is a literal only in metadata (`label("Speed")`); the checker says so
        .int_literal, .float_literal, .string_literal, .kw_true, .kw_false => {
            _ = p.next();
            return p.add(t, .literal);
        },
        .identifier => {
            _ = p.next();
            return p.add(t, .ident);
        },
        .l_paren => {
            _ = p.next();
            try p.enter();
            defer p.leave();
            const e = try p.expr();
            _ = try p.expect(.r_paren);
            return e;
        },
        else => |k| {
            if (isKeyword(k) and k != .kw_true and k != .kw_false) {
                try p.report(.expected_expression, p.i, "expected an expression; this word is a keyword", keyword_hint);
                _ = p.next();
                return error.Syntax;
            }
            return p.fail(.expected_expression, "expected an expression", null);
        },
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseText(gpa: std.mem.Allocator, text: []const u8, diags: *Diagnostic.List) !Ast {
    return parse(gpa, @fromBackingInt(@intCast(0)), text, .{}, diags);
}

/// Prints `text`'s tree; the print must parse without errors and print the same again.
fn roundTrip(text: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    var diags: Diagnostic.List = .{ .limit = 16 };
    defer diags.deinit(gpa);
    var a = try parseText(gpa, text, &diags);
    defer a.deinit(gpa);
    if (diags.errors != 0) {
        std.debug.print("unexpected diagnostic: {s} at {d}\n", .{ diags.items.items[0].message, diags.items.items[0].span.start });
        return error.TestUnexpectedResult;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try a.print(&out.writer);
    try testing.expectEqualStrings(expected, out.written());

    var diags2: Diagnostic.List = .{ .limit = 16 };
    defer diags2.deinit(gpa);
    var b = try parseText(gpa, out.written(), &diags2);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), diags2.errors);
    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try b.print(&out2.writer);
    try testing.expectEqualStrings(out.written(), out2.written());
    try expectSameShape(&a, &b);
}

/// The two trees have the same shape: printed with every operand in parentheses, they are
/// the same text. (A printer that dropped a needed parenthesis would print stably but
/// change the tree; this catches it.)
fn expectSameShape(a: *const Ast, b: *const Ast) !void {
    const gpa = testing.allocator;
    var x: std.Io.Writer.Allocating = .init(gpa);
    defer x.deinit();
    var y: std.Io.Writer.Allocating = .init(gpa);
    defer y.deinit();
    try a.printWith(&x.writer, .{ .all_parens = true });
    try b.printWith(&y.writer, .{ .all_parens = true });
    try testing.expectEqualStrings(x.written(), y.written());
}

/// The codes of the diagnostics `text` gives, in order.
fn expectCodes(text: []const u8, codes: []const Diagnostic.Code) !void {
    const gpa = testing.allocator;
    var diags: Diagnostic.List = .{ .limit = 16 };
    defer diags.deinit(gpa);
    var a = try parseText(gpa, text, &diags);
    defer a.deinit(gpa);
    var got: [16]Diagnostic.Code = undefined;
    for (diags.items.items, 0..) |d, k| got[k] = d.code;
    try testing.expectEqualSlices(Diagnostic.Code, codes, got[0..diags.items.items.len]);
}

test "module items print in canonical form" {
    try roundTrip(
        \\import "common";
        \\import "art/art_core" : palette,grain ;
        \\alias uTime = gTime;
        \\uniform block Frame { vec4 gCam = vec4(1.); float gTime; vec4 gSite[8]; };
        \\struct Hit { float d; vec3 n; };
        \\uniform sampler2D uSim,uPrev;
        \\uniform vec4 uSite[8];
        \\param float speed = 1.0 { range(0., 4.), label("Speed") };
        \\spec bool FADE = false;
        \\const float TAU = 6.28318530718;
        \\layout(location=0) in vec3 aPos;
        \\flat out int vKind;
        \\vec3 cell, n;
        \\extern float map(vec3 p);
        \\float sdBox(vec3 p, vec3 b);
        \\program template world { vertex "fullscreen"; fragment "world_main"; spec FADE = true; }
        \\program gyroid_reef : world;
        \\program plain {}
        \\program cover_star_lattice : cover { link "worlds/star_lattice"; spec ART_COVER = true; }
        \\
    ,
        \\import "common";
        \\import "art/art_core" : palette, grain;
        \\alias uTime = gTime;
        \\uniform block Frame {
        \\    vec4 gCam = vec4(1.);
        \\    float gTime;
        \\    vec4 gSite[8];
        \\};
        \\struct Hit {
        \\    float d;
        \\    vec3 n;
        \\};
        \\uniform sampler2D uSim, uPrev;
        \\uniform vec4 uSite[8];
        \\param float speed = 1.0 { range(0., 4.), label("Speed") };
        \\spec bool FADE = false;
        \\const float TAU = 6.28318530718;
        \\layout(location = 0) in vec3 aPos;
        \\flat out int vKind;
        \\vec3 cell, n;
        \\extern float map(vec3 p);
        \\float sdBox(vec3 p, vec3 b);
        \\program template world {
        \\    vertex "fullscreen";
        \\    fragment "world_main";
        \\    spec FADE = true;
        \\}
        \\program gyroid_reef : world;
        \\program plain;
        \\program cover_star_lattice : cover {
        \\    link "worlds/star_lattice";
        \\    spec ART_COVER = true;
        \\}
        \\
    );
}

test "the README's example parses" {
    const readme = @embedFile("README.md");
    const start = std.mem.indexOf(u8, readme, "```glsl\n").? + 8;
    const end = start + std.mem.indexOf(u8, readme[start..], "```").?;
    // its function body is elided
    const gpa = testing.allocator;
    const text = try std.mem.replaceOwned(u8, gpa, readme[start..end], "{ ... }", "{ return vec4(uv, 0., 1.); }");
    defer gpa.free(text);
    var diags: Diagnostic.List = .{ .limit = 16 };
    defer diags.deinit(gpa);
    var a = try parseText(gpa, text, &diags);
    defer a.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), diags.errors);
    try testing.expectEqual(@as(u32, 9), a.items.len);
}

test "functions and statements" {
    try roundTrip(
        \\void mbCam(out vec3 ro, inout vec3 rt, const in float k[3], vec2) {
        \\  float[9] w = float[9](1., 2., 1., 2., 4., 2., 1., 2., 1.);
        \\  for (int i = 0; i < 8; i++) { if (i == 3) continue; else if (i > 6) break; }
        \\  for (;;) return;
        \\  if (k[0] > 0.) discard;
        \\  ;
        \\  {}
        \\  ro += rt * k[1];
        \\}
        \\vec4 f(void) { return vec4(0); }
        \\
    ,
        \\void mbCam(out vec3 ro, inout vec3 rt, const in float k[3], vec2) {
        \\    float[9] w = float[9](1., 2., 1., 2., 4., 2., 1., 2., 1.);
        \\    for (int i = 0; i < 8; i++) {
        \\        if (i == 3) {
        \\            continue;
        \\        } else if (i > 6) {
        \\            break;
        \\        }
        \\    }
        \\    for (;;) {
        \\        return;
        \\    }
        \\    if (k[0] > 0.) {
        \\        discard;
        \\    }
        \\    ;
        \\    {
        \\    }
        \\    ro += rt * k[1];
        \\}
        \\vec4 f() {
        \\    return vec4(0);
        \\}
        \\
    );
}

test "the shape print puts every operand in parentheses" {
    const gpa = testing.allocator;
    var diags: Diagnostic.List = .{ .limit = 16 };
    defer diags.deinit(gpa);
    var a = try parseText(gpa, "void f() { a = b + c * -d[1] ? e : f(g + h); }", &diags);
    defer a.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try a.printWith(&out.writer, .{ .all_parens = true });
    try testing.expectEqualStrings(
        \\void f() {
        \\    a = (b + (c * (-d[1]))) ? e : f(g + h);
        \\}
        \\
    , out.written());
}

test "precedence: parentheses only where they are needed" {
    try roundTrip(
        \\void f() {
        \\  a = (b + c) * d - (e - f) - g / (h * i);
        \\  a = -(b * c) + -b * c + - -b + -(--b) + !(x && y);
        \\  a = x || y && z | w ^ v & u == t < s << r;
        \\  a = (((x || y) && z) | w) ^ (v & (u == t)) < s;
        \\  a = b = c += d;
        \\  a = c ? d : e ? f : g;
        \\  a = (c ? d : e) ? f : g;
        \\  (c ? a : b) = 1.;
        \\  a = v.xyz[1] + m[0][2] + f(x)(y).w + i++ + ++i;
        \\}
        \\
    ,
        \\void f() {
        \\    a = (b + c) * d - (e - f) - g / (h * i);
        \\    a = -(b * c) + -b * c + - -b + - --b + !(x && y);
        \\    a = x || y && z | w ^ v & u == t < s << r;
        \\    a = (((x || y) && z) | w) ^ (v & u == t) < s;
        \\    a = b = c += d;
        \\    a = c ? d : e ? f : g;
        \\    a = (c ? d : e) ? f : g;
        \\    (c ? a : b) = 1.;
        \\    a = v.xyz[1] + m[0][2] + f(x)(y).w + i++ + ++i;
        \\}
        \\
    );
}

test "an error gives one diagnostic, and parsing goes on after it" {
    // a missing `;` in a function: the next statement and the next function still parse
    try expectCodes(
        \\float f() { float a = 1. float b = 2.; return a; }
        \\float g() { return 1.; }
    , &.{.expected_token});
    // two bad items, two diagnostics
    try expectCodes(
        \\alias = 3;
        \\float ok;
        \\struct { float x; };
        \\vec3 fine;
    , &.{ .expected_token, .expected_token });
    // inside a struct, a uniform block or a program: the rest of it still parses
    try expectCodes("struct S { float x = ; float y; }; float ok;", &.{.expected_expression});
    try expectCodes("uniform block F { vec4 a; 3; vec4 b; }; float ok;", &.{.expected_token});
    try expectCodes("program p { vertex; fragment \"f\"; shader \"x\"; } float ok;", &.{ .expected_token, .expected_token });
    // stray tokens at the top level
    try expectCodes(") float ok;", &.{.expected_declaration});
    try expectCodes("float f() { a = ; }", &.{.expected_expression});
    try expectCodes("float f() { a = (x, y); }", &.{.expected_token});
}

test "a keyword used as a name says so" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "void f() { float spec = 1.; }", "void f() { a = spec * 2.; }", "float spec;", "void f(float param) {}" }) |text| {
        var diags: Diagnostic.List = .{ .limit = 16 };
        defer diags.deinit(gpa);
        var a = try parseText(gpa, text, &diags);
        defer a.deinit(gpa);
        try testing.expectEqual(@as(u32, 1), diags.errors);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "keyword") != null);
    }
}

test "GLSL forms BULG leaves out are named" {
    try expectCodes("void f() { while (x < 1.) { x += 1.; } y = 2.; }", &.{.unsupported_statement});
    try expectCodes("void f() { do { x += 1.; } while (x < 1.); }", &.{.unsupported_statement});
    try expectCodes("void f() { switch (k) { case 1: break; } y = 1; }", &.{.unsupported_statement});
    try expectCodes("precision highp float;\nfloat ok;", &.{.precision_statement});
    try expectCodes("#define X 1\nfloat ok;", &.{.preprocessor_directive});
    try expectCodes("layout(std140) uniform float a;", &.{.unknown_layout});
    try expectCodes("extern float a;", &.{.misplaced_qualifier});
    try expectCodes("uniform float f() { return 1.; }", &.{.misplaced_qualifier});
}

test "the recovered tree keeps the good items" {
    const gpa = testing.allocator;
    var diags: Diagnostic.List = .{ .limit = 16 };
    defer diags.deinit(gpa);
    var a = try parseText(gpa, "float a; alias = ; vec3 b; float f() { x = ; return 1.; }", &diags);
    defer a.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), diags.errors);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try a.print(&out.writer);
    try testing.expectEqualStrings(
        \\float a;
        \\vec3 b;
        \\float f() {
        \\    return 1.;
        \\}
        \\
    , out.written());
}

test "nesting is bounded" {
    const gpa = testing.allocator;
    const n = 100_000;
    const text = try gpa.alloc(u8, 2 * n + 32);
    defer gpa.free(text);
    var k: usize = 0;
    for ("float a = ") |c| {
        text[k] = c;
        k += 1;
    }
    @memset(text[k..][0..n], '(');
    k += n;
    text[k] = '1';
    k += 1;
    @memset(text[k..][0..n], ')');
    k += n;
    text[k] = ';';
    k += 1;
    var diags: Diagnostic.List = .{ .limit = 16 };
    defer diags.deinit(gpa);
    var a = try parse(gpa, @fromBackingInt(@intCast(0)), text[0..k], .{}, &diags);
    defer a.deinit(gpa);
    try testing.expectEqual(Diagnostic.Code.nesting_too_deep, diags.items.items[0].code);
    try testing.expectEqual(@as(u32, 1), diags.errors);

    // blocks and prefix operators too
    var diags2: Diagnostic.List = .{ .limit = 16 };
    defer diags2.deinit(gpa);
    @memset(text[0..n], '-');
    var b = try parse(gpa, @fromBackingInt(@intCast(0)), text[0..n], .{ .nesting = 64 }, &diags2);
    defer b.deinit(gpa);
    try testing.expect(diags2.errors >= 1);
}

test "random token soup never crashes and always ends" {
    const gpa = testing.allocator;
    const alphabet = [_][]const u8{
        "float", "x",    "vec3", "(",      ")",     "{", "}",       "[",     "]",      ";",       ",",      "=",     "+",     "-",     "*",    "?",      ":",
        "if",    "else", "for",  "return", "1.",    "2", "uniform", "block", "struct", "program", "import", "\"a\"", "alias", "param", "spec", "extern", "layout",
        "in",    "out",  ".",    "++",     "while", "<",
    };
    var prng: std.Random.DefaultPrng = .init(0x61696e74);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..5_000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        const n = r.intRangeAtMost(usize, 0, 60);
        for (0..n) |_| {
            w.writeAll(alphabet[r.uintLessThan(usize, alphabet.len)]) catch break;
            w.writeByte(' ') catch break;
        }
        var diags: Diagnostic.List = .{ .limit = 8 };
        defer diags.deinit(gpa);
        var a = try parse(gpa, @fromBackingInt(@intCast(0)), w.buffered(), .{ .nesting = 32 }, &diags);
        defer a.deinit(gpa);
        // whatever parsed prints, and the print parses without new errors
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try a.print(&out.writer);
        if (diags.errors == 0) {
            var d2: Diagnostic.List = .{ .limit = 8 };
            defer d2.deinit(gpa);
            var b = try parse(gpa, @fromBackingInt(@intCast(0)), out.written(), .{}, &d2);
            defer b.deinit(gpa);
            try testing.expectEqual(@as(u32, 0), d2.errors);
            try expectSameShape(&a, &b);
        }
    }
}

test "out of memory anywhere is reported, never leaked" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var diags: Diagnostic.List = .{ .limit = 4 };
            defer diags.deinit(gpa);
            var a = try parse(gpa, @fromBackingInt(@intCast(0)),
                \\import "x" : a, b;
                \\uniform block F { vec4 c; };
                \\float f(vec3 p) { for (int i = 0; i < 3; i++) p += vec3(1); return p.x ? 1. : 2.; }
                \\float g( { }
            , .{}, &diags);
            a.deinit(gpa);
        }
    }.run, .{});
}
