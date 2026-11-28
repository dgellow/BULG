//! What one stage of a program reaches from `main`, after specialisation: the functions,
//! globals, uniform blocks and structs its text must declare. The emitters print these;
//! reflection describes them.

const std = @import("std");
const Session = @import("../Session.zig");
const Ir = @import("Ir.zig");
const eval = @import("eval.zig");
const types = @import("../sema/types.zig");
const Type = types.Type;

pub const Error = error{OutOfMemory};

pub const Decl = union(enum) {
    @"struct": struct { module: u32, index: u32 },
    block: struct { module: u32, index: u32 },
    global: Ir.Ref,
    function: Ir.Ref,

    pub fn eql(a: Decl, b: Decl) bool {
        return std.meta.eql(a, b);
    }
};

pub const Reach = struct {
    s: *const Session,
    a: std.mem.Allocator,
    info: Ir.StageInfo,
    specs: eval.Specs,
    /// in the order they were found: functions callees first, then what they use
    decls: std.ArrayList(Decl) = .empty,

    fn mod(e: *Reach, mi: u32) *const Ir.Module {
        return &e.s.modules[mi];
    }
    fn ast(e: *Reach, mi: u32) *const @import("../syntax/Ast.zig") {
        return &e.s.asts.items[mi];
    }

    pub fn addDecl(e: *Reach, d: Decl) Error!bool {
        for (e.decls.items) |x| if (x.eql(d)) return false;
        try e.decls.append(e.a, d);
        return true;
    }

    pub fn collect(e: *Reach) Error!void {
        for (e.info.functions) |f| {
            _ = try e.addDecl(.{ .function = f });
            const func = e.mod(f.module).functions[f.index];
            try e.useType(func.ret);
            for (func.params) |p| try e.useType(p.type);
            for (func.locals) |l| try e.useType(l.type);
            if (func.body != .none) try e.useStmt(f.module, func.body);
        }
    }

    pub fn useType(e: *Reach, t: Type) Error!void {
        const pool = &e.s.pool;
        if (pool.arrayOf(t)) |a| return e.useType(a.elem);
        if (pool.structOf(t)) |st| {
            const where = e.structDecl(t) orelse return;
            if (try e.addDecl(where)) for (st.fields) |f| try e.useType(f.type);
        }
    }

    pub fn structDecl(e: *Reach, t: Type) ?Decl {
        for (e.s.modules, 0..) |m, mi| for (m.structs, 0..) |st, k| {
            if (st == t) return .{ .@"struct" = .{ .module = @intCast(mi), .index = @intCast(k) } };
        };
        return null;
    }

    pub fn useStmt(e: *Reach, mi: u32, sid: Ir.StmtId) Error!void {
        if (sid == .none) return;
        const st = e.mod(mi).stmt(sid);
        switch (st.data) {
            .block => |l| for (e.mod(mi).list(l)) |x| try e.useStmt(mi, @fromBackingInt(@intCast(x))),
            .local => |d| try e.useExpr(mi, d.init),
            .expr => |x| try e.useExpr(mi, x),
            .@"if" => |d| {
                if (e.folded(mi, d.cond)) |taken| return e.useStmt(mi, if (taken) d.then else d.@"else");
                try e.useExpr(mi, d.cond);
                try e.useStmt(mi, d.then);
                try e.useStmt(mi, d.@"else");
            },
            .@"for" => |d| {
                try e.useStmt(mi, d.init);
                try e.useExpr(mi, d.cond);
                try e.useExpr(mi, d.step);
                try e.useStmt(mi, d.body);
            },
            .@"return" => |x| try e.useExpr(mi, x),
            .@"break", .@"continue", .discard => {},
        }
    }

    pub fn useExpr(e: *Reach, mi: u32, x: Ir.ExprId) Error!void {
        if (x == .none) return;
        const m = e.mod(mi);
        const ex = m.expr(x);
        try e.useType(ex.type);
        switch (ex.data) {
            .literal, .string, .local, .param, .builtin_var => {},
            .global => |r| {
                const g = e.mod(r.module).globals[r.index];
                if (g.block) |b| {
                    if (try e.addDecl(.{ .block = .{ .module = r.module, .index = b } })) {
                        for (e.mod(r.module).blocks[b].members) |mem| try e.useType(e.mod(r.module).globals[mem].type);
                    }
                } else if (try e.addDecl(.{ .global = r })) {
                    try e.useType(g.type);
                    if (g.kind != .spec or e.specs.get(r) == null) try e.useExpr(r.module, g.init);
                }
            },
            .alias => |r| try e.useExpr(r.module, e.mod(r.module).aliases[r.index].value),
            .call => |d| for (m.list(d.args)) |a| try e.useExpr(mi, @fromBackingInt(@intCast(a))),
            .builtin_call => |d| for (m.list(d.args)) |a| try e.useExpr(mi, @fromBackingInt(@intCast(a))),
            .construct => |l| for (m.list(l)) |a| try e.useExpr(mi, @fromBackingInt(@intCast(a))),
            .unary => |d| try e.useExpr(mi, d.operand),
            .binary => |d| {
                try e.useExpr(mi, d.lhs);
                try e.useExpr(mi, d.rhs);
            },
            .assign => |d| {
                try e.useExpr(mi, d.lhs);
                try e.useExpr(mi, d.rhs);
            },
            .ternary => |d| {
                if (e.folded(mi, d.cond)) |taken| return e.useExpr(mi, if (taken) d.then else d.@"else");
                try e.useExpr(mi, d.cond);
                try e.useExpr(mi, d.then);
                try e.useExpr(mi, d.@"else");
            },
            .index => |d| {
                try e.useExpr(mi, d.base);
                try e.useExpr(mi, d.index);
            },
            .swizzle => |d| try e.useExpr(mi, d.base),
            .field => |d| try e.useExpr(mi, d.base),
            .array_length => |d| try e.useExpr(mi, d.base),
        }
    }

    /// Whether `x` names a spec constant (directly or through aliases and constants).
    pub fn refsSpec(e: *Reach, mi: u32, x: Ir.ExprId) bool {
        if (x == .none) return false;
        const m = e.mod(mi);
        const ex = m.expr(x);
        return switch (ex.data) {
            .global => |r| blk: {
                const g = e.mod(r.module).globals[r.index];
                break :blk g.kind == .spec or (g.kind == .@"const" and e.refsSpec(r.module, g.init));
            },
            .alias => |r| e.refsSpec(r.module, e.mod(r.module).aliases[r.index].value),
            .unary => |d| e.refsSpec(mi, d.operand),
            .binary => |d| e.refsSpec(mi, d.lhs) or e.refsSpec(mi, d.rhs),
            .ternary => |d| e.refsSpec(mi, d.cond) or e.refsSpec(mi, d.then) or e.refsSpec(mi, d.@"else"),
            .construct => |l| for (m.list(l)) |a| {
                if (e.refsSpec(mi, @fromBackingInt(@intCast(a)))) break true;
            } else false,
            else => false,
        };
    }

    /// The branch a condition takes when it depends on spec constants and constants only.
    pub fn folded(e: *Reach, mi: u32, cond: Ir.ExprId) ?bool {
        if (!e.refsSpec(mi, cond)) return null;
        const v = eval.constant(e.s.modules, mi, cond, e.specs) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    fn module_rank(e: *Reach) Error![]u32 {
        // imported modules first: a post-order walk of the imports, from the stage's modules
        const rank = try e.a.alloc(u32, e.s.modules.len);
        @memset(rank, std.math.maxInt(u32));
        var next: u32 = 0;
        for (e.info.modules) |mi| try e.rankVisit(rank, &next, mi);
        return rank;
    }

    fn rankVisit(e: *Reach, rank: []u32, next: *u32, mi: u32) Error!void {
        if (rank[mi] != std.math.maxInt(u32)) return;
        rank[mi] = std.math.maxInt(u32) - 1; // visiting
        const ast_ = e.ast(mi);
        for (ast_.list(ast_.items)) |raw| {
            const n = ast_.node(@fromBackingInt(@intCast(raw)));
            if (n.data != .import) continue;
            const path = ast_.tokenText(n.data.import.path);
            if (e.s.findModule(path[1 .. path.len - 1])) |t| try e.rankVisit(rank, next, t);
        }
        rank[mi] = next.*;
        next.* += 1;
    }

    fn position(e: *Reach, d: Decl) struct { u32, u32 } {
        const mi: u32, const tok: u32 = switch (d) {
            .@"struct" => |x| .{ x.module, e.mod(x.module).struct_toks[x.index] },
            .block => |x| .{ x.module, e.mod(x.module).blocks[x.index].tok },
            .global => |r| .{ r.module, e.mod(r.module).globals[r.index].tok },
            .function => |r| .{ r.module, e.mod(r.module).functions[r.index].tok },
        };
        return .{ mi, e.ast(mi).tokens[tok].start };
    }

    /// The declarations each one needs before it.
    fn deps(e: *Reach, d: Decl, out: *std.ArrayList(Decl)) Error!void {
        switch (d) {
            .@"struct" => |x| {
                const st = e.s.pool.structOf(e.mod(x.module).structs[x.index]).?;
                for (st.fields) |f| try e.typeDeps(f.type, out);
            },
            .block => |x| for (e.mod(x.module).blocks[x.index].members) |mem| try e.typeDeps(e.mod(x.module).globals[mem].type, out),
            .global => |r| {
                const g = e.mod(r.module).globals[r.index];
                try e.typeDeps(g.type, out);
                if (g.kind != .spec or e.specs.get(r) == null) try e.exprDeps(r.module, g.init, out);
            },
            .function => |r| {
                const f = e.mod(r.module).functions[r.index];
                try e.typeDeps(f.ret, out);
                for (f.params) |p| try e.typeDeps(p.type, out);
                for (f.locals) |l| try e.typeDeps(l.type, out);
                try e.stmtDeps(r.module, f.body, out);
            },
        }
    }

    fn typeDeps(e: *Reach, t: Type, out: *std.ArrayList(Decl)) Error!void {
        if (e.s.pool.arrayOf(t)) |a| return e.typeDeps(a.elem, out);
        if (e.structDecl(t)) |d| try out.append(e.a, d);
    }

    fn stmtDeps(e: *Reach, mi: u32, sid: Ir.StmtId, out: *std.ArrayList(Decl)) Error!void {
        if (sid == .none) return;
        const st = e.mod(mi).stmt(sid);
        switch (st.data) {
            .block => |l| for (e.mod(mi).list(l)) |x| try e.stmtDeps(mi, @fromBackingInt(@intCast(x)), out),
            .local => |d| try e.exprDeps(mi, d.init, out),
            .expr => |x| try e.exprDeps(mi, x, out),
            .@"if" => |d| {
                if (e.folded(mi, d.cond)) |taken| return e.stmtDeps(mi, if (taken) d.then else d.@"else", out);
                try e.exprDeps(mi, d.cond, out);
                try e.stmtDeps(mi, d.then, out);
                try e.stmtDeps(mi, d.@"else", out);
            },
            .@"for" => |d| {
                try e.stmtDeps(mi, d.init, out);
                try e.exprDeps(mi, d.cond, out);
                try e.exprDeps(mi, d.step, out);
                try e.stmtDeps(mi, d.body, out);
            },
            .@"return" => |x| try e.exprDeps(mi, x, out),
            .@"break", .@"continue", .discard => {},
        }
    }

    fn exprDeps(e: *Reach, mi: u32, x: Ir.ExprId, out: *std.ArrayList(Decl)) Error!void {
        if (x == .none) return;
        const m = e.mod(mi);
        const ex = m.expr(x);
        try e.typeDeps(ex.type, out);
        switch (ex.data) {
            .global => |r| {
                const g = e.mod(r.module).globals[r.index];
                try out.append(e.a, if (g.block) |b| .{ .block = .{ .module = r.module, .index = b } } else .{ .global = r });
            },
            .alias => |r| try e.exprDeps(r.module, e.mod(r.module).aliases[r.index].value, out),
            .call => |d| {
                try out.append(e.a, .{ .function = e.fill(d.callee) });
                for (m.list(d.args)) |a| try e.exprDeps(mi, @fromBackingInt(@intCast(a)), out);
            },
            .builtin_call => |d| for (m.list(d.args)) |a| try e.exprDeps(mi, @fromBackingInt(@intCast(a)), out),
            .construct => |l| for (m.list(l)) |a| try e.exprDeps(mi, @fromBackingInt(@intCast(a)), out),
            .unary => |d| try e.exprDeps(mi, d.operand, out),
            .binary => |d| {
                try e.exprDeps(mi, d.lhs, out);
                try e.exprDeps(mi, d.rhs, out);
            },
            .assign => |d| {
                try e.exprDeps(mi, d.lhs, out);
                try e.exprDeps(mi, d.rhs, out);
            },
            .ternary => |d| {
                if (e.folded(mi, d.cond)) |taken| return e.exprDeps(mi, if (taken) d.then else d.@"else", out);
                try e.exprDeps(mi, d.cond, out);
                try e.exprDeps(mi, d.then, out);
                try e.exprDeps(mi, d.@"else", out);
            },
            .index => |d| {
                try e.exprDeps(mi, d.base, out);
                try e.exprDeps(mi, d.index, out);
            },
            .swizzle => |d| try e.exprDeps(mi, d.base, out),
            .field => |d| try e.exprDeps(mi, d.base, out),
            .array_length => |d| try e.exprDeps(mi, d.base, out),
            else => {},
        }
    }

    /// The function a call runs in this stage: an extern's fill, or the callee.
    pub fn fill(e: *Reach, r: Ir.Ref) Ir.Ref {
        for (e.info.externs) |x| if (x.hole.module == r.module and x.hole.index == r.index) return x.fill;
        return r;
    }

    /// Declarations in source order (modules by rank), each after what it needs.
    pub fn order(e: *Reach) Error![]Decl {
        const rank = try e.module_rank();
        const n = e.decls.items.len;
        const need = try e.a.alloc(std.ArrayList(u32), n);
        for (e.decls.items, need) |d, *nd| {
            nd.* = .empty;
            var ds: std.ArrayList(Decl) = .empty;
            try e.deps(d, &ds);
            for (ds.items) |dep| for (e.decls.items, 0..) |o, k| {
                if (o.eql(dep) and !o.eql(d)) try nd.append(e.a, @intCast(k));
            };
        }
        const done = try e.a.alloc(bool, n);
        @memset(done, false);
        var out: std.ArrayList(Decl) = .empty;
        while (out.items.len < n) {
            var best: ?usize = null;
            var best_key: struct { u32, u32 } = .{ std.math.maxInt(u32), std.math.maxInt(u32) };
            for (e.decls.items, 0..) |d, k| {
                if (done[k]) continue;
                const ready = for (need[k].items) |dep| {
                    if (!done[dep]) break false;
                } else true;
                if (!ready) continue;
                const p = e.position(d);
                const key: struct { u32, u32 } = .{ rank[p[0]], p[1] };
                if (key[0] < best_key[0] or (key[0] == best_key[0] and key[1] < best_key[1])) {
                    best = k;
                    best_key = key;
                }
            }
            // the checker refuses cycles, so something is always ready
            const k = best orelse unreachable;
            done[k] = true;
            try out.append(e.a, e.decls.items[k]);
        }
        return out.items;
    }
};

/// The declarations of `r` in the order a text declares them: modules in link order (the
/// imported first), each module in its source's order, a declaration moved only as far as
/// a dependency needs.
pub fn ordered(s: *const Session, r: Reach, a: std.mem.Allocator) Error![]const Decl {
    _ = s;
    var copy = r;
    copy.a = a;
    return copy.order();
}

/// What `stage` of `prog` reaches; its lists are in `a`.
pub fn stage(s: *const Session, prog: *const Ir.Program, info: Ir.StageInfo, a: std.mem.Allocator) Error!Reach {
    var r: Reach = .{ .s = s, .a = a, .info = info, .specs = .{ .values = prog.specs } };
    try r.collect();
    return r;
}

/// A program's loose uniforms and params (not samplers, not in a block): what its
/// `bulg_Params` block holds, the same in both stages. Both stages' in the order their
/// texts declare them, the vertex stage first; one entry a name (GL links by name).
pub fn looseUniforms(s: *const Session, prog: *const Ir.Program, a: std.mem.Allocator) Error![]const Ir.Ref {
    var out: std.ArrayList(Ir.Ref) = .empty;
    for ([_]?Ir.StageInfo{ prog.vertex, prog.fragment }) |maybe| {
        const info = maybe orelse continue;
        const r = try stage(s, prog, info, a);
        for (try ordered(s, r, a)) |d| {
            if (d != .global) continue;
            const g = s.modules[d.global.module].globals[d.global.index];
            if (!isLoose(g)) continue;
            for (out.items) |o| {
                if (std.mem.eql(u8, s.modules[o.module].globals[o.index].name, g.name)) break;
            } else try out.append(a, d.global);
        }
    }
    return out.items;
}

/// Is `g` one of a `bulg_Params` block's members?
pub fn isLoose(g: Ir.Global) bool {
    return (g.kind == .uniform or g.kind == .param) and g.block == null and g.type != .sampler2D;
}

/// The std140 offsets of `members` laid out in order, and the block's size.
pub fn std140Offsets(s: *const Session, members: []const Ir.Ref, a: std.mem.Allocator) Error!struct { offsets: []const u32, size: u32 } {
    const offsets = try a.alloc(u32, members.len);
    var off: u32 = 0;
    var max_align: u32 = 16;
    for (members, offsets) |r, *o| {
        const l = types.std140(&s.pool, s.modules[r.module].globals[r.index].type);
        off = std.mem.alignForward(u32, off, l.alignment);
        o.* = off;
        off += l.size;
        max_align = @max(max_align, l.alignment);
    }
    return .{ .offsets = offsets, .size = std.mem.alignForward(u32, off, max_align) };
}
