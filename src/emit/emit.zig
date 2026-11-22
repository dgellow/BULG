//! One stage of a program as GLSL ES 3.00, GLSL 3.30 or MSL: a complete text, header
//! included, with a line map back to the sources. One printer writes all three; MSL's
//! differences are in `msl.zig` and in the branches marked for it here.
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
const msl = @import("msl.zig");

pub const Dialect = enum {
    es300,
    glsl330,
    msl,

    /// The file extension of a stage's text.
    pub fn extension(d: Dialect, stage: Ir.Stage) []const u8 {
        return switch (d) {
            .msl => if (stage == .vertex) "vert.metal" else "frag.metal",
            else => if (stage == .vertex) "vert" else "frag",
        };
    }
};

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
    /// the dialect cannot say what the program says (yet): `emitWhy` says what
    Unsupported,
};

/// The text of `stage` of `prog`, in `out`'s memory. The program must have linked, with
/// no error in the stage's modules (`error.NotChecked` otherwise).
pub fn emit(s: *const Session, prog: *const Ir.Program, stage: Ir.Stage, dialect: Dialect, out: std.mem.Allocator) Error!Emitted {
    return emitWhy(s, prog, stage, dialect, out, null);
}

/// `emit`, and on `error.Unsupported` what it was, in `why`.
pub fn emitWhy(s: *const Session, prog: *const Ir.Program, stage: Ir.Stage, dialect: Dialect, out: std.mem.Allocator, why: ?*[]const u8) Error!Emitted {
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
        .dialect = dialect,
        .stage = stage,
    };
    errdefer e.text.deinit();
    e.run() catch |err| {
        if (err == error.Unsupported) if (why) |p| {
            p.* = e.why;
        };
        return err;
    };
    const lines = try out.dupe(LineEntry, e.lines.items);
    errdefer out.free(lines);
    return .{ .text = try e.text.toOwnedSlice(), .lines = lines };
}

