//! The syntax tree of one module (one source file): a flat array of nodes that refer to
//! each other by index, lists stored as ranges in `extra`, and every node tied to a token
//! for its place in the source. Literals stay tokens, so their spelling survives to the
//! emitters. Built by Parser.zig; printed back by `print`.

const std = @import("std");
const Source = @import("../Source.zig");
const Token = @import("Token.zig");

pub const Index = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(i: Index) ?u32 {
        return if (i == .none) null else @backingInt(i);
    }
};

/// A list of node indices (or token indices, where noted) in `extra`.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,
};

pub const Qualifier = packed struct(u8) {
    uniform: bool = false,
    in: bool = false,
    out: bool = false,
    flat: bool = false,
    @"const": bool = false,
    param: bool = false,
    spec: bool = false,
    _: u1 = 0,
};

pub const ParamDir = enum(u8) { none, in, out, inout };

pub const ProgramItemKind = enum(u8) { vertex, fragment, link, spec };

pub const Data = union(enum) {
    // ---- module items
    /// `import "path";` or `import "path" : a, b;` (names: token indices)
    import: struct { path: u32, names: Range },
    /// `alias name = value;`
    alias: struct { name: u32, value: Index },
    /// `uniform block Name { members };` (members: var_decl nodes)
    uniform_block: struct { name: u32, members: Range },
    /// `struct Name { fields };` (fields: var_decl nodes)
    struct_decl: struct { name: u32, fields: Range },
    /// a function, or with no body a prototype (`extern` marks a link-time hole)
    function: struct { ret: Index, name: u32, params: Range, body: Index, is_extern: bool },
    /// `program [template] name [: parent] [{ items }]` (parent: a token, 0 if none)
    program: struct { name: u32, parent: u32, is_template: bool, items: Range },
    /// `vertex "file";`, `fragment "file";`, `link "file";` (value: string token) or
    /// `spec NAME = expr;` (name: token, value: expression)
    program_item: struct { kind: ProgramItemKind, name: u32, value: Index },

    // ---- declarations, at any level
    /// `[layout(location = n)] qualifiers type a [= x], b[2] [{ meta }];`
    /// (declarators: declarator nodes; meta: meta_entry nodes)
    var_decl: struct { quals: Qualifier, location: Index, type: Index, declarators: Range, meta: Range },
    /// one name of a declaration: `name`, `name[len]`, `name = init`
    declarator: struct { name: u32, array_len: Index, init: Index },
    /// a type: a name, optionally `name[len]`
    type_name: struct { name: u32, array_len: Index },
    /// a function parameter (name: token, 0 if unnamed)
    param: struct { dir: ParamDir, is_const: bool, type: Index, name: u32, array_len: Index },
    /// `key` or `key(args)` in a `{ ... }` metadata list (args: expressions)
    meta_entry: struct { key: u32, args: Range, has_parens: bool },

    // ---- statements
    block: struct { stmts: Range },
    expr_stmt: struct { expr: Index },
    if_stmt: struct { cond: Index, then: Index, @"else": Index },
    for_stmt: struct { init: Index, cond: Index, step: Index, body: Index },
    return_stmt: struct { value: Index },
    break_stmt,
    continue_stmt,
    discard_stmt,
    empty_stmt,

    // ---- expressions (the node's token is the operator, the literal or the name)
    literal,
    ident,
    /// `-a`, `!a`, `~a`, `++a`, `--a`, `+a`
    prefix: struct { operand: Index },
    /// `a++`, `a--`
    postfix: struct { operand: Index },
    binary: struct { lhs: Index, rhs: Index },
    /// `=`, `+=`, ... (right-associative)
    assign: struct { lhs: Index, rhs: Index },
    ternary: struct { cond: Index, then: Index, @"else": Index },
    /// `f(args)`, `vec3(args)`, `float[3](args)` (callee: ident or index node)
    call: struct { callee: Index, args: Range },
    index: struct { base: Index, index: Index },
    /// `a.name`: a field or a swizzle (token: the name)
    field: struct { base: Index },
    /// a parse error's place holder, so the tree stays whole
    invalid,
};

