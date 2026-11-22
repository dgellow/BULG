//! One stage of a program as GLSL ES 3.00 or GLSL 3.30: a complete text, header included,
//! with a line map back to the sources.
//!
//! - Specialisation: spec constants take the variant's values; an `if` or `?:` whose
//!   condition depends on spec constants alone keeps only the branch taken (what `#ifdef`
//!   did). Nothing else is folded, inlined or reordered inside a function, so a GL driver
//!   compiles what the source says.
//! - Only what `main` reaches is emitted. Declarations come in their modules' order (the
//!   imported first) and their order in the source, moved only as far as a dependency
//!   needs.
//! - Literals are printed as written; parentheses where precedence needs them; aliases
//!   where they are used.
//! - Two declarations of one name from different modules: the later in the text is
//!   renamed `name_N`.

const std = @import("std");
const Session = @import("../Session.zig");
const Source = @import("../Source.zig");
const Ast = @import("../syntax/Ast.zig");
const Ir = @import("../ir/Ir.zig");
const eval = @import("../ir/eval.zig");
const reach = @import("../ir/reach.zig");
const types = @import("../sema/types.zig");
const builtins = @import("../sema/builtins.zig");
const Type = types.Type;

pub const Dialect = enum { es300, glsl330 };

pub const header_es300 =
    \\#version 300 es
    \\precision highp float;
    \\precision highp int;
    \\precision highp sampler2D;
    \\
;
pub const header_330 =
    \\#version 330 core
    \\
;

/// Where an emitted line came from.
pub const LineEntry = struct {
    /// the first emitted line (1-based) this entry covers
    line: u32,
    src: Source.Id,
    /// 1-based line in that source
    src_line: u32,
};

pub const Emitted = struct {
    text: []u8,
    /// sorted by `line`; an emitted line maps to the last entry at or before it
    lines: []LineEntry,

    pub fn deinit(e: *Emitted, gpa: std.mem.Allocator) void {
        gpa.free(e.text);
        gpa.free(e.lines);
        e.* = undefined;
    }

    /// The source line an emitted line came from.
    pub fn lookup(e: *const Emitted, line: u32) ?LineEntry {
        var best: ?LineEntry = null;
        for (e.lines) |l| {
            if (l.line > line) break;
            best = l;
        }
        return best;
    }
};

pub const Error = error{
    OutOfMemory,
    /// the program did not link, or a module of the stage has errors
    NotChecked,
};

/// The text of `stage` of `prog`, in `out`'s memory. The program must have linked, with
/// no error in the stage's modules (`error.NotChecked` otherwise).
pub fn emit(s: *const Session, prog: *const Ir.Program, stage: Ir.Stage, dialect: Dialect, out: std.mem.Allocator) Error!Emitted {
    const info = (if (stage == .vertex) prog.vertex else prog.fragment) orelse return error.NotChecked;
    if (!s.stageChecked(prog, info)) return error.NotChecked;
    var arena_state: std.heap.ArenaAllocator = .init(out);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var e: Emitter = .{
        .s = s,
        .a = a,
        .info = info,
        .specs = .{ .values = prog.specs },
        .text = .init(out),
        .r = .{ .s = s, .a = a, .info = info, .specs = .{ .values = prog.specs } },
    };
    errdefer e.text.deinit();
    try e.run(dialect);
    const lines = try out.dupe(LineEntry, e.lines.items);
    errdefer out.free(lines);
    return .{ .text = try e.text.toOwnedSlice(), .lines = lines };
}

/// `driver_log` with every `0:LINE` (Mesa, ANGLE) and `0(LINE)` (NVIDIA, Apple) turned into
/// `path:line` of the source the emitted line came from.
pub fn mapLog(s: *const Session, emitted: *const Emitted, driver_log: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < driver_log.len) {
        const at_start = i == 0 or !std.ascii.isDigit(driver_log[i - 1]);
        if (at_start and driver_log[i] == '0' and i + 2 < driver_log.len and (driver_log[i + 1] == ':' or driver_log[i + 1] == '(') and std.ascii.isDigit(driver_log[i + 2])) {
            var j = i + 2;
            while (j < driver_log.len and std.ascii.isDigit(driver_log[j])) j += 1;
            const line = std.fmt.parseInt(u32, driver_log[i + 2 .. j], 10) catch 0;
            if (driver_log[i + 1] == '(' and j < driver_log.len and driver_log[j] == ')') j += 1;
            if (emitted.lookup(line)) |l| {
                try w.print("{s}:{d}", .{ s.source(l.src).path, l.src_line });
                i = j;
                continue;
            }
        }
        try w.writeByte(driver_log[i]);
        i += 1;
    }
}