/// `driver_log` with every `0:LINE` (Mesa, ANGLE), `0(LINE)` (NVIDIA, Apple's GL) and
/// `program_source:LINE` (Metal) turned into `path:line` of the source the emitted line
/// came from.
pub fn mapLog(s: *const Session, emitted: *const Emitted, driver_log: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const metal = "program_source:";
    var i: usize = 0;
    while (i < driver_log.len) {
        if (std.mem.startsWith(u8, driver_log[i..], metal) and i + metal.len < driver_log.len and std.ascii.isDigit(driver_log[i + metal.len])) {
            var j = i + metal.len;
            while (j < driver_log.len and std.ascii.isDigit(driver_log[j])) j += 1;
            const line = std.fmt.parseInt(u32, driver_log[i + metal.len .. j], 10) catch 0;
            if (emitted.lookup(line)) |l| {
                try w.print("{s}:{d}", .{ s.source(l.src).path, l.src_line });
                i = j;
                continue;
            }
        }
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
    dialect: Dialect,
    stage: Ir.Stage,
    /// what `error.Unsupported` was about
    why: []const u8 = "",
    /// MSL: the pieces of the prelude the text uses
    helpers: std.EnumSet(msl.Helper) = .empty,

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

    fn run(e: *Emitter) Error!void {
        if (e.dialect == .msl) return e.runMsl();
        const header = if (e.dialect == .es300) header_es300 else header_330;
        try e.put(header);
        e.line += @intCast(std.mem.count(u8, header, "\n"));

        try e.r.collect();
        const sorted = try e.r.order();
        // names are claimed in the order of the text: the first keeps its name
        try e.name(sorted);
        for (sorted) |d| try e.decl(d);
    }

    fn isMsl(e: *const Emitter) bool {
        return e.dialect == .msl;
    }

    fn unsupported(e: *Emitter, what: []const u8) Error {
        e.why = what;
        return error.Unsupported;
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
        if (e.isMsl() and msl.reserved(n)) n = try std.fmt.allocPrint(e.a, "bulg_{s}", .{n});
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
            n = try std.fmt.allocPrint(e.a, "{s}_{d}", .{ if (e.isMsl() and msl.reserved(e.baseName(d))) try std.fmt.allocPrint(e.a, "bulg_{s}", .{e.baseName(d)}) else e.baseName(d), k });
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
                    try e.declarator(f.type, try e.ident(f.name));
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
                try e.indent();
                try e.typeName(f.ret);
                try e.print(" {s}(", .{e.declName(d)});
                for (f.params, 0..) |p, k| {
                    if (k > 0) try e.put(", ");
                    const pname = if (p.name.len > 0) try e.ident(p.name) else "";
                    if (e.isMsl() and p.dir != .in) {
                        // an out or inout parameter is a reference to the caller's variable
                        try e.put("thread ");
                        try e.typeName(p.type);
                        try e.put("&");
                        if (pname.len > 0) try e.print(" {s}", .{pname});
                        continue;
                    }
                    if (p.is_const) try e.put("const ");
                    switch (p.dir) {
                        .in => {},
                        .out => try e.put("out "),
                        .inout => try e.put("inout "),
                    }
                    try e.declarator(p.type, pname);
                }
                try e.put(") ");
                e.cur_fn = f;
                try e.block(r.module, f.body);
                try e.nl();
            },
        }
    }

    /// A local's, parameter's or field's name as printed: MSL keeps some names (`msl.reserved`).
    fn ident(e: *Emitter, n: []const u8) Error![]const u8 {
        if (e.isMsl() and n.len > 0 and msl.reserved(n)) return std.fmt.allocPrint(e.a, "bulg_{s}", .{n}) catch error.OutOfMemory;
        return n;
    }

    /// `T name` (arrays as `T name[N]`; in MSL `array<T, N> name`).
    fn declarator(e: *Emitter, t: Type, n: []const u8) Error!void {
        if (e.isMsl()) {
            try e.typeName(t);
            if (n.len > 0) try e.print(" {s}", .{n});
            return;
        }
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
        if (e.isMsl()) {
            if (pool.arrayOf(t)) |a| {
                try e.put("array<");
                try e.typeName(a.elem);
                return e.print(", {d}>", .{a.len});
            }
            if (pool.structOf(t) != null) return e.put(e.declName(e.r.structDecl(t).?));
            if (t == .sampler2D) e.helpers.insert(.sampler);
            return e.put(msl.typeName(t));
        }
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
                if (e.isMsl()) try e.put("f");
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
                try e.declarator(l.type, try e.ident(l.name));
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
            .discard => try e.put(if (e.isMsl()) "discard_fragment()" else "discard"),
            .block => |l| {
                // a for's init that declares several names
                if (e.isMsl()) for (e.mod(mi).list(l)) |x| {
                    const ls = e.mod(mi).stmt(@fromBackingInt(@intCast(x))).data.local;
                    if (e.s.pool.arrayOf(e.cur_fn.locals[ls.local].type) != null) return e.unsupported("an array among several names declared at once");
                };
                for (e.mod(mi).list(l), 0..) |x, k| {
                    const ls = e.mod(mi).stmt(@fromBackingInt(@intCast(x))).data.local;
                    const loc = e.cur_fn.locals[ls.local];
                    if (k == 0) {
                        if (loc.is_const) try e.put("const ");
                        try e.typeName(if (e.s.pool.arrayOf(loc.type)) |a| a.elem else loc.type);
                        try e.put(" ");
                    } else try e.put(", ");
                    try e.put(try e.ident(loc.name));
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
            .literal, .string => {
                const t = e.tokText(mi, ex.tok);
                try e.put(t);
                // C++ reads an unsuffixed literal as a double: Metal's are floats
                if (e.isMsl() and ex.data == .literal and ex.data.literal == .float and !std.mem.endsWith(u8, t, "f") and !std.mem.endsWith(u8, t, "F")) try e.put("f");
            },
            .local => |l| try e.put(try e.ident(e.cur_fn.locals[l].name)),
            .param => |p| try e.put(try e.ident(e.cur_fn.params[p].name)),
            .builtin_var => |v| try e.put(builtins.variables[v].name),
            .global => |r| {
                if (e.isMsl()) {
                    const g = e.mod(r.module).globals[r.index];
                    // a block's members are read through the block, loose uniforms through
                    // the stage's parameter buffer
                    if (g.block) |bi| {
                        try e.print("bulg_{s}->", .{e.declName(.{ .block = .{ .module = r.module, .index = bi } })});
                    } else if ((g.kind == .uniform or g.kind == .param) and g.type != .sampler2D) {
                        try e.put("bulg_params->");
                    }
                }
                try e.put(e.declName(.{ .global = r }));
            },
            .alias => |r| try e.expr(r.module, e.mod(r.module).aliases[r.index].value, min),
            .call => |d| {
                try e.put(e.declName(.{ .function = e.r.fill(d.callee) }));
                try e.args(mi, d.args);
            },
            .builtin_call => |d| {
                if (e.isMsl()) return e.mslCall(mi, ex, d.func, d.args);
                try e.put(builtins.functions[d.func].name);
                try e.args(mi, d.args);
            },
            .construct => |l| {
                if (e.isMsl()) return e.mslConstruct(mi, ex.type, l);
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
                // C++ has no `^^`: on two bools it is `!=`
                try e.print(" {s} ", .{if (e.isMsl() and d.op == .log_xor) "!=" else binaryText(d.op)});
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
                if (e.isMsl()) {
                    // Metal has xyzw and rgba, not stpq: the components, as xyzw
                    try e.put(".");
                    for (d.comps[0..d.len]) |c| try e.put(&.{"xyzw"[c]});
                } else try e.print(".{s}", .{e.tokText(mi, ex.tok)});
            },
            .field => |d| {
                try e.expr(mi, d.base, prec_postfix);
                try e.print(".{s}", .{try e.ident(e.tokText(mi, ex.tok))});
            },
            .array_length => |d| {
                if (e.isMsl()) return e.print("{d}", .{d.len});
                try e.expr(mi, d.base, prec_postfix);
                try e.put(".length()");
            },
        }
    }

    // ------------------------------------------------------------ MSL: the stage

    /// MSL: the header and the prelude it uses, the program-scope declarations (structs,
    /// blocks, constants, the stage's parameter struct), then the stage as one struct (its
    /// globals, uniforms and built-in variables as members, its functions as member
    /// functions, unchanged), then the entry point, which fills the struct, calls `main`
    /// and hands the outputs on. Metal has no mutable program-scope variables and its
    /// functions see only what they are given: the struct is how the text keeps GLSL's
    /// globals and calls as written.
    fn runMsl(e: *Emitter) Error!void {
        try e.r.collect();
        const sorted = try e.r.order();
        try e.name(sorted);

        var blocks: std.ArrayList(Decl) = .empty;
        var params: std.ArrayList(Ir.Ref) = .empty;
        var samplers: std.ArrayList(Ir.Ref) = .empty;
        var ins: std.ArrayList(Ir.Ref) = .empty;
        var outs: std.ArrayList(Ir.Ref) = .empty;
        for (sorted) |d| switch (d) {
            .block => try blocks.append(e.a, d),
            .global => |r| {
                const g = e.mod(r.module).globals[r.index];
                switch (g.kind) {
                    .uniform, .param => if (g.block == null) {
                        if (g.type == .sampler2D) try samplers.append(e.a, r) else try params.append(e.a, r);
                    },
                    .in => try ins.append(e.a, r),
                    .out => try outs.append(e.a, r),
                    else => {},
                }
            },
            else => {},
        };
        if (samplers.items.len > 0) e.helpers.insert(.sampler);

        // program scope
        for (sorted) |d| switch (d) {
            .@"struct" => try e.decl(d),
            .block => try e.mslBlock(d.block.module, d.block.index),
            .global => |r| if (try e.atProgramScope(r)) try e.mslGlobal(r, true),
            .function => {},
        };
        if (params.items.len > 0) {
            try e.put("struct bulg_Params {");
            try e.nl();
            for (params.items) |r| {
                const g = e.mod(r.module).globals[r.index];
                try e.mark(r.module, g.tok);
                try e.put("  ");
                try e.declarator(g.type, e.declName(.{ .global = r }));
                try e.put(";");
                try e.nl();
            }
            try e.put("};");
            try e.nl();
        }

        // the stage
        try e.put("struct bulg_Stage {");
        try e.nl();
        e.depth = 1;
        for (blocks.items) |d| {
            const n = e.declName(d);
            try e.print("  constant {s}* bulg_{s};", .{ n, n });
            try e.nl();
        }
        if (params.items.len > 0) {
            try e.put("  constant bulg_Params* bulg_params;");
            try e.nl();
        }
        const uses = e.info.uses;
        if (e.stage == .vertex) {
            try e.put("  float4 gl_Position;");
            try e.nl();
            if (uses.point_size) try e.line_("  float gl_PointSize;");
            if (uses.vertex_id) try e.line_("  int gl_VertexID;");
            if (uses.instance_id) try e.line_("  int gl_InstanceID;");
        } else {
            if (uses.frag_coord) try e.line_("  float4 gl_FragCoord;");
            if (uses.front_facing) try e.line_("  bool gl_FrontFacing;");
            if (uses.point_coord) try e.line_("  float2 gl_PointCoord;");
        }
        for (sorted) |d| switch (d) {
            .global => |r| {
                const g = e.mod(r.module).globals[r.index];
                if (g.block != null) continue;
                if ((g.kind == .uniform or g.kind == .param) and g.type != .sampler2D) continue;
                if (try e.atProgramScope(r)) continue;
                try e.mslGlobal(r, false);
            },
            .function => try e.decl(d),
            else => {},
        };
        e.depth = 0;
        try e.put("};");
        try e.nl();

        try e.mslEntry(blocks.items, params.items.len > 0, samplers.items, ins.items, outs.items);

        // the header and the prelude go before what was printed, which moves every line
        const body = e.text.toOwnedSlice() catch return error.OutOfMemory;
        defer e.text.allocator.free(body);
        var pre: std.ArrayList(u8) = .empty;
        try pre.appendSlice(e.a, msl.header);
        var it = e.helpers.iterator();
        while (it.next()) |h| try pre.appendSlice(e.a, if (h == .sampler and e.stage == .vertex) msl.sampler_vertex else msl.helperText(h));
        const shift: u32 = @intCast(std.mem.count(u8, pre.items, "\n"));
        for (e.lines.items) |*l| l.line += shift;
        try e.put(pre.items);
        try e.put(body);
    }

    /// One line of the emitter's own (no source line).
    fn line_(e: *Emitter, text: []const u8) Error!void {
        try e.put(text);
        try e.nl();
    }

    /// Can a constant be declared at program scope (`constant`)? When its value is made of
    /// literals, constructors, operators and other such constants: Metal evaluates those
    /// while compiling. One that calls a function is a member of the stage instead.
    fn atProgramScope(e: *Emitter, r: Ir.Ref) Error!bool {
        const g = e.mod(r.module).globals[r.index];
        switch (g.kind) {
            .spec => if (e.specs.get(r) != null) return true,
            .@"const" => {},
            else => return false,
        }
        if (g.init == .none) return false;
        return e.constantExpr(r.module, g.init);
    }

    fn constantExpr(e: *Emitter, mi: u32, x: Ir.ExprId) Error!bool {
        if (x == .none) return true;
        const m = e.mod(mi);
        const ex = m.expr(x);
        return switch (ex.data) {
            .literal => true,
            .construct => |l| {
                for (m.list(l)) |a| if (!try e.constantExpr(mi, @fromBackingInt(@intCast(a)))) return false;
                return true;
            },
            .unary => |d| (d.op == .neg or d.op == .plus or d.op == .not or d.op == .bit_not) and try e.constantExpr(mi, d.operand),
            .binary => |d| try e.constantExpr(mi, d.lhs) and try e.constantExpr(mi, d.rhs),
            .ternary => |d| try e.constantExpr(mi, d.cond) and try e.constantExpr(mi, d.then) and try e.constantExpr(mi, d.@"else"),
            .swizzle => |d| try e.constantExpr(mi, d.base),
            .index => |d| try e.constantExpr(mi, d.base) and try e.constantExpr(mi, d.index),
            .field => |d| try e.constantExpr(mi, d.base),
            .alias => |r| try e.constantExpr(r.module, e.mod(r.module).aliases[r.index].value),
            .global => |r| try e.atProgramScope(r),
            else => false,
        };
    }

    /// A global: at program scope a `constant`; in the stage a member (with its
    /// initializer, `const` for a constant).
    fn mslGlobal(e: *Emitter, r: Ir.Ref, program_scope: bool) Error!void {
        const g = e.mod(r.module).globals[r.index];
        try e.mark(r.module, g.tok);
        try e.indent();
        const is_const = g.kind == .@"const" or g.kind == .spec;
        if (program_scope) try e.put("constant ") else if (is_const) try e.put("const ");
        try e.declarator(g.type, e.declName(.{ .global = r }));
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
    }

    /// A uniform block as a struct with std140's offsets. Metal's own layout agrees for
    /// what Kykeon's blocks hold (vec4s, then scalars); padding is added where std140 puts
    /// a member later, a vec3 followed by a scalar is a packed_float3, and anything that
    /// cannot be made to agree is refused rather than laid out wrong.
    fn mslBlock(e: *Emitter, mi: u32, bi: u32) Error!void {
        const m = e.mod(mi);
        const b = m.blocks[bi];
        try e.mark(mi, b.tok);
        try e.print("struct {s} {{", .{e.declName(.{ .block = .{ .module = mi, .index = bi } })});
        try e.nl();
        var off: u32 = 0;
        var pads: u32 = 0;
        for (b.members, b.offsets, 0..) |mem, want, k| {
            const g = m.globals[mem];
            const next = if (k + 1 < b.offsets.len) b.offsets[k + 1] else b.size;
            var t = g.type;
            var count: u32 = 1;
            if (e.s.pool.arrayOf(t)) |a| {
                t = a.elem;
                count = a.len;
            }
            if (!t.isBuiltin()) return e.unsupported("a struct in a uniform block");
            if (t.scalarOf() == .bool) return e.unsupported("a bool in a uniform block");
            if (t == .mat2 or t == .hmat2) return e.unsupported("a mat2 in a uniform block");
            const l = msl.layout(t);
            const packed3 = count == 1 and t.vectorLen() == 3 and next - want == 12;
            const alignment: u32 = if (packed3) 4 else l.alignment;
            if (count > 1 and l.size % 16 != 0) return e.unsupported("an array of less than 16-byte elements in a uniform block");
            if (msl.alignUp(off, alignment) > want) return e.unsupported("a uniform block whose std140 layout Metal cannot match");
            if (off < want) {
                try e.print("  char bulg_pad{d}[{d}];", .{ pads, want - off });
                try e.nl();
                pads += 1;
            }
            try e.mark(mi, g.tok);
            try e.put("  ");
            const member = e.declName(.{ .global = .{ .module = mi, .index = mem } });
            if (packed3) {
                try e.print("packed_{s} {s};", .{ msl.typeName(t), member });
            } else try e.declarator(g.type, member);
            if (!packed3) try e.put(";");
            try e.nl();
            off = want + (if (packed3) 12 else l.size * count);
        }
        if (off < b.size) {
            try e.print("  char bulg_pad{d}[{d}];", .{ pads, b.size - off });
            try e.nl();
        }
        try e.put("};");
        try e.nl();
    }

    /// The entry point: `bulg_main`, with the stage's inputs, outputs and resources.
    /// Buffers: the blocks from 0 in the order of the text, then the parameter struct.
    /// Textures and samplers: from 0 in the order of the text. Vertex attributes: their
    /// location (or their place among the inputs). Varyings match by name.
    fn mslEntry(e: *Emitter, blocks: []const Decl, has_params: bool, samplers: []const Ir.Ref, ins: []const Ir.Ref, outs: []const Ir.Ref) Error!void {
        const vertex = e.stage == .vertex;
        const uses = e.info.uses;
        const in_name = if (vertex) "bulg_VertexIn" else "bulg_FragmentIn";
        const out_name = if (vertex) "bulg_VertexOut" else "bulg_FragmentOut";
        if (ins.len > 0) {
            try e.print("struct {s} {{", .{in_name});
            try e.nl();
            for (ins, 0..) |r, k| {
                const g = e.mod(r.module).globals[r.index];
                const n = e.declName(.{ .global = r });
                try e.put("  ");
                try e.declarator(g.type, n);
                if (vertex) {
                    try e.print(" [[attribute({d})]];", .{g.location orelse @as(u32, @intCast(k))});
                } else {
                    try e.print(" [[user({s}){s}]];", .{ n, if (g.flat) ", flat" else "" });
                }
                try e.nl();
            }
            try e.put("};");
            try e.nl();
        }
        const has_out = vertex or outs.len > 0;
        if (has_out) {
            try e.print("struct {s} {{", .{out_name});
            try e.nl();
            if (vertex) {
                try e.line_("  float4 gl_Position [[position]];");
                if (uses.point_size) try e.line_("  float gl_PointSize [[point_size]];");
            }
            for (outs, 0..) |r, k| {
                const g = e.mod(r.module).globals[r.index];
                const n = e.declName(.{ .global = r });
                try e.put("  ");
                try e.declarator(g.type, n);
                if (vertex) try e.print(" [[user({s})]];", .{n}) else try e.print(" [[color({d})]];", .{g.location orelse @as(u32, @intCast(k))});
                try e.nl();
            }
            try e.put("};");
            try e.nl();
        }
        // the signature, one argument to a line
        try e.print("{s} {s} bulg_main(", .{ if (vertex) "vertex" else "fragment", if (has_out) out_name else "void" });
        var first = true;
        const Arg = struct {
            fn sep(em: *Emitter, f: *bool) Error!void {
                if (!f.*) try em.put(",");
                f.* = false;
                try em.nl();
                try em.put("    ");
            }
        };
        if (ins.len > 0) {
            try Arg.sep(e, &first);
            try e.print("{s} bulg_in [[stage_in]]", .{in_name});
        }
        if (vertex) {
            if (uses.vertex_id) {
                try Arg.sep(e, &first);
                try e.put("uint bulg_vertex_id [[vertex_id]]");
            }
            if (uses.instance_id) {
                try Arg.sep(e, &first);
                try e.put("uint bulg_instance_id [[instance_id]]");
            }
        } else {
            if (uses.frag_coord) {
                try Arg.sep(e, &first);
                try e.put("float4 bulg_frag_coord [[position]]");
            }
            if (uses.front_facing) {
                try Arg.sep(e, &first);
                try e.put("bool bulg_front_facing [[front_facing]]");
            }
            if (uses.point_coord) {
                try Arg.sep(e, &first);
                try e.put("float2 bulg_point_coord [[point_coord]]");
            }
        }
        var buffer: u32 = 0;
        for (blocks) |d| {
            try Arg.sep(e, &first);
            const n = e.declName(d);
            try e.print("constant {s}& bulg_{s}_buffer [[buffer({d})]]", .{ n, n, buffer });
            buffer += 1;
        }
        if (has_params) {
            try Arg.sep(e, &first);
            try e.print("constant bulg_Params& bulg_params_buffer [[buffer({d})]]", .{buffer});
        }
        for (samplers, 0..) |r, k| {
            const n = e.declName(.{ .global = r });
            try Arg.sep(e, &first);
            try e.print("texture2d<float> bulg_{s}_texture [[texture({d})]]", .{ n, k });
            try Arg.sep(e, &first);
            try e.print("sampler bulg_{s}_sampler [[sampler({d})]]", .{ n, k });
        }
        try e.put(") {");
        try e.nl();
        try e.line_("  bulg_Stage s;");
        for (blocks) |d| {
            const n = e.declName(d);
            try e.print("  s.bulg_{s} = &bulg_{s}_buffer;", .{ n, n });
            try e.nl();
        }
        if (has_params) try e.line_("  s.bulg_params = &bulg_params_buffer;");
        for (samplers) |r| {
            const n = e.declName(.{ .global = r });
            try e.print("  s.{s} = {{bulg_{s}_texture, bulg_{s}_sampler}};", .{ n, n, n });
            try e.nl();
        }
        if (vertex) {
            if (uses.vertex_id) try e.line_("  s.gl_VertexID = int(bulg_vertex_id);");
            if (uses.instance_id) try e.line_("  s.gl_InstanceID = int(bulg_instance_id);");
        } else {
            if (uses.frag_coord) try e.line_("  s.gl_FragCoord = bulg_frag_coord;");
            if (uses.front_facing) try e.line_("  s.gl_FrontFacing = bulg_front_facing;");
            if (uses.point_coord) try e.line_("  s.gl_PointCoord = bulg_point_coord;");
        }
        for (ins) |r| {
            const n = e.declName(.{ .global = r });
            try e.print("  s.{s} = bulg_in.{s};", .{ n, n });
            try e.nl();
        }
        try e.line_("  s.main();");
        if (has_out) {
            try e.print("  {s} bulg_out;", .{out_name});
            try e.nl();
            if (vertex) {
                // GL's clip space in Metal's: y down instead of up (so that rows, texture
                // coordinates and gl_FragCoord keep GL's numbers), depth 0..1 instead of -1..1
                try e.line_("  bulg_out.gl_Position = float4(s.gl_Position.x, -s.gl_Position.y, (s.gl_Position.z + s.gl_Position.w) * 0.5f, s.gl_Position.w);");
                if (uses.point_size) try e.line_("  bulg_out.gl_PointSize = s.gl_PointSize;");
            }
            for (outs) |r| {
                const n = e.declName(.{ .global = r });
                try e.print("  bulg_out.{s} = s.{s};", .{ n, n });
                try e.nl();
            }
            try e.line_("  return bulg_out;");
        }
        try e.line_("}");
    }

    // ------------------------------------------------------------ MSL: calls and constructors

    fn argAt(e: *Emitter, mi: u32, l: Ir.List, k: usize) Ir.ExprId {
        return @fromBackingInt(@intCast(e.mod(mi).list(l)[k]));
    }

    /// A GLSL built-in in Metal: most keep their name; some are Metal's under another
    /// name, some are prelude functions of the GLSL name, a few are written out.
    fn mslCall(e: *Emitter, mi: u32, ex: Ir.Expr, func: u16, l: Ir.List) Error!void {
        const f = builtins.functions[func];
        const n = f.name;
        const eq = std.mem.eql;
        const ret = ex.type;
        if (eq(u8, n, "not")) {
            try e.put("(!");
            try e.expr(mi, e.argAt(mi, l, 0), prec_prefix);
            return e.put(")");
        }
        if (eq(u8, n, "floatBitsToInt") or eq(u8, n, "floatBitsToUint") or eq(u8, n, "intBitsToFloat") or eq(u8, n, "uintBitsToFloat")) {
            try e.put("as_type<");
            try e.typeName(ret);
            try e.put(">");
            return e.args(mi, l);
        }
        if (eq(u8, n, "packHalf2x16")) {
            try e.put("as_type<uint>(half2(");
            try e.expr(mi, e.argAt(mi, l, 0), 0);
            return e.put("))");
        }
        if (eq(u8, n, "unpackHalf2x16")) {
            try e.put("float2(as_type<half2>(");
            try e.expr(mi, e.argAt(mi, l, 0), 0);
            return e.put("))");
        }
        // mix with a bool vector picks, it does not blend
        if (eq(u8, n, "mix") and f.params[2].scalarOf() == .bool) {
            try e.put("select");
            return e.args(mi, l);
        }
        const renamed: ?[]const u8 = if (eq(u8, n, "atan") and f.params.len == 2)
            "atan2"
        else if (eq(u8, n, "inversesqrt"))
            "rsqrt"
        else if (eq(u8, n, "dFdx"))
            "dfdx"
        else if (eq(u8, n, "dFdy"))
            "dfdy"
        else if (eq(u8, n, "roundEven"))
            "rint"
        else if (eq(u8, n, "packSnorm2x16"))
            "pack_float_to_snorm2x16"
        else if (eq(u8, n, "unpackSnorm2x16"))
            "unpack_snorm2x16_to_float"
        else if (eq(u8, n, "packUnorm2x16"))
            "pack_float_to_unorm2x16"
        else if (eq(u8, n, "unpackUnorm2x16"))
            "unpack_unorm2x16_to_float"
        else
            null;
        if (eq(u8, n, "mod")) e.helpers.insert(.mod);
        if (eq(u8, n, "radians")) e.helpers.insert(.radians);
        if (eq(u8, n, "degrees")) e.helpers.insert(.degrees);
        if (std.mem.startsWith(u8, n, "lessThan") or std.mem.startsWith(u8, n, "greaterThan") or eq(u8, n, "equal") or eq(u8, n, "notEqual")) e.helpers.insert(.relational);
        if (f.kind == .texture) e.helpers.insert(.sampler);
        const sized: ?u8 = if (ret.matrixLen()) |k| k else null;
        if (sized) |k| {
            if (eq(u8, n, "matrixCompMult")) e.helpers.insert(switch (k) {
                2 => .comp_mult2,
                3 => .comp_mult3,
                else => .comp_mult4,
            });
            if (eq(u8, n, "outerProduct")) e.helpers.insert(switch (k) {
                2 => .outer2,
                3 => .outer3,
                else => .outer4,
            });
            if (eq(u8, n, "inverse")) e.helpers.insert(switch (k) {
                2 => .inverse2,
                3 => .inverse3,
                else => .inverse4,
            });
        }
        try e.put(renamed orelse n);
        // Metal's common functions take their arguments of one type: a GLSL scalar beside
        // vectors is made the vector
        const splat = eq(u8, n, "min") or eq(u8, n, "max") or eq(u8, n, "clamp") or eq(u8, n, "mix") or
            eq(u8, n, "step") or eq(u8, n, "smoothstep") or eq(u8, n, "mod");
        try e.put("(");
        for (e.mod(mi).list(l), 0..) |a, k| {
            if (k > 0) try e.put(", ");
            const ax: Ir.ExprId = @fromBackingInt(@intCast(a));
            if (splat and f.params[k].isScalar() and !ret.isScalar()) {
                try e.typeName(ret);
                try e.put("(");
                try e.expr(mi, ax, 0);
                try e.put(")");
            } else try e.expr(mi, ax, 0);
        }
        try e.put(")");
    }

    /// Component `k` of `x` (a scalar is its own component 0).
    fn component(e: *Emitter, mi: u32, x: Ir.ExprId, k: u8) Error!void {
        const t = e.mod(mi).expr(x).type;
        if (t.isScalar()) return e.expr(mi, x, 0);
        if (t.matrixLen()) |n| {
            try e.expr(mi, x, prec_postfix);
            return e.print("[{d}][{d}]", .{ k / n, k % n });
        }
        try e.expr(mi, x, prec_postfix);
        try e.print(".{c}", .{"xyzw"[k]});
    }

    /// The first `n` components of a vector `x`, as a swizzle (all of them: as it is).
    fn leading(e: *Emitter, mi: u32, x: Ir.ExprId, n: u8) Error!void {
        const t = e.mod(mi).expr(x).type;
        if (t.vectorLen().? == n) return e.expr(mi, x, 0);
        try e.expr(mi, x, prec_postfix);
        try e.print(".{s}", .{"xyzw"[0..n]});
    }

    /// A GLSL constructor in Metal: the forms Metal's own constructors take are kept,
    /// the others are spelt out (or go through a prelude function).
    fn mslConstruct(e: *Emitter, mi: u32, t: Type, l: Ir.List) Error!void {
        const pool = &e.s.pool;
        const items = e.mod(mi).list(l);
        if (pool.arrayOf(t) != null or pool.structOf(t) != null) {
            try e.typeName(t);
            try e.put("{");
            for (items, 0..) |a, k| {
                if (k > 0) try e.put(", ");
                try e.expr(mi, @fromBackingInt(@intCast(a)), 0);
            }
            return e.put("}");
        }
        const first = e.argAt(mi, l, 0);
        const ft = e.mod(mi).expr(first).type;
        if (t.isScalar()) {
            // a conversion takes a vector's or matrix's first component
            try e.typeName(t);
            try e.put("(");
            try e.component(mi, first, 0);
            return e.put(")");
        }
        if (t.matrixLen()) |n| return e.mslMatrix(mi, t, n, l, ft);
        const n = t.vectorLen().?;
        if (items.len == 1) {
            try e.typeName(t);
            try e.put("(");
            if (ft.isScalar()) {
                try e.expr(mi, first, 0);
            } else if (ft.vectorLen() != null) {
                try e.leading(mi, first, n);
            } else return e.unsupported("a vector made from a matrix");
            return e.put(")");
        }
        // several: the last one gives only what is still missing
        try e.typeName(t);
        try e.put("(");
        var have: u8 = 0;
        for (items, 0..) |a, k| {
            const ax: Ir.ExprId = @fromBackingInt(@intCast(a));
            const at = e.mod(mi).expr(ax).type;
            const c = at.vectorLen() orelse return e.unsupported("a vector made from a matrix and more");
            if (k > 0) try e.put(", ");
            const take = @min(c, n - have);
            if (take == c) try e.expr(mi, ax, 0) else if (take == 1) try e.component(mi, ax, 0) else try e.leading(mi, ax, take);
            have += take;
        }
        try e.put(")");
    }

    fn mslMatrix(e: *Emitter, mi: u32, t: Type, n: u8, l: Ir.List, ft: Type) Error!void {
        const items = e.mod(mi).list(l);
        const first = e.argAt(mi, l, 0);
        if (items.len == 1) {
            if (ft.isScalar()) {
                // a scalar is the diagonal
                e.helpers.insert(switch (n) {
                    2 => .diag2,
                    3 => .diag3,
                    else => .diag4,
                });
                try e.print("bulg_diag{d}(", .{n});
                if (ft.scalarOf() != .float and ft.scalarOf() != .half) {
                    try e.put("float(");
                    try e.expr(mi, first, 0);
                    try e.put(")");
                } else try e.expr(mi, first, 0);
                return e.put(")");
            }
            if (ft.matrixLen()) |m| {
                if (m == n) {
                    try e.typeName(t);
                    try e.put("(");
                    try e.expr(mi, first, 0);
                    return e.put(")");
                }
                e.helpers.insert(msl.Helper.matFrom(n, m));
                try e.print("bulg_mat{d}(", .{n});
                try e.expr(mi, first, 0);
                return e.put(")");
            }
            return e.unsupported("a matrix made from one vector");
        }
        // columns as they are
        const columns = items.len == n and for (items) |a| {
            if (e.mod(mi).expr(@fromBackingInt(@intCast(a))).type.vectorLen() != n) break false;
        } else true;
        if (columns) {
            try e.typeName(t);
            return e.args(mi, l);
        }
        // otherwise the components, n to a column
        var comps: std.ArrayList(struct { Ir.ExprId, u8 }) = .empty;
        for (items) |a| {
            const ax: Ir.ExprId = @fromBackingInt(@intCast(a));
            const c = e.mod(mi).expr(ax).type.vectorLen() orelse return e.unsupported("a matrix made from a matrix and more");
            for (0..c) |k| try comps.append(e.a, .{ ax, @intCast(k) });
        }
        if (comps.items.len < @as(usize, n) * n) return e.unsupported("a matrix made from too few components");
        try e.typeName(t);
        try e.put("(");
        const col = Type.vector(.float, n);
        for (0..n) |c| {
            if (c > 0) try e.put(", ");
            try e.typeName(col);
            try e.put("(");
            for (0..n) |r| {
                if (r > 0) try e.put(", ");
                const it = comps.items[c * n + r];
                const at = e.mod(mi).expr(it[0]).type;
                if (at.isScalar()) try e.expr(mi, it[0], 0) else try e.component(mi, it[0], it[1]);
            }
            try e.put(")");
        }
        try e.put(")");
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