pub const Node = struct {
    /// the token the node is about (for spans and messages)
    tok: u32,
    data: Data,
};

const Ast = @This();

src: Source.Id,
text: []const u8,
tokens: []const Token,
nodes: []const Node,
extra: []const u32,
/// the module's items
items: Range,

pub fn deinit(a: *Ast, gpa: std.mem.Allocator) void {
    gpa.free(a.tokens);
    gpa.free(a.nodes);
    gpa.free(a.extra);
    a.* = undefined;
}

pub fn node(a: *const Ast, i: Index) Node {
    return a.nodes[@backingInt(i)];
}

pub fn list(a: *const Ast, r: Range) []const u32 {
    return a.extra[r.start..][0..r.len];
}

pub fn tokenText(a: *const Ast, t: u32) []const u8 {
    const tok = a.tokens[t];
    return a.text[tok.start..tok.end];
}

pub fn span(a: *const Ast, i: Index) Source.Span {
    const tok = a.tokens[a.node(i).tok];
    return .{ .src = a.src, .start = tok.start, .end = tok.end };
}

// ---------------------------------------------------------------- printing

/// Binding strength of binary operators, weakest first (assignment and `?:` are below 1).
pub fn binaryPrecedence(tag: Token.Tag) ?u8 {
    return switch (tag) {
        .pipe_pipe => 1,
        .caret_caret => 2,
        .ampersand_ampersand => 3,
        .pipe => 4,
        .caret => 5,
        .ampersand => 6,
        .equal_equal, .bang_equal => 7,
        .less, .greater, .less_equal, .greater_equal => 8,
        .shl, .shr => 9,
        .plus, .minus => 10,
        .star, .slash, .percent => 11,
        else => null,
    };
}

const prec_assign = 0;
const prec_ternary = 1; // below every binary operator, above assignment
const prec_prefix = 13; // above the tightest binary operator (11 + 1)
const prec_postfix = 14;

/// The module as canonical BULG text: one declaration or statement per line, four-space
/// indents, spaces around binary operators, parentheses only where precedence needs them,
/// literals as written. Printing what this prints gives the same text again.
pub fn print(a: *const Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return a.printWith(w, .{});
}

pub const PrintOptions = struct {
    /// every operator's operands in parentheses: the tree's shape, for comparing trees
    all_parens: bool = false,
};

pub fn printWith(a: *const Ast, w: *std.Io.Writer, options: PrintOptions) std.Io.Writer.Error!void {
    var p: Printer = .{ .a = a, .w = w, .all_parens = options.all_parens };
    for (a.list(a.items)) |item| try p.item(@fromBackingInt(@intCast(item)));
}