const Decl = reach.Decl;

const Emitter = struct {
    s: *const Session,
    a: std.mem.Allocator,
    info: Ir.StageInfo,
    specs: eval.Specs,
    text: std.Io.Writer.Allocating,
    lines: std.ArrayList(LineEntry) = .empty,
    line: u32 = 1,
    depth: u32 = 0,
    half_as_float: bool = true,
    /// the function being printed (its locals and parameters)
    cur_fn: Ir.Function = undefined,

    /// what main reaches
    r: reach.Reach,
    /// the emitted name of each global, function and struct that was renamed
    renamed: std.AutoHashMapUnmanaged(Decl, []const u8) = .empty,

    fn mod(e: *Emitter, mi: u32) *const Ir.Module {
        return &e.s.modules[mi];
    }
    fn ast(e: *Emitter, mi: u32) *const Ast {
        return &e.s.asts.items[mi];
    }
    fn tokText(e: *Emitter, mi: u32, tok: u32) []const u8 {
        return e.ast(mi).tokenText(tok);
    }
    fn w(e: *Emitter) *std.Io.Writer {
        return &e.text.writer;
    }
    fn put(e: *Emitter, bytes: []const u8) Error!void {
        e.w().writeAll(bytes) catch return error.OutOfMemory;
    }
    fn print(e: *Emitter, comptime fmt: []const u8, values: anytype) Error!void {
        e.w().print(fmt, values) catch return error.OutOfMemory;
    }
    fn nl(e: *Emitter) Error!void {
        try e.put("\n");
        e.line += 1;
    }
    fn indent(e: *Emitter) Error!void {
        for (0..e.depth) |_| try e.put("  ");
    }
    /// The next emitted line comes from `tok` of module `mi`.
    fn mark(e: *Emitter, mi: u32, tok: u32) Error!void {
        const src_id = e.mod(mi).src;
        const at = e.s.source(src_id).locate(e.ast(mi).tokens[tok].start);
        const entry: LineEntry = .{ .line = e.line, .src = src_id, .src_line = at.line };
        if (e.lines.items.len > 0) {
            const last = &e.lines.items[e.lines.items.len - 1];
            // a later mark on the same emitted line is the one it is about
            if (last.line == e.line) {
                last.* = entry;
                return;
            }
            if (last.src == src_id and last.src_line == at.line) return;
        }
        try e.lines.append(e.a, entry);
    }

    fn run(e: *Emitter, dialect: Dialect) Error!void {
        const header = if (dialect == .es300) header_es300 else header_330;
        try e.put(header);
        e.line += @intCast(std.mem.count(u8, header, "\n"));

        try e.r.collect();
        const sorted = try e.r.order();
        // names are claimed in the order of the text: the first keeps its name
        try e.name(sorted);
        for (sorted) |d| try e.decl(d);
    }

    // ------------------------------------------------------------ names

    fn declName(e: *Emitter, d: Decl) []const u8 {
        if (e.renamed.get(d)) |n| return n;
        return e.baseName(d);
    }

    fn baseName(e: *Emitter, d: Decl) []const u8 {
        return switch (d) {
            .@"struct" => |x| e.s.pool.structOf(e.mod(x.module).structs[x.index]).?.name,
            .block => |x| e.mod(x.module).blocks[x.index].name,
            .global => |r| e.mod(r.module).globals[r.index].name,
            .function => |r| e.mod(r.module).functions[r.index].name,
        };
    }

    /// Renames the later of two declarations that would clash in one text. Functions of one
    /// name may share it when their parameters differ (they are overloads).
    fn name(e: *Emitter, sorted: []const Decl) Error!void {
        var taken: std.StringHashMapUnmanaged(std.ArrayList(Decl)) = .empty;
        for (sorted) |d| {
            // a block's members are names of their own
            if (d == .block) {
                for (e.mod(d.block.module).blocks[d.block.index].members) |mem| try e.claim(&taken, .{ .global = .{ .module = d.block.module, .index = mem } });
            }
            try e.claim(&taken, d);
        }
    }

    fn claim(e: *Emitter, taken: *std.StringHashMapUnmanaged(std.ArrayList(Decl)), d: Decl) Error!void {
        var n = e.baseName(d);
        var k: u32 = 2;
        while (true) {
            const gop = try taken.getOrPut(e.a, n);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                try gop.value_ptr.append(e.a, d);
                break;
            }
            const clash = for (gop.value_ptr.items) |other| {
                if (!e.overloads(other, d)) break true;
            } else false;
            if (!clash) {
                try gop.value_ptr.append(e.a, d);
                break;
            }
            n = try std.fmt.allocPrint(e.a, "{s}_{d}", .{ e.baseName(d), k });
            k += 1;
        }
        if (!std.mem.eql(u8, n, e.baseName(d))) try e.renamed.put(e.a, d, n);
    }

    fn overloads(e: *Emitter, a: Decl, b: Decl) bool {
        if (a != .function or b != .function) return false;
        const fa = e.mod(a.function.module).functions[a.function.index];
        const fb = e.mod(b.function.module).functions[b.function.index];
        if (fa.params.len != fb.params.len) return true;
        for (fa.params, fb.params) |p, q| if (p.type != q.type) return true;
        return false;
    }

    // ------------------------------------------------------------ declarations

    fn decl(e: *Emitter, d: Decl) Error!void {
        switch (d) {
            .@"struct" => |x| {
                const m = e.mod(x.module);
                const st = e.s.pool.structOf(m.structs[x.index]).?;
                try e.mark(x.module, m.struct_toks[x.index]);
                try e.print("struct {s} {{", .{e.declName(d)});
                try e.nl();
                for (st.fields) |f| {
                    try e.put("  ");
                    try e.declarator(f.type, f.name);
                    try e.put(";");
                    try e.nl();
                }
                try e.put("};");
                try e.nl();
            },
            .block => |x| {
                const m = e.mod(x.module);
                const b = m.blocks[x.index];
                try e.mark(x.module, b.tok);
                try e.print("layout(std140) uniform {s} {{", .{e.declName(d)});
                try e.nl();
                for (b.members) |mem| {
                    const g = m.globals[mem];
                    try e.mark(x.module, g.tok);
                    try e.put("  ");
                    try e.declarator(g.type, e.declName(.{ .global = .{ .module = x.module, .index = mem } }));
                    try e.put(";");
                    try e.nl();
                }
                try e.put("};");
                try e.nl();
            },
            .global => |r| {
                const g = e.mod(r.module).globals[r.index];
                try e.mark(r.module, g.tok);
                if (g.location) |loc| try e.print("layout(location={d}) ", .{loc});
                if (g.flat) try e.put("flat ");
                switch (g.kind) {
                    .uniform, .param => try e.put("uniform "),
                    .in => try e.put("in "),
                    .out => try e.put("out "),
                    .@"const", .spec => try e.put("const "),
                    .mutable => {},
                }
                try e.declarator(g.type, e.declName(d));
                if (g.kind == .spec) {
                    if (e.specs.get(r)) |v| {
                        try e.put(" = ");
                        try e.constant(v);
                    } else if (g.init != .none) {
                        try e.put(" = ");
                        try e.expr(r.module, g.init, 0);
                    }
                } else if (g.init != .none and (g.kind == .@"const" or g.kind == .mutable)) {
                    try e.put(" = ");
                    try e.expr(r.module, g.init, 0);
                }
                try e.put(";");
                try e.nl();
            },
            .function => |r| {
                const f = e.mod(r.module).functions[r.index];
                try e.mark(r.module, f.tok);
                try e.typeName(f.ret);
                try e.print(" {s}(", .{e.declName(d)});
                for (f.params, 0..) |p, k| {
                    if (k > 0) try e.put(", ");
                    if (p.is_const) try e.put("const ");
                    switch (p.dir) {
                        .in => {},
                        .out => try e.put("out "),
                        .inout => try e.put("inout "),
                    }
                    try e.declarator(p.type, if (p.name.len > 0) p.name else "");
                }
                try e.put(") ");
                e.cur_fn = f;
                try e.block(r.module, f.body);
                try e.nl();
            },
        }
    }

    /// `T name` (arrays as `T name[N]`).
    fn declarator(e: *Emitter, t: Type, n: []const u8) Error!void {
        if (e.s.pool.arrayOf(t)) |a| {
            try e.typeName(a.elem);
            if (n.len > 0) try e.print(" {s}", .{n});
            try e.print("[{d}]", .{a.len});
            return;
        }
        try e.typeName(t);
        if (n.len > 0) try e.print(" {s}", .{n});
    }

    fn typeName(e: *Emitter, t: Type) Error!void {
        const pool = &e.s.pool;
        if (pool.arrayOf(t)) |a| {
            try e.typeName(a.elem);
            return e.print("[{d}]", .{a.len});
        }
        if (pool.structOf(t) != null) return e.put(e.declName(e.r.structDecl(t).?));
        // half lowers to float on GL in v0
        const lowered: Type = if (e.half_as_float) switch (t) {
            .half => .float,
            .hvec2 => .vec2,
            .hvec3 => .vec3,
            .hvec4 => .vec4,
            .hmat2 => .mat2,
            .hmat3 => .mat3,
            .hmat4 => .mat4,
            else => t,
        } else t;
        try e.put(@tagName(lowered));
    }

    fn constant(e: *Emitter, v: Ir.Const) Error!void {
        switch (v) {
            .bool => |b| try e.put(if (b) "true" else "false"),
            .int => |i| try e.print("{d}", .{i}),
            .uint => |u| try e.print("{d}u", .{u}),
            .float => |f| {
                // the shortest text that reads back as the same float, with a point
                var buf: [64]u8 = undefined;
                const d = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
                try e.put(d);
                if (std.mem.indexOfAny(u8, d, ".eEn") == null) try e.put(".");
            },
        }
    }

    // ------------------------------------------------------------ statements

    fn block(e: *Emitter, mi: u32, sid: Ir.StmtId) Error!void {
        const st = e.mod(mi).stmt(sid);
        try e.put("{");
        try e.nl();
        e.depth += 1;
        switch (st.data) {
            .block => |l| for (e.mod(mi).list(l)) |x| try e.stmt(mi, @fromBackingInt(@intCast(x))),
            else => try e.stmt(mi, sid),
        }
        e.depth -= 1;
        try e.indent();
        try e.put("}");
    }

    fn stmt(e: *Emitter, mi: u32, sid: Ir.StmtId) Error!void {
        const st = e.mod(mi).stmt(sid);
        switch (st.data) {
            .block => |l| {
                // an empty statement (or an empty scope) says nothing
                if (l.len == 0) return;
                try e.mark(mi, st.tok);
                try e.indent();
                try e.block(mi, sid);
                try e.nl();
            },
            .@"if" => |d| {
                if (e.r.folded(mi, d.cond)) |taken| {
                    const branch = if (taken) d.then else d.@"else";
                    if (branch == .none) return;
                    // an `else if` needs no scope of its own: its branches have theirs
                    if (e.mod(mi).stmt(branch).data == .@"if") return e.stmt(mi, branch);
                    // keep the branch's scope
                    try e.mark(mi, st.tok);
                    try e.indent();
                    try e.block(mi, branch);
                    try e.nl();
                    return;
                }
                try e.mark(mi, st.tok);
                try e.indent();
                try e.ifChain(mi, sid);
                try e.nl();
            },
            .@"for" => |d| {
                try e.mark(mi, st.tok);
                try e.indent();
                try e.put("for (");
                if (d.init != .none) try e.simple(mi, d.init);
                try e.put(";");
                if (d.cond != .none) {
                    try e.put(" ");
                    try e.expr(mi, d.cond, 0);
                }
                try e.put(";");
                if (d.step != .none) {
                    try e.put(" ");
                    try e.expr(mi, d.step, 0);
                }
                try e.put(") ");
                try e.block(mi, d.body);
                try e.nl();
            },
            else => {
                try e.mark(mi, st.tok);
                try e.indent();
                try e.simple(mi, sid);
                try e.put(";");
                try e.nl();
            },
        }
    }

    fn ifChain(e: *Emitter, mi: u32, sid: Ir.StmtId) Error!void {
        const d = e.mod(mi).stmt(sid).data.@"if";
        try e.put("if (");
        try e.expr(mi, d.cond, 0);
        try e.put(") ");
        try e.block(mi, d.then);
        if (d.@"else" == .none) return;
        const els = e.mod(mi).stmt(d.@"else");
        if (els.data == .@"if" and e.r.folded(mi, els.data.@"if".cond) == null) {
            try e.put(" else ");
            return e.ifChain(mi, d.@"else");
        }
        if (els.data == .@"if") {
            const taken = e.r.folded(mi, els.data.@"if".cond).?;
            const branch = if (taken) els.data.@"if".then else els.data.@"if".@"else";
            if (branch == .none) return;
            try e.put(" else ");
            return e.block(mi, branch);
        }
        try e.put(" else ");
        try e.block(mi, d.@"else");
    }

    /// A statement without its `;`: a declaration (one name), an expression, a jump.
    fn simple(e: *Emitter, mi: u32, sid: Ir.StmtId) Error!void {
        const st = e.mod(mi).stmt(sid);
        switch (st.data) {
            .local => |d| {
                const l = e.cur_fn.locals[d.local];
                if (l.is_const) try e.put("const ");
                try e.declarator(l.type, l.name);
                if (d.init != .none) {
                    try e.put(" = ");
                    try e.expr(mi, d.init, 0);
                }
            },
            .expr => |x| try e.expr(mi, x, 0),
            .@"return" => |x| {
                try e.put("return");
                if (x != .none) {
                    try e.put(" ");
                    try e.expr(mi, x, 0);
                }
            },
            .@"break" => try e.put("break"),
            .@"continue" => try e.put("continue"),
            .discard => try e.put("discard"),
            .block => |l| {
                // a for's init that declares several names
                for (e.mod(mi).list(l), 0..) |x, k| {
                    const ls = e.mod(mi).stmt(@fromBackingInt(@intCast(x))).data.local;
                    const loc = e.cur_fn.locals[ls.local];
                    if (k == 0) {
                        if (loc.is_const) try e.put("const ");
                        try e.typeName(if (e.s.pool.arrayOf(loc.type)) |a| a.elem else loc.type);
                        try e.put(" ");
                    } else try e.put(", ");
                    try e.put(loc.name);
                    if (e.s.pool.arrayOf(loc.type)) |a| try e.print("[{d}]", .{a.len});
                    if (ls.init != .none) {
                        try e.put(" = ");
                        try e.expr(mi, ls.init, 0);
                    }
                }
            },
            else => unreachable,
        }
    }

    // ------------------------------------------------------------ expressions

    const prec_assign = 0;
    const prec_ternary = 1;
    const prec_prefix = 13;
    const prec_postfix = 14;

    fn binaryPrec(op: Ir.BinaryOp) u8 {
        return switch (op) {
            .log_or => 2,
            .log_xor => 3,
            .log_and => 4,
            .bit_or => 5,
            .bit_xor => 6,
            .bit_and => 7,
            .eq, .ne => 8,
            .lt, .gt, .le, .ge => 9,
            .shl, .shr => 10,
            .add, .sub => 11,
            .mul, .div, .rem => 12,
        };
    }

    fn binaryText(op: Ir.BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
            .shl => "<<",
            .shr => ">>",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .log_and => "&&",
            .log_or => "||",
            .log_xor => "^^",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
        };
    }

    fn assignText(op: Ir.AssignOp) []const u8 {
        return switch (op) {
            .set => "=",
            .add => "+=",
            .sub => "-=",
            .mul => "*=",
            .div => "/=",
            .rem => "%=",
            .shl => "<<=",
            .shr => ">>=",
            .bit_and => "&=",
            .bit_or => "|=",
            .bit_xor => "^=",
        };
    }

    /// How tightly `x` binds, as printed (aliases print their expression).
    fn precOf(e: *Emitter, mi: u32, x: Ir.ExprId) u8 {
        const ex = e.mod(mi).expr(x);
        return switch (ex.data) {
            .assign => prec_assign,
            .ternary => |d| if (e.r.folded(mi, d.cond)) |taken| e.precOf(mi, if (taken) d.then else d.@"else") else prec_ternary,
            .binary => |d| binaryPrec(d.op),
            .unary => |d| switch (d.op) {
                .post_inc, .post_dec => prec_postfix,
                else => prec_prefix,
            },
            .alias => |r| e.precOf(r.module, e.mod(r.module).aliases[r.index].value),
            .literal => |v| switch (v) {
                // a negative constant printed for a spec value is a prefix expression
                .int => |i| if (i < 0) prec_prefix else prec_postfix,
                .float => |f| if (f < 0 or std.math.signbit(f)) prec_prefix else prec_postfix,
                else => prec_postfix,
            },
            else => prec_postfix,
        };
    }

    /// `x`, in parentheses if it binds less tightly than `min`.
    fn expr(e: *Emitter, mi: u32, x: Ir.ExprId, min: u8) Error!void {
        const m = e.mod(mi);
        const ex = m.expr(x);
        const own = e.precOf(mi, x);
        const paren = own < min;
        if (paren) try e.put("(");
        defer if (paren) e.put(")") catch {};
        switch (ex.data) {
            .literal, .string => try e.put(e.tokText(mi, ex.tok)),
            .local => |l| try e.put(e.cur_fn.locals[l].name),
            .param => |p| try e.put(e.cur_fn.params[p].name),
            .builtin_var => |v| try e.put(builtins.variables[v].name),
            .global => |r| try e.put(e.declName(.{ .global = r })),
            .alias => |r| try e.expr(r.module, e.mod(r.module).aliases[r.index].value, min),
            .call => |d| {
                try e.put(e.declName(.{ .function = e.r.fill(d.callee) }));
                try e.args(mi, d.args);
            },
            .builtin_call => |d| {
                try e.put(builtins.functions[d.func].name);
                try e.args(mi, d.args);
            },
            .construct => |l| {
                try e.typeName(ex.type);
                try e.args(mi, l);
            },
            .unary => |d| switch (d.op) {
                .post_inc, .post_dec => {
                    try e.expr(mi, d.operand, prec_postfix);
                    try e.put(if (d.op == .post_inc) "++" else "--");
                },
                else => {
                    const t: []const u8 = switch (d.op) {
                        .neg => "-",
                        .plus => "+",
                        .not => "!",
                        .bit_not => "~",
                        .pre_inc => "++",
                        .pre_dec => "--",
                        else => unreachable,
                    };
                    try e.put(t);
                    // `- -a`, `- --a`: not `--a`
                    const inner = e.mod(mi).expr(d.operand);
                    if ((d.op == .neg or d.op == .plus) and inner.data == .unary and e.precOf(mi, d.operand) == prec_prefix) try e.put(" ");
                    if ((d.op == .neg or d.op == .plus) and inner.data == .literal and e.precOf(mi, d.operand) == prec_prefix) try e.put(" ");
                    try e.expr(mi, d.operand, prec_prefix);
                },
            },
            .binary => |d| {
                const p = binaryPrec(d.op);
                try e.expr(mi, d.lhs, p);
                try e.print(" {s} ", .{binaryText(d.op)});
                try e.expr(mi, d.rhs, p + 1);
            },
            .assign => |d| {
                try e.expr(mi, d.lhs, prec_ternary + 1);
                try e.print(" {s} ", .{assignText(d.op)});
                try e.expr(mi, d.rhs, prec_assign);
            },
            .ternary => |d| {
                if (e.r.folded(mi, d.cond)) |taken| return e.expr(mi, if (taken) d.then else d.@"else", min);
                try e.expr(mi, d.cond, prec_ternary + 1);
                try e.put(" ? ");
                try e.expr(mi, d.then, prec_assign);
                try e.put(" : ");
                try e.expr(mi, d.@"else", prec_assign);
            },
            .index => |d| {
                try e.expr(mi, d.base, prec_postfix);
                try e.put("[");
                try e.expr(mi, d.index, 0);
                try e.put("]");
            },
            .swizzle => |d| {
                try e.expr(mi, d.base, prec_postfix);
                try e.print(".{s}", .{e.tokText(mi, ex.tok)});
            },
            .field => |d| {
                try e.expr(mi, d.base, prec_postfix);
                try e.print(".{s}", .{e.tokText(mi, ex.tok)});
            },
            .array_length => |d| {
                try e.expr(mi, d.base, prec_postfix);
                try e.put(".length()");
            },
        }
    }

    fn args(e: *Emitter, mi: u32, l: Ir.List) Error!void {
        try e.put("(");
        for (e.mod(mi).list(l), 0..) |a, k| {
            if (k > 0) try e.put(", ");
            try e.expr(mi, @fromBackingInt(@intCast(a)), 0);
        }
        try e.put(")");
    }
};