const Printer = struct {
    a: *const Ast,
    w: *std.Io.Writer,
    depth: u32 = 0,
    all_parens: bool,

    fn indent(p: *Printer) !void {
        for (0..p.depth) |_| try p.w.writeAll("    ");
    }

    fn tok(p: *Printer, t: u32) !void {
        try p.w.writeAll(p.a.tokenText(t));
    }

    fn item(p: *Printer, i: Index) std.Io.Writer.Error!void {
        const n = p.a.node(i);
        switch (n.data) {
            .import => |d| {
                try p.w.writeAll("import ");
                try p.tok(d.path);
                for (p.a.list(d.names), 0..) |t, k| {
                    try p.w.writeAll(if (k == 0) " : " else ", ");
                    try p.tok(t);
                }
                try p.w.writeAll(";\n");
            },
            .alias => |d| {
                try p.w.writeAll("alias ");
                try p.tok(d.name);
                try p.w.writeAll(" = ");
                try p.expr(d.value, prec_assign);
                try p.w.writeAll(";\n");
            },
            .uniform_block => |d| {
                try p.w.writeAll("uniform block ");
                try p.tok(d.name);
                try p.members(d.members);
            },
            .struct_decl => |d| {
                try p.w.writeAll("struct ");
                try p.tok(d.name);
                try p.members(d.fields);
            },
            .function => |d| {
                if (d.is_extern) try p.w.writeAll("extern ");
                try p.typeName(d.ret);
                try p.w.writeByte(' ');
                try p.tok(d.name);
                try p.w.writeByte('(');
                for (p.a.list(d.params), 0..) |q, k| {
                    if (k > 0) try p.w.writeAll(", ");
                    try p.param(@fromBackingInt(@intCast(q)));
                }
                try p.w.writeByte(')');
                if (d.body == .none) {
                    try p.w.writeAll(";\n");
                } else {
                    try p.w.writeByte(' ');
                    try p.block(d.body);
                    try p.w.writeByte('\n');
                }
            },
            .program => |d| {
                try p.w.writeAll(if (d.is_template) "program template " else "program ");
                try p.tok(d.name);
                if (d.parent != 0) {
                    try p.w.writeAll(" : ");
                    try p.tok(d.parent);
                }
                if (d.items.len == 0) {
                    try p.w.writeAll(";\n");
                    return;
                }
                try p.w.writeAll(" {\n");
                for (p.a.list(d.items)) |it| {
                    const pi = p.a.node(@fromBackingInt(@intCast(it))).data.program_item;
                    try p.w.writeAll("    ");
                    try p.w.writeAll(@tagName(pi.kind));
                    try p.w.writeByte(' ');
                    if (pi.kind == .spec) {
                        try p.tok(pi.name);
                        try p.w.writeAll(" = ");
                        try p.expr(pi.value, prec_assign);
                    } else try p.tok(pi.name);
                    try p.w.writeAll(";\n");
                }
                try p.w.writeAll("}\n");
            },
            .var_decl => {
                try p.varDecl(i);
                try p.w.writeAll(";\n");
            },
            else => {
                try p.stmt(i);
            },
        }
    }

    fn members(p: *Printer, r: Range) !void {
        try p.w.writeAll(" {\n");
        p.depth += 1;
        for (p.a.list(r)) |m| {
            try p.indent();
            try p.varDecl(@fromBackingInt(@intCast(m)));
            try p.w.writeAll(";\n");
        }
        p.depth -= 1;
        try p.indent();
        try p.w.writeAll("};\n");
    }

    fn typeName(p: *Printer, i: Index) !void {
        const d = p.a.node(i).data.type_name;
        try p.tok(d.name);
        if (d.array_len != .none) {
            try p.w.writeByte('[');
            try p.expr(d.array_len, prec_assign);
            try p.w.writeByte(']');
        }
    }

    fn param(p: *Printer, i: Index) !void {
        const d = p.a.node(i).data.param;
        if (d.is_const) try p.w.writeAll("const ");
        if (d.dir != .none) {
            try p.w.writeAll(@tagName(d.dir));
            try p.w.writeByte(' ');
        }
        try p.typeName(d.type);
        if (d.name != 0) {
            try p.w.writeByte(' ');
            try p.tok(d.name);
        }
        if (d.array_len != .none) {
            try p.w.writeByte('[');
            try p.expr(d.array_len, prec_assign);
            try p.w.writeByte(']');
        }
    }

    fn varDecl(p: *Printer, i: Index) std.Io.Writer.Error!void {
        const d = p.a.node(i).data.var_decl;
        if (d.location != .none) {
            try p.w.writeAll("layout(location = ");
            try p.expr(d.location, prec_assign);
            try p.w.writeAll(") ");
        }
        const q = d.quals;
        const words = [_]struct { bool, []const u8 }{
            .{ q.@"const", "const " },  .{ q.param, "param " }, .{ q.spec, "spec " },
            .{ q.uniform, "uniform " }, .{ q.flat, "flat " },   .{ q.in, "in " },
            .{ q.out, "out " },
        };
        for (words) |wd| if (wd[0]) try p.w.writeAll(wd[1]);
        try p.typeName(d.type);
        for (p.a.list(d.declarators), 0..) |di, k| {
            const dd = p.a.node(@fromBackingInt(@intCast(di))).data.declarator;
            try p.w.writeAll(if (k == 0) " " else ", ");
            try p.tok(dd.name);
            if (dd.array_len != .none) {
                try p.w.writeByte('[');
                try p.expr(dd.array_len, prec_assign);
                try p.w.writeByte(']');
            }
            if (dd.init != .none) {
                try p.w.writeAll(" = ");
                try p.expr(dd.init, prec_assign);
            }
        }
        if (d.meta.len > 0) {
            try p.w.writeAll(" { ");
            for (p.a.list(d.meta), 0..) |mi, k| {
                if (k > 0) try p.w.writeAll(", ");
                const m = p.a.node(@fromBackingInt(@intCast(mi))).data.meta_entry;
                try p.tok(m.key);
                if (m.has_parens) {
                    try p.w.writeByte('(');
                    try p.exprList(m.args);
                    try p.w.writeByte(')');
                }
            }
            try p.w.writeAll(" }");
        }
    }

    fn block(p: *Printer, i: Index) std.Io.Writer.Error!void {
        const d = p.a.node(i).data.block;
        try p.w.writeAll("{\n");
        p.depth += 1;
        for (p.a.list(d.stmts)) |s| try p.stmt(@fromBackingInt(@intCast(s)));
        p.depth -= 1;
        try p.indent();
        try p.w.writeByte('}');
    }

    /// A statement on its own lines, indented.
    fn stmt(p: *Printer, i: Index) std.Io.Writer.Error!void {
        try p.indent();
        try p.stmtInline(i);
        try p.w.writeByte('\n');
    }

    /// A statement starting where the cursor is, without the final newline.
    fn stmtInline(p: *Printer, i: Index) std.Io.Writer.Error!void {
        const n = p.a.node(i);
        switch (n.data) {
            .block => try p.block(i),
            .var_decl => {
                try p.varDecl(i);
                try p.w.writeByte(';');
            },
            .expr_stmt => |d| {
                try p.expr(d.expr, prec_assign);
                try p.w.writeByte(';');
            },
            .if_stmt => |d| {
                try p.w.writeAll("if (");
                try p.expr(d.cond, prec_assign);
                try p.w.writeAll(") ");
                try p.body(d.then, false);
                if (d.@"else" != .none) {
                    try p.w.writeAll(" else ");
                    try p.body(d.@"else", true);
                }
            },
            .for_stmt => |d| {
                try p.w.writeAll("for (");
                if (d.init != .none) {
                    const init = p.a.node(d.init);
                    if (init.data == .var_decl) try p.varDecl(d.init) else try p.expr(init.data.expr_stmt.expr, prec_assign);
                }
                try p.w.writeByte(';');
                if (d.cond != .none) {
                    try p.w.writeByte(' ');
                    try p.expr(d.cond, prec_assign);
                }
                try p.w.writeByte(';');
                if (d.step != .none) {
                    try p.w.writeByte(' ');
                    try p.expr(d.step, prec_assign);
                }
                try p.w.writeAll(") ");
                try p.body(d.body, false);
            },
            .return_stmt => |d| {
                try p.w.writeAll("return");
                if (d.value != .none) {
                    try p.w.writeByte(' ');
                    try p.expr(d.value, prec_assign);
                }
                try p.w.writeByte(';');
            },
            .break_stmt => try p.w.writeAll("break;"),
            .continue_stmt => try p.w.writeAll("continue;"),
            .discard_stmt => try p.w.writeAll("discard;"),
            .empty_stmt => try p.w.writeByte(';'),
            .invalid => try p.w.writeAll("/* invalid */;"),
            else => unreachable,
        }
    }

    /// The body of an `if`, `else` or `for`: blocks stay on the line, other statements
    /// are wrapped in braces so the canonical form has one shape (and no `else` can move
    /// to another `if`). Only an `else` keeps a bare `if`: `else if`.
    fn body(p: *Printer, i: Index, is_else: bool) std.Io.Writer.Error!void {
        if (p.a.node(i).data == .block) return p.block(i);
        if (is_else and p.a.node(i).data == .if_stmt) return p.stmtInline(i);
        try p.w.writeAll("{\n");
        p.depth += 1;
        try p.stmt(i);
        p.depth -= 1;
        try p.indent();
        try p.w.writeByte('}');
    }

    fn exprList(p: *Printer, r: Range) !void {
        for (p.a.list(r), 0..) |e, k| {
            if (k > 0) try p.w.writeAll(", ");
            try p.expr(@fromBackingInt(@intCast(e)), prec_assign);
        }
    }

    /// `min`: the weakest binding allowed here without parentheses.
    fn expr(p: *Printer, i: Index, min: u8) std.Io.Writer.Error!void {
        const n = p.a.node(i);
        const own: u8 = switch (n.data) {
            .assign => prec_assign,
            .ternary => prec_ternary,
            .binary => binaryPrecedence(p.a.tokens[n.tok].tag).? + 1,
            .prefix => prec_prefix,
            else => prec_postfix,
        };
        const paren = own < min or (p.all_parens and own < prec_postfix and min > prec_assign);
        if (paren) try p.w.writeByte('(');
        switch (n.data) {
            .literal, .ident => try p.tok(n.tok),
            .invalid => try p.w.writeAll("/* invalid */0"),
            .prefix => |d| {
                try p.tok(n.tok);
                // `- -a` and `+ +a` must not print as `--a` and `++a`
                const inner = p.a.node(d.operand);
                if (inner.data == .prefix) {
                    const it = p.a.tokens[inner.tok].tag;
                    const ot = p.a.tokens[n.tok].tag;
                    if ((ot == .minus and (it == .minus or it == .minus_minus)) or (ot == .plus and (it == .plus or it == .plus_plus))) try p.w.writeByte(' ');
                }
                try p.expr(d.operand, prec_prefix);
            },
            .postfix => |d| {
                try p.expr(d.operand, prec_postfix);
                try p.tok(n.tok);
            },
            .binary => |d| {
                // left-associative: the right side must bind tighter than this operator
                try p.expr(d.lhs, own);
                try p.w.writeByte(' ');
                try p.tok(n.tok);
                try p.w.writeByte(' ');
                try p.expr(d.rhs, own + 1);
            },
            .assign => |d| {
                try p.expr(d.lhs, prec_ternary + 1);
                try p.w.writeByte(' ');
                try p.tok(n.tok);
                try p.w.writeByte(' ');
                try p.expr(d.rhs, prec_assign);
            },
            .ternary => |d| {
                try p.expr(d.cond, prec_ternary + 1);
                try p.w.writeAll(" ? ");
                try p.expr(d.then, prec_assign);
                try p.w.writeAll(" : ");
                try p.expr(d.@"else", prec_assign);
            },
            .call => |d| {
                try p.expr(d.callee, prec_postfix);
                try p.w.writeByte('(');
                try p.exprList(d.args);
                try p.w.writeByte(')');
            },
            .index => |d| {
                try p.expr(d.base, prec_postfix);
                try p.w.writeByte('[');
                try p.expr(d.index, prec_assign);
                try p.w.writeByte(']');
            },
            .field => |d| {
                try p.expr(d.base, prec_postfix);
                try p.w.writeByte('.');
                try p.tok(n.tok);
            },
            else => unreachable,
        }
        if (paren) try p.w.writeByte(')');
    }
};
