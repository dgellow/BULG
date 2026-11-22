//! Syntax trees to checked modules and programs.
//!
//! 1. Each module's declarations are collected by name; imports are resolved.
//! 2. Structs, globals, aliases and function signatures are resolved on demand (the order
//!    of declarations in a module is free), with cycles reported.
//! 3. Function bodies are checked into the IR: every name resolved, every expression typed,
//!    no implicit conversions.
//! 4. Prototypes meet their definitions; call cycles are reported.
//! 5. Programs are linked: stages, modules, `extern`s, spec values, what each stage uses.
//!
//! An error never stops the check: a bad expression gets the type `invalid`, which matches
//! anything, so one mistake gives one diagnostic.

const std = @import("std");
const Session = @import("../Session.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ast = @import("../syntax/Ast.zig");
const Token = @import("../syntax/Token.zig");
const Ir = @import("../ir/Ir.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");
const Type = types.Type;
const Scalar = types.Scalar;
const ExprId = Ir.ExprId;
const StmtId = Ir.StmtId;

const Error = error{OutOfMemory};
const Code = Diagnostic.Code;

const Checker = @This();

s: *Session,
a: std.mem.Allocator,
mods: []Mod,

const State = enum { todo, busy, done };

const Sym = union(enum) {
    /// a name two imports declare (reported where it is used)
    ambiguous,
    @"struct": u32,
    global: u32,
    alias: u32,
    block: u32,
};

const Import = struct { module: u32, names: ?[]const u32, tok: u32 };

const StructDecl = struct { node: Ast.Index, state: State = .todo, type: Type = .invalid };

const GlobalDecl = struct {
    decl: Ast.Index,
    declarator: Ast.Index,
    block: ?u32 = null,
    state: State = .todo,
    g: Ir.Global = undefined,
};

const AliasDecl = struct { node: Ast.Index, state: State = .todo, value: ExprId = .none, type: Type = .invalid };

const FuncDecl = struct {
    node: Ast.Index,
    sig: State = .todo,
    ret: Type = .invalid,
    params: []Ir.Param = &.{},
    /// for a prototype: the definition in the same module
    definition: ?u32 = null,
    f: Ir.Function = undefined,
};

const BlockDecl = struct { node: Ast.Index, members: []u32 = &.{} };

const Mod = struct {
    ast: *const Ast,
    name: []const u8,
    src: Source.Id,
    scope: std.StringHashMapUnmanaged(Sym) = .empty,
    funcs_by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    imports: std.ArrayList(Import) = .empty,
    structs: std.ArrayList(StructDecl) = .empty,
    globals: std.ArrayList(GlobalDecl) = .empty,
    aliases: std.ArrayList(AliasDecl) = .empty,
    funcs: std.ArrayList(FuncDecl) = .empty,
    blocks: std.ArrayList(BlockDecl) = .empty,
    programs: std.ArrayList(Ast.Index) = .empty,
    exprs: std.ArrayList(Ir.Expr) = .empty,
    stmts: std.ArrayList(Ir.Stmt) = .empty,
    extra: std.ArrayList(u32) = .empty,
    ir_blocks: std.ArrayList(Ir.Block) = .empty,

    fn text(m: *const Mod, tok: u32) []const u8 {
        return m.ast.tokenText(tok);
    }
    fn node(m: *const Mod, i: Ast.Index) Ast.Node {
        return m.ast.node(i);
    }
    fn nodeList(m: *const Mod, r: Ast.Range) []const u32 {
        return m.ast.list(r);
    }
    fn expr(m: *const Mod, e: ExprId) Ir.Expr {
        return m.exprs.items[@backingInt(e)];
    }
};

pub fn run(s: *Session) Error!void {
    var c: Checker = .{ .s = s, .a = s.arena(), .mods = try s.arena().alloc(Mod, s.asts.items.len) };
    for (c.mods, s.asts.items, s.sources.items, 0..) |*m, *ast, src, i| m.* = .{
        .ast = ast,
        .name = Session.moduleName(src.path),
        .src = @fromBackingInt(@intCast(@as(u32, @intCast(i)))),
    };
    for (0..c.mods.len) |i| try c.collect(@intCast(i));
    for (0..c.mods.len) |i| try c.resolveImports(@intCast(i));
    for (c.mods, 0..) |*m, i| {
        const mi: u32 = @intCast(i);
        for (0..m.structs.items.len) |k| _ = try c.structType(mi, @intCast(k));
        for (0..m.globals.items.len) |k| try c.resolveGlobal(mi, @intCast(k));
        for (0..m.aliases.items.len) |k| try c.resolveAlias(mi, @intCast(k));
        for (0..m.funcs.items.len) |k| try c.resolveSignature(mi, @intCast(k));
    }
    for (0..c.mods.len) |i| try c.linkPrototypes(@intCast(i));
    for (c.mods, 0..) |*m, i| {
        for (0..m.funcs.items.len) |k| try c.checkBody(@intCast(i), @intCast(k));
    }
    try c.checkRecursion();
    // programs check expressions of their own (spec values) into the modules' IR, so the
    // modules are finished after them
    try c.linkPrograms();
    try c.finishModules();
}

// ---------------------------------------------------------------- diagnostics

fn report(c: *Checker, m: u32, tok: u32, code: Code, comptime fmt: []const u8, args: anytype) Error!void {
    return c.reportHint(m, tok, code, null, fmt, args);
}

fn reportHint(c: *Checker, m: u32, tok: u32, code: Code, hint: ?[]const u8, comptime fmt: []const u8, args: anytype) Error!void {
    const ast = c.mods[m].ast;
    const t = ast.tokens[tok];
    try c.s.diags.add(c.a, .{
        .severity = .@"error",
        .code = code,
        .span = .{ .src = c.mods[m].src, .start = t.start, .end = t.end },
        .message = try std.fmt.allocPrint(c.a, fmt, args),
        .hint = hint,
    });
}

/// A type's name for a message (in the arena).
fn tn(c: *Checker, t: Type) []const u8 {
    var buf: [128]u8 = undefined;
    return c.a.dupe(u8, c.s.pool.name(t, &buf)) catch "(type)";
}

fn typeList(c: *Checker, ts: []const Type) []const u8 {
    var out: std.Io.Writer.Allocating = .init(c.a);
    out.writer.writeByte('(') catch return "(...)";
    for (ts, 0..) |t, i| {
        if (i > 0) out.writer.writeAll(", ") catch {};
        c.s.pool.format(t, &out.writer) catch {};
    }
    out.writer.writeByte(')') catch {};
    return out.written();
}

// ---------------------------------------------------------------- 1. collecting

fn isReserved(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "gl_") or std.mem.indexOf(u8, name, "__") != null;
}

fn declare(c: *Checker, mi: u32, name_tok: u32, sym: Sym) Error!void {
    const m = &c.mods[mi];
    const name = m.text(name_tok);
    if (isReserved(name)) return c.report(mi, name_tok, .reserved_name, "`{s}`: names starting with `gl_` or containing `__` are reserved", .{name});
    if (types.builtin_names.get(name) != null) return c.report(mi, name_tok, .reserved_name, "`{s}` is a built-in type", .{name});
    if (m.funcs_by_name.contains(name)) return c.report(mi, name_tok, .duplicate_declaration, "`{s}` is already a function of this module", .{name});
    const gop = try m.scope.getOrPut(c.a, name);
    if (gop.found_existing) return c.report(mi, name_tok, .duplicate_declaration, "`{s}` is declared twice in this module", .{name});
    gop.value_ptr.* = sym;
}

fn collect(c: *Checker, mi: u32) Error!void {
    const m = &c.mods[mi];
    for (m.nodeList(m.ast.items)) |raw| {
        const i: Ast.Index = @fromBackingInt(@intCast(raw));
        const n = m.node(i);
        switch (n.data) {
            .import => try m.imports.append(c.a, .{ .module = undefined, .names = null, .tok = n.tok }),
            .alias => |d| {
                const k: u32 = @intCast(m.aliases.items.len);
                try m.aliases.append(c.a, .{ .node = i });
                try c.declare(mi, d.name, .{ .alias = k });
            },
            .struct_decl => |d| {
                const k: u32 = @intCast(m.structs.items.len);
                try m.structs.append(c.a, .{ .node = i });
                try c.declare(mi, d.name, .{ .@"struct" = k });
            },
            .uniform_block => |d| {
                const k: u32 = @intCast(m.blocks.items.len);
                var members: std.ArrayList(u32) = .empty;
                for (m.nodeList(d.members)) |mem| {
                    const md = m.node(@fromBackingInt(@intCast(mem))).data.var_decl;
                    for (m.nodeList(md.declarators)) |dr| {
                        const g: u32 = @intCast(m.globals.items.len);
                        try m.globals.append(c.a, .{ .decl = @fromBackingInt(@intCast(mem)), .declarator = @fromBackingInt(@intCast(dr)), .block = k });
                        try members.append(c.a, g);
                        try c.declare(mi, m.node(@fromBackingInt(@intCast(dr))).data.declarator.name, .{ .global = g });
                    }
                }
                try m.blocks.append(c.a, .{ .node = i, .members = members.items });
                try c.declare(mi, d.name, .{ .block = k });
            },
            .var_decl => |d| {
                for (m.nodeList(d.declarators)) |dr| {
                    const g: u32 = @intCast(m.globals.items.len);
                    try m.globals.append(c.a, .{ .decl = i, .declarator = @fromBackingInt(@intCast(dr)) });
                    try c.declare(mi, m.node(@fromBackingInt(@intCast(dr))).data.declarator.name, .{ .global = g });
                }
            },
            .function => |d| {
                const name = m.text(d.name);
                const k: u32 = @intCast(m.funcs.items.len);
                try m.funcs.append(c.a, .{ .node = i });
                if (isReserved(name)) {
                    try c.report(mi, d.name, .reserved_name, "`{s}`: names starting with `gl_` or containing `__` are reserved", .{name});
                } else if (builtins.overloads(name).len > 0) {
                    try c.report(mi, d.name, .reserved_name, "`{s}` is a built-in function; a module cannot define or overload it", .{name});
                } else if (types.builtin_names.get(name) != null) {
                    try c.report(mi, d.name, .reserved_name, "`{s}` is a built-in type", .{name});
                } else if (m.scope.contains(name)) {
                    try c.report(mi, d.name, .duplicate_declaration, "`{s}` is already declared in this module", .{name});
                }
                const gop = try m.funcs_by_name.getOrPut(c.a, name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(c.a, k);
            },
            .program => try m.programs.append(c.a, i),
            else => {},
        }
    }
}

fn resolveImports(c: *Checker, mi: u32) Error!void {
    const m = &c.mods[mi];
    var k: usize = 0;
    for (m.nodeList(m.ast.items)) |raw| {
        const n = m.node(@fromBackingInt(@intCast(raw)));
        if (n.data != .import) continue;
        const d = n.data.import;
        const path = stripQuotes(m.text(d.path));
        const target = c.s.findModule(path) orelse {
            try c.report(mi, d.path, .unknown_module, "no module `{s}` in this session", .{path});
            m.imports.items[k].module = std.math.maxInt(u32);
            k += 1;
            continue;
        };
        var names: ?[]u32 = null;
        if (d.names.len > 0) {
            names = try c.a.dupe(u32, m.nodeList(d.names));
            const tm = &c.mods[target];
            for (names.?) |t| {
                const nm = m.text(t);
                if (!tm.scope.contains(nm) and !tm.funcs_by_name.contains(nm))
                    try c.report(mi, t, .unknown_name, "module `{s}` declares no `{s}`", .{ path, nm });
            }
        }
        m.imports.items[k] = .{ .module = target, .names = names, .tok = d.path };
        k += 1;
    }
}

fn stripQuotes(t: []const u8) []const u8 {
    return if (t.len >= 2 and t[0] == '"') t[1 .. t.len - 1] else t;
}

fn importAllows(c: *Checker, mi: u32, imp: Import, name: []const u8) bool {
    if (imp.module == std.math.maxInt(u32)) return false;
    const names = imp.names orelse return true;
    for (names) |t| if (std.mem.eql(u8, c.mods[mi].text(t), name)) return true;
    return false;
}

const Found = struct { module: u32, sym: Sym };

/// A module-level name: the module's own declarations, then its imports'.
fn lookup(c: *Checker, mi: u32, name: []const u8, tok: u32) Error!?Found {
    const m = &c.mods[mi];
    if (m.scope.get(name)) |sym| return .{ .module = mi, .sym = sym };
    var found: ?Found = null;
    for (m.imports.items) |imp| {
        if (!c.importAllows(mi, imp, name)) continue;
        if (c.mods[imp.module].scope.get(name)) |sym| {
            if (found) |f| {
                if (f.module != imp.module) {
                    try c.report(mi, tok, .ambiguous_name, "`{s}` is declared by both `{s}` and `{s}`", .{ name, c.mods[f.module].name, c.mods[imp.module].name });
                    return .{ .module = mi, .sym = .ambiguous };
                }
            }
            found = .{ .module = imp.module, .sym = sym };
        }
    }
    return found;
}

/// Every user function named `name` this module sees: its own and its imports'.
fn functionsNamed(c: *Checker, mi: u32, name: []const u8) Error![]const Ir.Ref {
    var out: std.ArrayList(Ir.Ref) = .empty;
    const m = &c.mods[mi];
    if (m.funcs_by_name.get(name)) |l| for (l.items) |f| try out.append(c.a, .{ .module = mi, .index = f });
    for (m.imports.items) |imp| {
        if (!c.importAllows(mi, imp, name)) continue;
        if (c.mods[imp.module].funcs_by_name.get(name)) |l| for (l.items) |f| try out.append(c.a, .{ .module = imp.module, .index = f });
    }
    return out.items;
}

// ---------------------------------------------------------------- 2. declarations

/// The type a type-name node names (with its `[n]`, if any).
fn typeOf(c: *Checker, mi: u32, node: Ast.Index) Error!Type {
    const m = &c.mods[mi];
    const d = m.node(node).data.type_name;
    const name = m.text(d.name);
    var t: Type = .invalid;
    if (types.builtin_names.get(name)) |b| {
        t = b;
    } else if (try c.lookup(mi, name, d.name)) |f| switch (f.sym) {
        .@"struct" => |k| t = try c.structType(f.module, k),
        .ambiguous => return .invalid,
        else => {
            try c.report(mi, d.name, .unknown_type, "`{s}` is not a type", .{name});
            return .invalid;
        },
    } else {
        try c.report(mi, d.name, .unknown_type, "unknown type `{s}`", .{name});
        return .invalid;
    }
    if (d.array_len != .none) t = try c.arrayOf(mi, t, d.array_len);
    return t;
}

/// `elem[len]`, with `len` a positive constant integer.
fn arrayOf(c: *Checker, mi: u32, elem: Type, len_node: Ast.Index) Error!Type {
    const m = &c.mods[mi];
    var x = c.moduleCtx(mi);
    const e = try c.expr(&x, len_node);
    if (elem == .invalid or m.expr(e).type == .invalid) return .invalid;
    if (c.s.pool.arrayOf(elem) != null) {
        try c.report(mi, m.node(len_node).tok, .bad_array_size, "arrays of arrays are not in BULG v0", .{});
        return .invalid;
    }
    const v = c.evalConst(mi, e);
    const n: i64 = if (v) |k| switch (k) {
        .int => |i| i,
        .uint => |u| u,
        else => -1,
    } else -1;
    if (v == null or n <= 0) {
        try c.report(mi, m.node(len_node).tok, .bad_array_size, "an array's size must be a positive constant integer", .{});
        return .invalid;
    }
    return c.s.pool.array(c.a, elem, @intCast(n));
}

fn structType(c: *Checker, mi: u32, k: u32) Error!Type {
    const m = &c.mods[mi];
    const sd = &m.structs.items[k];
    switch (sd.state) {
        .done => return sd.type,
        .busy => {
            const d = m.node(sd.node).data.struct_decl;
            try c.report(mi, d.name, .declaration_cycle, "struct `{s}` contains itself", .{m.text(d.name)});
            return .invalid;
        },
        .todo => {},
    }
    sd.state = .busy;
    const d = m.node(sd.node).data.struct_decl;
    var fields: std.ArrayList(types.Field) = .empty;
    for (m.nodeList(d.fields)) |fraw| {
        const fd = m.node(@fromBackingInt(@intCast(fraw))).data.var_decl;
        if (@as(u8, @bitCast(fd.quals)) != 0 or fd.location != .none or fd.meta.len > 0)
            try c.report(mi, m.node(@fromBackingInt(@intCast(fraw))).tok, .misplaced_declaration, "a struct's fields take no qualifiers", .{});
        const base = try c.typeOf(mi, fd.type);
        for (m.nodeList(fd.declarators)) |dr| {
            const dd = m.node(@fromBackingInt(@intCast(dr))).data.declarator;
            var ft = base;
            if (dd.array_len != .none) ft = try c.arrayOf(mi, base, dd.array_len);
            if (dd.init != .none) try c.report(mi, dd.name, .bad_initializer, "a struct's fields have no defaults", .{});
            if (ft == .sampler2D) try c.report(mi, dd.name, .misplaced_declaration, "a struct cannot hold a sampler", .{});
            for (fields.items) |f| if (std.mem.eql(u8, f.name, m.text(dd.name)))
                try c.report(mi, dd.name, .duplicate_declaration, "`{s}` is a field twice", .{f.name});
            try fields.append(c.a, .{ .name = m.text(dd.name), .type = ft });
        }
    }
    // m may have moved? No: mods is a fixed slice; the lists inside only grow.
    const t = try c.s.pool.addStruct(c.a, .{ .name = m.text(d.name), .fields = fields.items, .decl = k });
    const sd2 = &c.mods[mi].structs.items[k];
    sd2.state = .done;
    sd2.type = t;
    return t;
}

const storage_hint = "a declaration takes one of `uniform`, `in`, `out`, `const`, `param`, `spec`, or none";

fn resolveGlobal(c: *Checker, mi: u32, k: u32) Error!void {
    const m = &c.mods[mi];
    const gd = &m.globals.items[k];
    switch (gd.state) {
        .done => return,
        .busy => {
            const dd = m.node(gd.declarator).data.declarator;
            try c.report(mi, dd.name, .declaration_cycle, "`{s}` is defined in terms of itself", .{m.text(dd.name)});
            return;
        },
        .todo => {},
    }
    gd.state = .busy;
    const decl_node = gd.decl;
    const in_block = gd.block;
    const d = m.node(decl_node).data.var_decl;
    const dd = m.node(gd.declarator).data.declarator;
    const name = m.text(dd.name);
    const q = d.quals;

    var kind: Ir.GlobalKind = .mutable;
    var count: u8 = 0;
    if (q.uniform) {
        kind = .uniform;
        count += 1;
    }
    if (q.in) {
        kind = .in;
        count += 1;
    }
    if (q.out) {
        kind = .out;
        count += 1;
    }
    if (q.@"const") {
        kind = .@"const";
        count += 1;
    }
    if (q.param) {
        kind = .param;
        count += 1;
    }
    if (q.spec) {
        kind = .spec;
        count += 1;
    }
    if (in_block != null) {
        if (count > 0) try c.report(mi, m.node(decl_node).tok, .misplaced_declaration, "a uniform block's members take no qualifiers", .{});
        kind = .uniform;
    } else if (count > 1) {
        try c.reportHint(mi, m.node(decl_node).tok, .misplaced_declaration, storage_hint, "more than one kind of storage", .{});
    }

    var t = try c.typeOf(mi, d.type);
    if (dd.array_len != .none) t = try c.arrayOf(mi, t, dd.array_len);

    // where things may be
    if (q.flat and kind != .in and kind != .out)
        try c.report(mi, m.node(decl_node).tok, .misplaced_declaration, "`flat` is for `in` and `out` variables", .{});
    var location: ?u32 = null;
    if (d.location != .none) {
        if (kind != .in and kind != .out) {
            try c.report(mi, m.node(decl_node).tok, .misplaced_declaration, "`layout(location)` is for `in` and `out` variables", .{});
        } else {
            var x = c.moduleCtx(mi);
            const e = try c.expr(&x, d.location);
            if (c.evalConst(mi, e)) |v| switch (v) {
                .int => |i| if (i >= 0) {
                    location = @intCast(i);
                },
                .uint => |u| location = u,
                else => {},
            };
            if (location == null and m.expr(e).type != .invalid)
                try c.report(mi, m.node(d.location).tok, .not_constant, "a location is a constant integer of 0 or more", .{});
        }
    }
    if (t == .sampler2D and kind != .uniform)
        try c.report(mi, dd.name, .misplaced_declaration, "a sampler is a `uniform`", .{});
    if (t == .void) try c.report(mi, dd.name, .misplaced_declaration, "a variable cannot be `void`", .{});
    if ((kind == .in or kind == .out) and t != .invalid and (t.scalarOf() == null or t.scalarOf().? == .bool) and c.s.pool.arrayOf(t) == null)
        try c.report(mi, dd.name, .misplaced_declaration, "an `{s}` variable is a number, a vector or a matrix (not `{s}`)", .{ @tagName(kind), c.tn(t) });
    if (kind == .spec and t != .invalid and !(t == .bool or t == .int or t == .uint or t == .float))
        try c.report(mi, dd.name, .misplaced_declaration, "a spec constant is a `bool`, `int`, `uint` or `float`", .{});
    if (kind == .param and t != .invalid and !(t.isNumeric() or t.scalarOf() == .bool))
        try c.report(mi, dd.name, .misplaced_declaration, "a param is a number, a vector or a matrix", .{});

    // the initialiser
    var init: ExprId = .none;
    if (dd.init != .none) {
        var x = c.moduleCtx(mi);
        init = try c.expr(&x, dd.init);
        const it = c.mods[mi].expr(init).type;
        if (kind == .uniform and in_block == null) {
            try c.reportHint(mi, dd.name, .bad_initializer, "for a value with a default the host can change, declare a `param`", "a uniform's value comes from the host", .{});
        } else if (kind == .in or kind == .out) {
            try c.report(mi, dd.name, .bad_initializer, "an `{s}` variable has no initialiser", .{@tagName(kind)});
        } else if (!c.same(it, t)) {
            try c.report(mi, m.node(dd.init).tok, .type_mismatch, "`{s}` is a `{s}`; this is a `{s}`", .{ name, c.tn(t), c.tn(it) });
        } else if (!c.isConst(mi, init)) {
            try c.report(mi, m.node(dd.init).tok, .not_constant, "a module-level initialiser must be a constant expression", .{});
        } else if (kind == .spec and c.evalConst(mi, init) == null) {
            try c.report(mi, m.node(dd.init).tok, .not_constant, "a spec constant's default must be a value known now", .{});
        }
    } else if (kind == .@"const" or kind == .param or kind == .spec) {
        try c.report(mi, dd.name, .bad_initializer, "a `{s}` needs a value", .{@tagName(kind)});
    }

    // metadata
    var meta: std.ArrayList(Ir.Meta) = .empty;
    if (d.meta.len > 0) {
        if (kind != .param and kind != .spec and kind != .uniform)
            try c.report(mi, m.node(decl_node).tok, .misplaced_declaration, "metadata is for `param`, `spec` and `uniform` declarations", .{});
        for (m.nodeList(d.meta)) |me| {
            const md = m.node(@fromBackingInt(@intCast(me))).data.meta_entry;
            var args: std.ArrayList(u32) = .empty;
            for (m.nodeList(md.args)) |arg| {
                // a bare word nothing declares (`curve(exp)`) is the host's to read, like a
                // string; a declared name (`range(0., MAX)`) is its value
                const an = m.node(@fromBackingInt(@intCast(arg)));
                if (an.data == .ident and (try c.lookup(mi, m.text(an.tok), an.tok)) == null and builtins.variable(m.text(an.tok)) == null) {
                    try args.append(c.a, @backingInt(try c.addExpr(mi, .void, an.tok, .string)));
                    continue;
                }
                var x = c.moduleCtx(mi);
                x.allow_strings = true;
                const e = try c.expr(&x, @fromBackingInt(@intCast(arg)));
                const ee = c.mods[mi].expr(e);
                if (ee.data != .string and ee.type != .invalid and !c.isConst(mi, e))
                    try c.report(mi, m.node(@fromBackingInt(@intCast(arg))).tok, .not_constant, "metadata arguments are constants or strings", .{});
                try args.append(c.a, @backingInt(e));
            }
            try meta.append(c.a, .{ .key = m.text(md.key), .args = try c.extraList(mi, args.items) });
        }
    }

    const g = &c.mods[mi].globals.items[k];
    g.g = .{
        .name = name,
        .type = t,
        .kind = kind,
        .flat = q.flat,
        .location = location,
        .init = init,
        .meta = meta.items,
        .block = in_block,
        .tok = dd.name,
    };
    g.state = .done;
}

fn resolveAlias(c: *Checker, mi: u32, k: u32) Error!void {
    const m = &c.mods[mi];
    const ad = &m.aliases.items[k];
    switch (ad.state) {
        .done => return,
        .busy => {
            const d = m.node(ad.node).data.alias;
            try c.report(mi, d.name, .declaration_cycle, "alias `{s}` is defined in terms of itself", .{m.text(d.name)});
            return;
        },
        .todo => {},
    }
    ad.state = .busy;
    const d = m.node(ad.node).data.alias;
    var x = c.moduleCtx(mi);
    const e = try c.expr(&x, d.value);
    const a2 = &c.mods[mi].aliases.items[k];
    a2.value = e;
    a2.type = c.mods[mi].expr(e).type;
    a2.state = .done;
}

fn resolveSignature(c: *Checker, mi: u32, k: u32) Error!void {
    const m = &c.mods[mi];
    const fd = &m.funcs.items[k];
    if (fd.sig != .todo) return;
    fd.sig = .busy;
    const d = m.node(fd.node).data.function;
    const ret = try c.typeOf(mi, d.ret);
    if (ret == .sampler2D) try c.report(mi, d.name, .misplaced_declaration, "a function cannot return a sampler", .{});
    var params: std.ArrayList(Ir.Param) = .empty;
    for (m.nodeList(d.params)) |praw| {
        const pd = m.node(@fromBackingInt(@intCast(praw))).data.param;
        var t = try c.typeOf(mi, pd.type);
        if (pd.array_len != .none) t = try c.arrayOf(mi, t, pd.array_len);
        const pname = if (pd.name != 0) m.text(pd.name) else "";
        const ptok = if (pd.name != 0) pd.name else m.node(@fromBackingInt(@intCast(praw))).tok;
        if (t == .void) try c.report(mi, ptok, .misplaced_declaration, "a parameter cannot be `void`", .{});
        const dir: Ir.ParamDir = switch (pd.dir) {
            .none, .in => .in,
            .out => .out,
            .inout => .inout,
        };
        if (t == .sampler2D and dir != .in) try c.report(mi, ptok, .misplaced_declaration, "a sampler parameter is `in`", .{});
        if (pd.is_const and dir != .in) try c.report(mi, ptok, .misplaced_declaration, "`const` is for `in` parameters", .{});
        for (params.items) |p| if (pname.len > 0 and std.mem.eql(u8, p.name, pname))
            try c.report(mi, ptok, .duplicate_declaration, "`{s}` is a parameter twice", .{pname});
        try params.append(c.a, .{ .name = pname, .type = t, .dir = dir, .is_const = pd.is_const });
    }
    const f2 = &c.mods[mi].funcs.items[k];
    f2.ret = ret;
    f2.params = params.items;
    f2.sig = .done;
}

fn sameParams(a: []const Ir.Param, b: []const Ir.Param) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.type != y.type) return false;
    return true;
}

fn linkPrototypes(c: *Checker, mi: u32) Error!void {
    const m = &c.mods[mi];
    var it = m.funcs_by_name.iterator();
    while (it.next()) |e| {
        const list = e.value_ptr.items;
        for (list, 0..) |fi, i| {
            const f = &m.funcs.items[fi];
            const d = m.node(f.node).data.function;
            for (list[0..i]) |fj| {
                const g = &m.funcs.items[fj];
                const gdn = m.node(g.node).data.function;
                if (!sameParams(f.params, g.params)) continue;
                if (f.ret != g.ret and f.ret != .invalid and g.ret != .invalid) {
                    try c.report(mi, d.name, .duplicate_declaration, "`{s}{s}` is declared before with another return type", .{ e.key_ptr.*, c.paramList(f.params) });
                } else if (d.body != .none and gdn.body != .none) {
                    try c.report(mi, d.name, .duplicate_declaration, "`{s}{s}` is defined twice", .{ e.key_ptr.*, c.paramList(f.params) });
                } else if (d.is_extern != gdn.is_extern and (d.body != .none or gdn.body != .none)) {
                    try c.reportHint(mi, d.name, .duplicate_declaration, "an `extern` is defined by another module of the program", "`{s}{s}` is both `extern` and defined here", .{ e.key_ptr.*, c.paramList(f.params) });
                } else if (d.body != .none) {
                    g.definition = fi;
                } else if (gdn.body != .none) {
                    f.definition = fj;
                }
            }
        }
        for (list) |fi| {
            const f = &m.funcs.items[fi];
            const d = m.node(f.node).data.function;
            if (d.body == .none and !d.is_extern and f.definition == null) {
                // a later prototype of an earlier one is fine if one of them has a definition
                var defined = false;
                for (list) |fj| {
                    const g = &m.funcs.items[fj];
                    if (fj != fi and sameParams(f.params, g.params) and m.node(g.node).data.function.body != .none) defined = true;
                }
                if (!defined) try c.reportHint(mi, d.name, .missing_definition, "to leave the function to another module, declare it `extern`", "`{s}{s}` is declared but not defined in this module", .{ e.key_ptr.*, c.paramList(f.params) });
            }
        }
    }
}

fn paramList(c: *Checker, ps: []const Ir.Param) []const u8 {
    var ts: std.ArrayList(Type) = .empty;
    for (ps) |p| ts.append(c.a, p.type) catch return "(...)";
    return c.typeList(ts.items);
}

/// The function a call of `r` runs: a prototype's definition, or `r` itself.
fn callTarget(c: *Checker, r: Ir.Ref) Ir.Ref {
    if (c.mods[r.module].funcs.items[r.index].definition) |d| return .{ .module = r.module, .index = d };
    return r;
}

// ---------------------------------------------------------------- 3. bodies

const ScopeEntry = struct { name: []const u8, local: u32 };

/// Where an expression is being checked: a function body, or the module level (no
/// locals, no parameters).
const Ctx = struct {
    m: u32,
    func: ?u32 = null,
    params: []const Ir.Param = &.{},
    param_toks: []const u32 = &.{},
    locals: std.ArrayList(Ir.Local) = .empty,
    scope: std.ArrayList(ScopeEntry) = .empty,
    /// where the innermost scope starts in `scope`
    scope_start: u32 = 0,
    /// 0 in a function's outermost scope (shared with its parameters)
    depth: u32 = 0,
    loops: u32 = 0,
    ret: Type = .void,
    uses: Ir.Uses = .{},
    calls: std.ArrayList(Ir.Ref) = .empty,
    allow_strings: bool = false,

    fn scopeHas(x: *const Ctx, n: []const u8) bool {
        for (x.scope.items) |e| if (std.mem.eql(u8, e.name, n)) return true;
        return false;
    }
};

fn moduleCtx(c: *Checker, mi: u32) Ctx {
    _ = c;
    return .{ .m = mi };
}

fn addExpr(c: *Checker, mi: u32, t: Type, tok: u32, data: Ir.Expr.Data) Error!ExprId {
    const m = &c.mods[mi];
    const id: ExprId = @fromBackingInt(@intCast(@as(u32, @intCast(m.exprs.items.len))));
    try m.exprs.append(c.a, .{ .type = t, .tok = tok, .data = data });
    return id;
}

fn invalid(c: *Checker, mi: u32, tok: u32) Error!ExprId {
    return c.addExpr(mi, .invalid, tok, .{ .literal = .{ .bool = false } });
}

fn addStmt(c: *Checker, mi: u32, tok: u32, data: Ir.Stmt.Data) Error!StmtId {
    const m = &c.mods[mi];
    const id: StmtId = @fromBackingInt(@intCast(@as(u32, @intCast(m.stmts.items.len))));
    try m.stmts.append(c.a, .{ .tok = tok, .data = data });
    return id;
}

fn extraList(c: *Checker, mi: u32, items: []const u32) Error!Ir.List {
    const m = &c.mods[mi];
    const l: Ir.List = .{ .start = @intCast(m.extra.items.len), .len = @intCast(items.len) };
    try m.extra.appendSlice(c.a, items);
    return l;
}

fn checkBody(c: *Checker, mi: u32, k: u32) Error!void {
    const m = &c.mods[mi];
    const fd = &m.funcs.items[k];
    const d = m.node(fd.node).data.function;
    var x: Ctx = .{ .m = mi, .func = k, .params = fd.params, .ret = fd.ret };
    var toks: std.ArrayList(u32) = .empty;
    for (m.nodeList(d.params)) |praw| try toks.append(c.a, m.node(@fromBackingInt(@intCast(praw))).data.param.name);
    x.param_toks = toks.items;
    var body: StmtId = .none;
    if (d.body != .none) {
        // the parameters and the body's top level share one scope
        body = try c.block(&x, d.body, false);
    }
    const name = m.text(d.name);
    if (std.mem.eql(u8, name, "main") and (fd.ret != .void or fd.params.len != 0))
        try c.report(mi, d.name, .missing_main, "`main` takes nothing and returns `void`", .{});
    const f = &c.mods[mi].funcs.items[k];
    f.f = .{
        .name = name,
        .ret = f.ret,
        .params = f.params,
        .body = body,
        .is_extern = d.is_extern,
        .locals = x.locals.items,
        .tok = d.name,
        .uses = x.uses,
        .calls = x.calls.items,
    };
}

fn declareLocal(c: *Checker, x: *Ctx, name_tok: u32, t: Type, is_const: bool) Error!u32 {
    const m = &c.mods[x.m];
    const name = m.text(name_tok);
    if (isReserved(name)) try c.report(x.m, name_tok, .reserved_name, "`{s}`: names starting with `gl_` or containing `__` are reserved", .{name});
    for (x.scope.items[x.scope_start..]) |e| if (std.mem.eql(u8, e.name, name))
        try c.report(x.m, name_tok, .duplicate_declaration, "`{s}` is already declared in this scope", .{name});
    if (x.depth == 0) for (x.params) |p| if (std.mem.eql(u8, p.name, name))
        try c.report(x.m, name_tok, .duplicate_declaration, "`{s}` is a parameter of this function", .{name});
    const l: u32 = @intCast(x.locals.items.len);
    try x.locals.append(c.a, .{ .name = name, .type = t, .is_const = is_const, .tok = name_tok });
    try x.scope.append(c.a, .{ .name = name, .local = l });
    return l;
}

/// `{ ... }`. With `new_scope` false the block's names go to the current scope (a function
/// body's top level, with the parameters).
fn block(c: *Checker, x: *Ctx, node: Ast.Index, new_scope: bool) Error!StmtId {
    const m = &c.mods[x.m];
    const n = m.node(node);
    const saved_len = x.scope.items.len;
    const saved_start = x.scope_start;
    if (new_scope) {
        x.scope_start = @intCast(x.scope.items.len);
        x.depth += 1;
    }
    defer {
        if (new_scope) {
            x.scope.shrinkRetainingCapacity(saved_len);
            x.scope_start = saved_start;
            x.depth -= 1;
        }
    }
    var out: std.ArrayList(u32) = .empty;
    for (m.nodeList(n.data.block.stmts)) |sraw| try c.stmtInto(x, @fromBackingInt(@intCast(sraw)), &out);
    return c.addStmt(x.m, n.tok, .{ .block = try c.extraList(x.m, out.items) });
}

/// A statement; a declaration of several names gives several `local` statements.
fn stmtInto(c: *Checker, x: *Ctx, node: Ast.Index, out: *std.ArrayList(u32)) Error!void {
    const m = &c.mods[x.m];
    if (m.node(node).data == .var_decl) {
        try c.localDecl(x, node, out);
        return;
    }
    try out.append(c.a, @backingInt(try c.stmt(x, node)));
}

/// A statement that is one IR statement (a declaration becomes a block of them when it
/// stands alone, as an `if`'s body).
fn stmt(c: *Checker, x: *Ctx, node: Ast.Index) Error!StmtId {
    const m = &c.mods[x.m];
    const n = m.node(node);
    switch (n.data) {
        .block => return c.block(x, node, true),
        .var_decl => {
            var out: std.ArrayList(u32) = .empty;
            try c.localDecl(x, node, &out);
            return c.addStmt(x.m, n.tok, .{ .block = try c.extraList(x.m, out.items) });
        },
        .expr_stmt => |d| return c.addStmt(x.m, n.tok, .{ .expr = try c.expr(x, d.expr) }),
        .if_stmt => |d| {
            const cond = try c.condition(x, d.cond);
            const then = try c.scoped(x, d.then);
            const els: StmtId = if (d.@"else" != .none) try c.scoped(x, d.@"else") else .none;
            return c.addStmt(x.m, n.tok, .{ .@"if" = .{ .cond = cond, .then = then, .@"else" = els } });
        },
        .for_stmt => |d| {
            const saved_len = x.scope.items.len;
            const saved_start = x.scope_start;
            x.scope_start = @intCast(x.scope.items.len);
            x.depth += 1;
            defer {
                x.scope.shrinkRetainingCapacity(saved_len);
                x.scope_start = saved_start;
                x.depth -= 1;
            }
            var init: StmtId = .none;
            if (d.init != .none) {
                const in = m.node(d.init);
                if (in.data == .var_decl) {
                    var out: std.ArrayList(u32) = .empty;
                    try c.localDecl(x, d.init, &out);
                    init = if (out.items.len == 1) @fromBackingInt(@intCast(out.items[0])) else try c.addStmt(x.m, in.tok, .{ .block = try c.extraList(x.m, out.items) });
                } else {
                    init = try c.addStmt(x.m, in.tok, .{ .expr = try c.expr(x, in.data.expr_stmt.expr) });
                }
            }
            const cond: ExprId = if (d.cond != .none) try c.condition(x, d.cond) else .none;
            const step: ExprId = if (d.step != .none) try c.expr(x, d.step) else .none;
            x.loops += 1;
            const body = try c.scoped(x, d.body);
            x.loops -= 1;
            return c.addStmt(x.m, n.tok, .{ .@"for" = .{ .init = init, .cond = cond, .step = step, .body = body } });
        },
        .return_stmt => |d| {
            if (x.func == null) unreachable;
            if (d.value == .none) {
                if (x.ret != .void and x.ret != .invalid)
                    try c.report(x.m, n.tok, .bad_return, "this function returns a `{s}`", .{c.tn(x.ret)});
                return c.addStmt(x.m, n.tok, .{ .@"return" = .none });
            }
            const e = try c.expr(x, d.value);
            const t = c.mods[x.m].expr(e).type;
            if (x.ret == .void) {
                try c.report(x.m, n.tok, .bad_return, "this function returns nothing", .{});
            } else if (!c.same(t, x.ret)) {
                try c.report(x.m, m.node(d.value).tok, .bad_return, "this function returns a `{s}`; this is a `{s}`", .{ c.tn(x.ret), c.tn(t) });
            }
            return c.addStmt(x.m, n.tok, .{ .@"return" = e });
        },
        .break_stmt, .continue_stmt => {
            if (x.loops == 0) try c.report(x.m, n.tok, .outside_loop, "`{s}` outside a loop", .{m.text(n.tok)});
            return c.addStmt(x.m, n.tok, if (n.data == .break_stmt) .@"break" else .@"continue");
        },
        .discard_stmt => {
            x.uses.discard = true;
            return c.addStmt(x.m, n.tok, .discard);
        },
        .empty_stmt => return c.addStmt(x.m, n.tok, .{ .block = .{} }),
        .invalid => return c.addStmt(x.m, n.tok, .{ .block = .{} }),
        else => unreachable,
    }
}

/// The body of an `if` or a `for`: its own scope even when it is not a block.
fn scoped(c: *Checker, x: *Ctx, node: Ast.Index) Error!StmtId {
    const saved_len = x.scope.items.len;
    const saved_start = x.scope_start;
    x.scope_start = @intCast(x.scope.items.len);
    x.depth += 1;
    defer {
        x.scope.shrinkRetainingCapacity(saved_len);
        x.scope_start = saved_start;
        x.depth -= 1;
    }
    const m = &c.mods[x.m];
    if (m.node(node).data == .block) return c.block(x, node, false);
    return c.stmt(x, node);
}

fn condition(c: *Checker, x: *Ctx, node: Ast.Index) Error!ExprId {
    const e = try c.expr(x, node);
    const t = c.mods[x.m].expr(e).type;
    if (t != .bool and t != .invalid)
        try c.report(x.m, c.mods[x.m].node(node).tok, .type_mismatch, "a condition is a `bool`; this is a `{s}`", .{c.tn(t)});
    return e;
}

fn localDecl(c: *Checker, x: *Ctx, node: Ast.Index, out: *std.ArrayList(u32)) Error!void {
    const m = &c.mods[x.m];
    const n = m.node(node);
    const d = n.data.var_decl;
    var q = d.quals;
    const is_const = q.@"const";
    q.@"const" = false;
    if (@as(u8, @bitCast(q)) != 0 or d.location != .none)
        try c.reportHint(x.m, n.tok, .misplaced_declaration, "`uniform`, `in`, `out`, `param` and `spec` are module-level declarations", "a local variable takes no qualifier but `const`", .{});
    if (d.meta.len > 0) try c.report(x.m, n.tok, .misplaced_declaration, "metadata is for module-level declarations", .{});
    const base = try c.typeOf(x.m, d.type);
    for (m.nodeList(d.declarators)) |dr| {
        const dd = m.node(@fromBackingInt(@intCast(dr))).data.declarator;
        var t = base;
        if (dd.array_len != .none) t = try c.arrayOf(x.m, base, dd.array_len);
        if (t == .sampler2D) try c.report(x.m, dd.name, .misplaced_declaration, "a sampler is a `uniform` or a parameter, not a local", .{});
        if (t == .void) try c.report(x.m, dd.name, .misplaced_declaration, "a variable cannot be `void`", .{});
        var init: ExprId = .none;
        if (dd.init != .none) {
            init = try c.expr(x, dd.init);
            const it = c.mods[x.m].expr(init).type;
            if (!c.same(it, t))
                try c.report(x.m, m.node(dd.init).tok, .type_mismatch, "`{s}` is a `{s}`; this is a `{s}`", .{ m.text(dd.name), c.tn(t), c.tn(it) })
            else if (is_const and !c.isConst(x.m, init))
                try c.report(x.m, m.node(dd.init).tok, .not_constant, "a `const` is initialised with a constant expression", .{});
        } else if (is_const) {
            try c.report(x.m, dd.name, .bad_initializer, "a `const` needs a value", .{});
        }
        // the name is in scope after its initialiser
        const l = try c.declareLocal(x, dd.name, t, is_const);
        try out.append(c.a, @backingInt(try c.addStmt(x.m, dd.name, .{ .local = .{ .local = l, .init = init } })));
    }
}

// ---------------------------------------------------------------- expressions

/// Types are equal, or one of them failed to check (then nothing more is said).
fn same(c: *Checker, a: Type, b: Type) bool {
    _ = c;
    return a == b or a == .invalid or b == .invalid;
}

fn expr(c: *Checker, x: *Ctx, node: Ast.Index) Error!ExprId {
    const m = &c.mods[x.m];
    const n = m.node(node);
    switch (n.data) {
        .literal => return c.literal(x, n.tok),
        .ident => return c.identifier(x, n.tok),
        .prefix => |d| return c.prefix(x, n.tok, d.operand),
        .postfix => |d| {
            const e = try c.expr(x, d.operand);
            const op: Ir.UnaryOp = if (m.ast.tokens[n.tok].tag == .plus_plus) .post_inc else .post_dec;
            return c.incDec(x, n.tok, op, e);
        },
        .binary => |d| {
            const l = try c.expr(x, d.lhs);
            const r = try c.expr(x, d.rhs);
            const op = binaryOp(m.ast.tokens[n.tok].tag);
            const t = try c.binaryType(x.m, n.tok, op, c.mods[x.m].expr(l).type, c.mods[x.m].expr(r).type);
            return c.addExpr(x.m, t, n.tok, .{ .binary = .{ .op = op, .lhs = l, .rhs = r } });
        },
        .assign => |d| {
            const l = try c.expr(x, d.lhs);
            const r = try c.expr(x, d.rhs);
            const op = assignOp(m.ast.tokens[n.tok].tag);
            const lt = c.mods[x.m].expr(l).type;
            const rt = c.mods[x.m].expr(r).type;
            try c.checkWritable(x, l, n.tok, "assign to");
            if (op == .set) {
                if (!c.same(lt, rt)) {
                    try c.report(x.m, m.node(d.rhs).tok, .type_mismatch, "assigning a `{s}` to a `{s}`", .{ c.tn(rt), c.tn(lt) });
                } else if (lt != .invalid and !c.s.pool.isPlain(lt)) {
                    try c.report(x.m, n.tok, .not_assignable, "a `{s}` cannot be assigned", .{c.tn(lt)});
                }
            } else {
                const t = try c.binaryType(x.m, n.tok, compoundOp(op), lt, rt);
                if (!c.same(t, lt))
                    try c.report(x.m, n.tok, .type_mismatch, "`{s}` of a `{s}` and a `{s}` is a `{s}`, not the `{s}` it is assigned to", .{ m.text(n.tok), c.tn(lt), c.tn(rt), c.tn(t), c.tn(lt) });
            }
            return c.addExpr(x.m, lt, n.tok, .{ .assign = .{ .op = op, .lhs = l, .rhs = r } });
        },
        .ternary => |d| {
            const cond = try c.condition(x, d.cond);
            const a = try c.expr(x, d.then);
            const b = try c.expr(x, d.@"else");
            const at = c.mods[x.m].expr(a).type;
            const bt = c.mods[x.m].expr(b).type;
            var t = if (at == .invalid) bt else at;
            if (!c.same(at, bt)) {
                try c.report(x.m, n.tok, .type_mismatch, "the two sides of `?:` are a `{s}` and a `{s}`", .{ c.tn(at), c.tn(bt) });
                t = .invalid;
            }
            return c.addExpr(x.m, t, n.tok, .{ .ternary = .{ .cond = cond, .then = a, .@"else" = b } });
        },
        .call => |d| return c.call(x, node, d.callee, d.args),
        .index => |d| return c.index(x, n.tok, d.base, d.index),
        .field => |d| return c.field(x, n.tok, d.base),
        .invalid => return c.invalid(x.m, n.tok),
        else => unreachable,
    }
}

fn literal(c: *Checker, x: *Ctx, tok: u32) Error!ExprId {
    const m = &c.mods[x.m];
    const t = m.ast.tokens[tok];
    const text = m.text(tok);
    switch (t.tag) {
        .kw_true => return c.addExpr(x.m, .bool, tok, .{ .literal = .{ .bool = true } }),
        .kw_false => return c.addExpr(x.m, .bool, tok, .{ .literal = .{ .bool = false } }),
        .string_literal => {
            if (!x.allow_strings) {
                try c.report(x.m, tok, .type_mismatch, "a string is only an argument of metadata", .{});
                return c.invalid(x.m, tok);
            }
            return c.addExpr(x.m, .void, tok, .string);
        },
        .int_literal => {
            const unsigned = text[text.len - 1] == 'u' or text[text.len - 1] == 'U';
            const digits = if (unsigned) text[0 .. text.len - 1] else text;
            const v = parseInt(digits) orelse {
                try c.report(x.m, tok, .bad_operands, "`{s}` does not fit in 32 bits", .{text});
                return c.invalid(x.m, tok);
            };
            if (unsigned) return c.addExpr(x.m, .uint, tok, .{ .literal = .{ .uint = v } });
            return c.addExpr(x.m, .int, tok, .{ .literal = .{ .int = @bitCast(v) } });
        },
        .float_literal => {
            const digits = if (text[text.len - 1] == 'f' or text[text.len - 1] == 'F') text[0 .. text.len - 1] else text;
            const v = std.fmt.parseFloat(f32, digits) catch {
                try c.report(x.m, tok, .bad_operands, "`{s}` is not a number BULG can read", .{text});
                return c.invalid(x.m, tok);
            };
            return c.addExpr(x.m, .float, tok, .{ .literal = .{ .float = v } });
        },
        else => unreachable,
    }
}

/// A GLSL integer literal's bit pattern: decimal, hex (`0x`) or octal (a leading `0`).
fn parseInt(digits: []const u8) ?u32 {
    if (digits.len > 2 and digits[0] == '0' and (digits[1] == 'x' or digits[1] == 'X'))
        return std.fmt.parseInt(u32, digits[2..], 16) catch null;
    if (digits.len > 1 and digits[0] == '0')
        return std.fmt.parseInt(u32, digits[1..], 8) catch null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

fn identifier(c: *Checker, x: *Ctx, tok: u32) Error!ExprId {
    const m = &c.mods[x.m];
    const text = m.text(tok);
    // locals, innermost first
    var i = x.scope.items.len;
    while (i > 0) {
        i -= 1;
        const e = x.scope.items[i];
        if (std.mem.eql(u8, e.name, text)) return c.addExpr(x.m, x.locals.items[e.local].type, tok, .{ .local = e.local });
    }
    for (x.params, 0..) |p, k| if (p.name.len > 0 and std.mem.eql(u8, p.name, text))
        return c.addExpr(x.m, p.type, tok, .{ .param = @intCast(k) });
    if (try c.lookup(x.m, text, tok)) |f| switch (f.sym) {
        .ambiguous => return c.invalid(x.m, tok),
        .global => |g| {
            try c.resolveGlobal(f.module, g);
            const gl = c.mods[f.module].globals.items[g];
            if (gl.state != .done) return c.invalid(x.m, tok);
            return c.addExpr(x.m, gl.g.type, tok, .{ .global = .{ .module = f.module, .index = g } });
        },
        .alias => |k| {
            try c.resolveAlias(f.module, k);
            const al = c.mods[f.module].aliases.items[k];
            if (al.state != .done) return c.invalid(x.m, tok);
            // an alias brings what its expression uses
            x.uses = x.uses.merge(c.exprUses(f.module, al.value));
            return c.addExpr(x.m, al.type, tok, .{ .alias = .{ .module = f.module, .index = k } });
        },
        .@"struct" => {
            try c.report(x.m, tok, .not_callable, "`{s}` is a type; `{s}(...)` makes one", .{ text, text });
            return c.invalid(x.m, tok);
        },
        .block => {
            try c.report(x.m, tok, .unknown_name, "`{s}` is a uniform block; its members are names of their own", .{text});
            return c.invalid(x.m, tok);
        },
    };
    if (builtins.variable(text)) |v| {
        x.uses = x.uses.merge(varUses(v));
        return c.addExpr(x.m, builtins.variables[v].type, tok, .{ .builtin_var = v });
    }
    if ((try c.functionsNamed(x.m, text)).len > 0 or builtins.overloads(text).len > 0) {
        try c.report(x.m, tok, .not_callable, "`{s}` is a function; call it", .{text});
        return c.invalid(x.m, tok);
    }
    if (types.builtin_names.get(text) != null) {
        try c.report(x.m, tok, .not_callable, "`{s}` is a type; `{s}(...)` makes one", .{ text, text });
        return c.invalid(x.m, tok);
    }
    try c.report(x.m, tok, .unknown_name, "unknown name `{s}`", .{text});
    return c.invalid(x.m, tok);
}

fn varUses(v: u8) Ir.Uses {
    const n = builtins.variables[v].name;
    var u: Ir.Uses = .{};
    if (std.mem.eql(u8, n, "gl_FragCoord")) u.frag_coord = true;
    if (std.mem.eql(u8, n, "gl_FrontFacing")) u.front_facing = true;
    if (std.mem.eql(u8, n, "gl_PointCoord")) u.point_coord = true;
    if (std.mem.eql(u8, n, "gl_Position")) u.position = true;
    if (std.mem.eql(u8, n, "gl_PointSize")) u.point_size = true;
    if (std.mem.eql(u8, n, "gl_VertexID")) u.vertex_id = true;
    if (std.mem.eql(u8, n, "gl_InstanceID")) u.instance_id = true;
    return u;
}

/// What a module-level expression uses (an alias of `gl_FragCoord.xy`, say).
fn exprUses(c: *Checker, mi: u32, e: ExprId) Ir.Uses {
    if (e == .none) return .{};
    const m = &c.mods[mi];
    const ex = m.expr(e);
    return switch (ex.data) {
        .builtin_var => |v| varUses(v),
        .unary => |d| c.exprUses(mi, d.operand),
        .binary => |d| c.exprUses(mi, d.lhs).merge(c.exprUses(mi, d.rhs)),
        .ternary => |d| c.exprUses(mi, d.cond).merge(c.exprUses(mi, d.then)).merge(c.exprUses(mi, d.@"else")),
        .index => |d| c.exprUses(mi, d.base).merge(c.exprUses(mi, d.index)),
        .swizzle => |d| c.exprUses(mi, d.base),
        .field => |d| c.exprUses(mi, d.base),
        .construct => |l| blk: {
            var u: Ir.Uses = .{};
            for (m.extra.items[l.start..][0..l.len]) |a| u = u.merge(c.exprUses(mi, @fromBackingInt(@intCast(a))));
            break :blk u;
        },
        .builtin_call => |d| blk: {
            var u: Ir.Uses = .{};
            switch (builtins.functions[d.func].kind) {
                .derivative => u.derivatives = true,
                .texture => u.textures = true,
                .pure => {},
            }
            for (m.extra.items[d.args.start..][0..d.args.len]) |a| u = u.merge(c.exprUses(mi, @fromBackingInt(@intCast(a))));
            break :blk u;
        },
        .alias => |r| c.exprUses(r.module, c.mods[r.module].aliases.items[r.index].value),
        else => .{},
    };
}

fn binaryOp(tag: Token.Tag) Ir.BinaryOp {
    return switch (tag) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .rem,
        .shl => .shl,
        .shr => .shr,
        .ampersand => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .ampersand_ampersand => .log_and,
        .pipe_pipe => .log_or,
        .caret_caret => .log_xor,
        .equal_equal => .eq,
        .bang_equal => .ne,
        .less => .lt,
        .greater => .gt,
        .less_equal => .le,
        .greater_equal => .ge,
        else => unreachable,
    };
}

fn assignOp(tag: Token.Tag) Ir.AssignOp {
    return switch (tag) {
        .equal => .set,
        .plus_equal => .add,
        .minus_equal => .sub,
        .star_equal => .mul,
        .slash_equal => .div,
        .percent_equal => .rem,
        .shl_equal => .shl,
        .shr_equal => .shr,
        .ampersand_equal => .bit_and,
        .pipe_equal => .bit_or,
        .caret_equal => .bit_xor,
        else => unreachable,
    };
}

fn compoundOp(op: Ir.AssignOp) Ir.BinaryOp {
    return switch (op) {
        .set => unreachable,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .shl => .shl,
        .shr => .shr,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
    };
}

/// The type of `l op r`, or `invalid` with a diagnostic.
fn binaryType(c: *Checker, mi: u32, tok: u32, op: Ir.BinaryOp, l: Type, r: Type) Error!Type {
    if (l == .invalid or r == .invalid) return .invalid;
    if (binaryResult(op, l, r)) |t| return t;
    try c.report(mi, c.opTok(mi, tok), .bad_operands, "`{s}` does not take a `{s}` and a `{s}`", .{ c.mods[mi].text(tok), c.tn(l), c.tn(r) });
    return .invalid;
}

fn opTok(c: *Checker, mi: u32, tok: u32) u32 {
    _ = c;
    _ = mi;
    return tok;
}

/// GLSL ES 3.00's rules (5.9), without conversions.
pub fn binaryResult(op: Ir.BinaryOp, l: Type, r: Type) ?Type {
    const ls = l.scalarOf() orelse return if ((op == .eq or op == .ne) and l == r and l != .sampler2D and l != .void) .bool else null;
    const rs = r.scalarOf() orelse return null;
    switch (op) {
        .log_and, .log_or, .log_xor => return if (l == .bool and r == .bool) .bool else null,
        .eq, .ne => return if (l == r) .bool else null,
        .lt, .gt, .le, .ge => return if (l == r and l.isScalar() and ls.isNumeric()) .bool else null,
        .add, .sub, .mul, .div => {
            if (ls != rs or !ls.isNumeric()) return null;
            if (l == r) return l; // componentwise (and `*` of two matrices is the product)
            if (l.isScalar()) return r;
            if (r.isScalar()) return l;
            if (op == .mul) {
                // matrix times vector, vector times matrix
                if (l.matrixLen()) |n| if (r.vectorLen() == n) return r;
                if (r.matrixLen()) |n| if (l.vectorLen() == n) return l;
            }
            return null;
        },
        .rem, .bit_and, .bit_or, .bit_xor => {
            if (ls != rs or !ls.isInt() or l.vectorLen() == null or r.vectorLen() == null) return null;
            if (l == r) return l;
            if (l.isScalar()) return r;
            if (r.isScalar()) return l;
            return null;
        },
        .shl, .shr => {
            if (!ls.isInt() or !rs.isInt() or l.vectorLen() == null or r.vectorLen() == null) return null;
            if (r.isScalar() or r.vectorLen() == l.vectorLen()) return l;
            return null;
        },
    }
}

fn prefix(c: *Checker, x: *Ctx, tok: u32, operand: Ast.Index) Error!ExprId {
    const m = &c.mods[x.m];
    const e = try c.expr(x, operand);
    const t = c.mods[x.m].expr(e).type;
    const tag = m.ast.tokens[tok].tag;
    const op: Ir.UnaryOp = switch (tag) {
        .minus => .neg,
        .plus => .plus,
        .bang => .not,
        .tilde => .bit_not,
        .plus_plus => .pre_inc,
        .minus_minus => .pre_dec,
        else => unreachable,
    };
    if (op == .pre_inc or op == .pre_dec) return c.incDec(x, tok, op, e);
    if (t == .invalid) return c.addExpr(x.m, .invalid, tok, .{ .unary = .{ .op = op, .operand = e } });
    const ok = switch (op) {
        .neg, .plus => t.isNumeric(),
        .not => t == .bool,
        .bit_not => t.vectorLen() != null and t.scalarOf().?.isInt(),
        else => unreachable,
    };
    if (!ok) {
        try c.report(x.m, tok, .bad_operands, "`{s}` does not take a `{s}`", .{ m.text(tok), c.tn(t) });
        return c.addExpr(x.m, .invalid, tok, .{ .unary = .{ .op = op, .operand = e } });
    }
    return c.addExpr(x.m, t, tok, .{ .unary = .{ .op = op, .operand = e } });
}

fn incDec(c: *Checker, x: *Ctx, tok: u32, op: Ir.UnaryOp, e: ExprId) Error!ExprId {
    const t = c.mods[x.m].expr(e).type;
    if (t != .invalid and !t.isNumeric()) {
        try c.report(x.m, tok, .bad_operands, "`{s}` does not take a `{s}`", .{ c.mods[x.m].text(tok), c.tn(t) });
        return c.addExpr(x.m, .invalid, tok, .{ .unary = .{ .op = op, .operand = e } });
    }
    try c.checkWritable(x, e, tok, "change");
    return c.addExpr(x.m, t, tok, .{ .unary = .{ .op = op, .operand = e } });
}

/// Why `e` cannot be written, or null if it can.
fn notWritable(c: *Checker, mi: u32, e: ExprId, x_locals: ?[]const Ir.Local, x_params: []const Ir.Param) ?[]const u8 {
    const ex = c.mods[mi].expr(e);
    return switch (ex.data) {
        .local => |l| if (x_locals) |ls| (if (ls[l].is_const) "a `const`" else null) else null,
        .param => |p| if (x_params[p].is_const) "a `const` parameter" else null,
        .global => |r| switch (c.mods[r.module].globals.items[r.index].g.kind) {
            .mutable, .out => null,
            .uniform => "a uniform",
            .in => "an `in` variable",
            .@"const" => "a `const`",
            .param => "a param (the host sets it)",
            .spec => "a spec constant",
        },
        .builtin_var => |v| if (builtins.variables[v].writable) null else "a built-in input",
        .swizzle => |d| blk: {
            for (0..d.len) |i| for (0..i) |j| if (d.comps[i] == d.comps[j]) break :blk "a swizzle with a repeated component";
            break :blk c.notWritable(mi, d.base, x_locals, x_params);
        },
        .index => |d| c.notWritable(mi, d.base, x_locals, x_params),
        .field => |d| c.notWritable(mi, d.base, x_locals, x_params),
        .alias => |r| blk: {
            const al = c.mods[r.module].aliases.items[r.index];
            break :blk c.notWritable(r.module, al.value, null, &.{});
        },
        .literal => if (ex.type == .invalid) null else "a value, not a variable",
        else => "a value, not a variable",
    };
}

fn checkWritable(c: *Checker, x: *Ctx, e: ExprId, tok: u32, comptime verb: []const u8) Error!void {
    if (c.mods[x.m].expr(e).type == .invalid) return;
    const why = c.notWritable(x.m, e, x.locals.items, x.params) orelse return;
    try c.report(x.m, tok, .not_assignable, "cannot " ++ verb ++ " {s}", .{why});
}

fn index(c: *Checker, x: *Ctx, tok: u32, base_node: Ast.Index, index_node: Ast.Index) Error!ExprId {
    const base = try c.expr(x, base_node);
    const ix = try c.expr(x, index_node);
    const bt = c.mods[x.m].expr(base).type;
    const it = c.mods[x.m].expr(ix).type;
    if (bt == .invalid or it == .invalid) return c.addExpr(x.m, .invalid, tok, .{ .index = .{ .base = base, .index = ix } });
    if (it != .int and it != .uint) {
        try c.report(x.m, c.mods[x.m].node(index_node).tok, .bad_index, "an index is an `int` or a `uint`; this is a `{s}`", .{c.tn(it)});
        return c.addExpr(x.m, .invalid, tok, .{ .index = .{ .base = base, .index = ix } });
    }
    var elem: Type = .invalid;
    var len: u32 = 0;
    if (c.s.pool.arrayOf(bt)) |a| {
        elem = a.elem;
        len = a.len;
    } else if (bt.matrixLen()) |n| {
        elem = bt.indexed().?;
        len = n;
    } else if (bt.vectorLen()) |n| {
        if (n > 1) {
            elem = bt.indexed().?;
            len = n;
        }
    }
    if (elem == .invalid) {
        try c.report(x.m, tok, .bad_index, "a `{s}` has no elements to index", .{c.tn(bt)});
        return c.addExpr(x.m, .invalid, tok, .{ .index = .{ .base = base, .index = ix } });
    }
    if (c.evalConst(x.m, ix)) |v| {
        const i: i64 = switch (v) {
            .int => |k| k,
            .uint => |k| k,
            else => 0,
        };
        if (i < 0 or i >= len) try c.report(x.m, c.mods[x.m].node(index_node).tok, .index_out_of_range, "index {d} of a `{s}`", .{ i, c.tn(bt) });
    }
    return c.addExpr(x.m, elem, tok, .{ .index = .{ .base = base, .index = ix } });
}

const swizzle_sets = [_][]const u8{ "xyzw", "rgba", "stpq" };

fn field(c: *Checker, x: *Ctx, tok: u32, base_node: Ast.Index) Error!ExprId {
    const m = &c.mods[x.m];
    const base = try c.expr(x, base_node);
    const bt = c.mods[x.m].expr(base).type;
    const fname = m.text(tok);
    if (bt == .invalid) return c.addExpr(x.m, .invalid, tok, .{ .field = .{ .base = base, .index = 0 } });
    if (c.s.pool.structOf(bt)) |st| {
        for (st.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, fname))
            return c.addExpr(x.m, f.type, tok, .{ .field = .{ .base = base, .index = @intCast(i) } });
        try c.report(x.m, tok, .unknown_field, "`{s}` has no field `{s}`", .{ st.name, fname });
        return c.addExpr(x.m, .invalid, tok, .{ .field = .{ .base = base, .index = 0 } });
    }
    const n = bt.vectorLen() orelse 0;
    if (n < 2) {
        try c.report(x.m, tok, .unknown_field, "a `{s}` has no fields", .{c.tn(bt)});
        return c.addExpr(x.m, .invalid, tok, .{ .field = .{ .base = base, .index = 0 } });
    }
    if (fname.len > 4) {
        try c.report(x.m, tok, .bad_swizzle, "a swizzle has at most 4 letters", .{});
        return c.addExpr(x.m, .invalid, tok, .{ .field = .{ .base = base, .index = 0 } });
    }
    var comps: [4]u2 = .{ 0, 0, 0, 0 };
    var set: ?usize = null;
    for (fname, 0..) |ch, i| {
        var found = false;
        for (swizzle_sets, 0..) |letters, si| if (std.mem.indexOfScalar(u8, letters, ch)) |k| {
            if (set != null and set.? != si) {
                try c.report(x.m, tok, .bad_swizzle, "`{s}` mixes letters of `xyzw`, `rgba` and `stpq`", .{fname});
                return c.addExpr(x.m, .invalid, tok, .{ .field = .{ .base = base, .index = 0 } });
            }
            set = si;
            if (k >= n) {
                try c.report(x.m, tok, .bad_swizzle, "a `{s}` has no `{c}`", .{ c.tn(bt), ch });
                return c.addExpr(x.m, .invalid, tok, .{ .field = .{ .base = base, .index = 0 } });
            }
            comps[i] = @intCast(k);
            found = true;
            break;
        };
        if (!found) {
            try c.report(x.m, tok, .bad_swizzle, "`{c}` is not a component (`xyzw`, `rgba`, `stpq`)", .{ch});
            return c.addExpr(x.m, .invalid, tok, .{ .field = .{ .base = base, .index = 0 } });
        }
    }
    const t = Type.vector(bt.scalarOf().?, @intCast(fname.len));
    return c.addExpr(x.m, t, tok, .{ .swizzle = .{ .base = base, .comps = comps, .len = @intCast(fname.len) } });
}

fn call(c: *Checker, x: *Ctx, node: Ast.Index, callee: Ast.Index, args_r: Ast.Range) Error!ExprId {
    const m = &c.mods[x.m];
    const cn = m.node(callee);
    const tok = m.node(node).tok;

    // `a.length()`
    if (cn.data == .field and std.mem.eql(u8, m.text(cn.tok), "length")) {
        const base = try c.expr(x, cn.data.field.base);
        const bt = c.mods[x.m].expr(base).type;
        if (bt == .invalid) return c.invalid(x.m, tok);
        if (c.s.pool.arrayOf(bt)) |a| {
            if (args_r.len != 0) try c.report(x.m, cn.tok, .bad_operands, "`length()` takes no arguments", .{});
            return c.addExpr(x.m, .int, cn.tok, .{ .array_length = .{ .base = base, .len = a.len } });
        }
        try c.report(x.m, cn.tok, .not_callable, "`length()` is for arrays; of a vector, `length(v)` is its length", .{});
        return c.invalid(x.m, tok);
    }

    // the arguments
    var args: std.ArrayList(u32) = .empty;
    var arg_types: std.ArrayList(Type) = .empty;
    var any_invalid = false;
    for (m.nodeList(args_r)) |araw| {
        const e = try c.expr(x, @fromBackingInt(@intCast(araw)));
        const t = c.mods[x.m].expr(e).type;
        if (t == .invalid) any_invalid = true;
        try args.append(c.a, @backingInt(e));
        try arg_types.append(c.a, t);
    }

    // constructors: `vec3(...)`, `Hit(...)`, `float[9](...)`
    var ctor: ?Type = null;
    if (cn.data == .ident) {
        const text = m.text(cn.tok);
        if (types.builtin_names.get(text)) |b| {
            ctor = b;
        } else if (x.scopeHas(text) == false and !paramNamed(x.params, text)) {
            if (try c.lookup(x.m, text, cn.tok)) |f| switch (f.sym) {
                .@"struct" => |k| ctor = try c.structType(f.module, k),
                else => {},
            };
        }
    } else if (cn.data == .index) {
        const bn = m.node(cn.data.index.base);
        if (bn.data == .ident) {
            const text = m.text(bn.tok);
            var elem: ?Type = types.builtin_names.get(text);
            if (elem == null) if (try c.lookup(x.m, text, bn.tok)) |f| switch (f.sym) {
                .@"struct" => |k| {
                    elem = try c.structType(f.module, k);
                },
                else => {},
            };
            if (elem) |e| ctor = try c.arrayOf(x.m, e, cn.data.index.index);
        }
    }
    if (ctor) |t| {
        if (t == .invalid or any_invalid) return c.addExpr(x.m, .invalid, tok, .{ .construct = try c.extraList(x.m, args.items) });
        const ok = try c.checkConstructor(x.m, tok, t, arg_types.items);
        return c.addExpr(x.m, if (ok) t else .invalid, tok, .{ .construct = try c.extraList(x.m, args.items) });
    }

    if (cn.data != .ident) {
        try c.report(x.m, cn.tok, .not_callable, "this cannot be called", .{});
        return c.invalid(x.m, tok);
    }
    const fname = m.text(cn.tok);
    if (any_invalid) return c.invalid(x.m, tok);

    // user functions
    const users = try c.functionsNamed(x.m, fname);
    if (users.len > 0) {
        for (users) |r| try c.resolveSignature(r.module, r.index);
        for (users) |r| {
            const fd = c.mods[r.module].funcs.items[r.index];
            if (fd.params.len != arg_types.items.len) continue;
            const match = for (fd.params, arg_types.items) |p, at| {
                if (p.type != at) break false;
            } else true;
            if (!match) continue;
            for (fd.params, args.items) |p, a| if (p.dir != .in)
                try c.checkWritable(x, @fromBackingInt(@intCast(a)), c.mods[x.m].expr(@fromBackingInt(@intCast(a))).tok, "pass as `out` or `inout`");
            const tr = c.callTarget(r);
            try x.calls.append(c.a, tr);
            return c.addExpr(x.m, fd.ret, tok, .{ .call = .{ .callee = tr, .args = try c.extraList(x.m, args.items) } });
        }
        try c.report(x.m, cn.tok, .no_overload, "no `{s}` takes {s}", .{ fname, c.typeList(arg_types.items) });
        return c.invalid(x.m, tok);
    }

    // built-in functions
    if (builtins.overloads(fname).len > 0) {
        if (builtins.find(fname, arg_types.items)) |f| {
            const fi: u16 = @intCast(f - &builtins.functions[0]);
            for (0..f.params.len) |k| if (f.out_mask & (@as(u8, 1) << @intCast(k)) != 0)
                try c.checkWritable(x, @fromBackingInt(@intCast(args.items[k])), c.mods[x.m].expr(@fromBackingInt(@intCast(args.items[k]))).tok, "pass as `out`");
            switch (f.kind) {
                .derivative => x.uses.derivatives = true,
                .texture => x.uses.textures = true,
                .pure => {},
            }
            return c.addExpr(x.m, f.ret, tok, .{ .builtin_call = .{ .func = fi, .args = try c.extraList(x.m, args.items) } });
        }
        try c.report(x.m, cn.tok, .no_overload, "no `{s}` takes {s}", .{ fname, c.typeList(arg_types.items) });
        return c.invalid(x.m, tok);
    }

    try c.report(x.m, cn.tok, .unknown_name, "unknown function `{s}`", .{fname});
    return c.invalid(x.m, tok);
}

fn paramNamed(ps: []const Ir.Param, n: []const u8) bool {
    for (ps) |p| if (std.mem.eql(u8, p.name, n)) return true;
    return false;
}

fn checkConstructor(c: *Checker, mi: u32, tok: u32, t: Type, args: []const Type) Error!bool {
    const pool = &c.s.pool;
    const tname = c.tn(t);
    if (args.len == 0) {
        try c.report(mi, tok, .bad_constructor, "`{s}(...)` needs arguments", .{tname});
        return false;
    }
    if (pool.arrayOf(t)) |a| {
        if (args.len != a.len) {
            try c.report(mi, tok, .bad_constructor, "a `{s}` has {d} elements; {d} given", .{ tname, a.len, args.len });
            return false;
        }
        for (args) |at| if (at != a.elem) {
            try c.report(mi, tok, .bad_constructor, "the elements of a `{s}` are `{s}`; one is a `{s}`", .{ tname, c.tn(a.elem), c.tn(at) });
            return false;
        };
        return true;
    }
    if (pool.structOf(t)) |st| {
        if (args.len != st.fields.len) {
            try c.report(mi, tok, .bad_constructor, "`{s}` has {d} fields; {d} given", .{ tname, st.fields.len, args.len });
            return false;
        }
        for (st.fields, args) |f, at| if (f.type != at) {
            try c.report(mi, tok, .bad_constructor, "`{s}.{s}` is a `{s}`; given a `{s}`", .{ tname, f.name, c.tn(f.type), c.tn(at) });
            return false;
        };
        return true;
    }
    if (t == .sampler2D or t == .void) {
        try c.report(mi, tok, .bad_constructor, "there is no `{s}` constructor", .{tname});
        return false;
    }
    // scalars, vectors, matrices: their arguments are scalars, vectors and matrices
    for (args) |at| if (at.components() == null) {
        try c.report(mi, tok, .bad_constructor, "a `{s}` is made of numbers, vectors and matrices, not a `{s}`", .{ tname, c.tn(at) });
        return false;
    };
    if (t.isScalar()) {
        if (args.len != 1) {
            try c.report(mi, tok, .bad_constructor, "`{s}(...)` takes one argument", .{tname});
            return false;
        }
        return true;
    }
    const need = t.components().?;
    if (args.len == 1 and args[0].isScalar()) return true; // fill, or a diagonal matrix
    if (t.matrixLen() != null and args.len == 1 and args[0].matrixLen() != null) return true; // resize
    if (t.matrixLen() != null) for (args) |at| if (at.matrixLen() != null) {
        try c.report(mi, tok, .bad_constructor, "a matrix is made from one matrix, or from numbers and vectors", .{});
        return false;
    };
    var have: u32 = 0;
    for (args, 0..) |at, i| {
        if (have >= need) {
            try c.report(mi, tok, .bad_constructor, "`{s}(...)` has more arguments than it uses (argument {d})", .{ tname, i + 1 });
            return false;
        }
        have += at.components().?;
    }
    if (have < need) {
        try c.report(mi, tok, .bad_constructor, "a `{s}` has {d} components; these arguments have {d}", .{ tname, need, have });
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- constants

/// Whether `e` is a constant expression (GLSL ES 3.00, 4.3.3): literals, constants,
/// spec constants, and constructors, operators and built-in functions of them.
fn isConst(c: *Checker, mi: u32, e: ExprId) bool {
    const m = &c.mods[mi];
    const ex = m.expr(e);
    if (ex.type == .invalid) return true;
    return switch (ex.data) {
        .literal, .string, .array_length => true,
        .global => |r| blk: {
            const g = c.mods[r.module].globals.items[r.index];
            break :blk g.state == .done and (g.g.kind == .@"const" or g.g.kind == .spec);
        },
        .alias => |r| c.isConst(r.module, c.mods[r.module].aliases.items[r.index].value),
        .construct => |l| for (m.extra.items[l.start..][0..l.len]) |a| {
            if (!c.isConst(mi, @fromBackingInt(@intCast(a)))) break false;
        } else true,
        .builtin_call => |d| builtins.functions[d.func].kind == .pure and builtins.functions[d.func].out_mask == 0 and for (m.extra.items[d.args.start..][0..d.args.len]) |a| {
            if (!c.isConst(mi, @fromBackingInt(@intCast(a)))) break false;
        } else true,
        .unary => |d| switch (d.op) {
            .neg, .plus, .not, .bit_not => c.isConst(mi, d.operand),
            else => false,
        },
        .binary => |d| c.isConst(mi, d.lhs) and c.isConst(mi, d.rhs),
        .ternary => |d| c.isConst(mi, d.cond) and c.isConst(mi, d.then) and c.isConst(mi, d.@"else"),
        .index => |d| c.isConst(mi, d.base) and c.isConst(mi, d.index),
        .swizzle => |d| c.isConst(mi, d.base),
        .field => |d| c.isConst(mi, d.base),
        else => false,
    };
}

/// The value of a scalar constant expression, when it is one BULG can compute now (spec
/// constants are not: their value is the variant's).
pub fn evalConst(c: *Checker, mi: u32, e: ExprId) ?Ir.Const {
    const m = &c.mods[mi];
    const ex = m.expr(e);
    return switch (ex.data) {
        .literal => |v| if (ex.type == .invalid) null else v,
        .global => |r| blk: {
            const g = c.mods[r.module].globals.items[r.index];
            if (g.state != .done or g.g.kind != .@"const" or g.g.init == .none) break :blk null;
            break :blk c.evalConst(r.module, g.g.init);
        },
        .alias => |r| c.evalConst(r.module, c.mods[r.module].aliases.items[r.index].value),
        .array_length => |d| .{ .int = @intCast(d.len) },
        .unary => |d| blk: {
            const v = c.evalConst(mi, d.operand) orelse break :blk null;
            break :blk switch (d.op) {
                .plus => v,
                .neg => switch (v) {
                    .int => |i| .{ .int = -%i },
                    .uint => |u| .{ .uint = 0 -% u },
                    .float => |f| .{ .float = -f },
                    .bool => null,
                },
                .not => if (v == .bool) .{ .bool = !v.bool } else null,
                .bit_not => switch (v) {
                    .int => |i| .{ .int = ~i },
                    .uint => |u| .{ .uint = ~u },
                    else => null,
                },
                else => null,
            };
        },
        .binary => |d| blk: {
            const l = c.evalConst(mi, d.lhs) orelse break :blk null;
            const r = c.evalConst(mi, d.rhs) orelse break :blk null;
            break :blk foldBinary(d.op, l, r);
        },
        .ternary => |d| blk: {
            const cond = c.evalConst(mi, d.cond) orelse break :blk null;
            if (cond != .bool) break :blk null;
            break :blk c.evalConst(mi, if (cond.bool) d.then else d.@"else");
        },
        .construct => |l| blk: {
            if (!ex.type.isScalar() or l.len != 1) break :blk null;
            const v = c.evalConst(mi, @fromBackingInt(@intCast(m.extra.items[l.start]))) orelse break :blk null;
            break :blk convert(v, ex.type.scalarOf().?);
        },
        else => null,
    };
}

fn convert(v: Ir.Const, to: Scalar) ?Ir.Const {
    const f: f64 = switch (v) {
        .bool => |b| @floatFromInt(@intFromBool(b)),
        .int => |i| @floatFromInt(i),
        .uint => |u| @floatFromInt(u),
        .float => |x| x,
    };
    return switch (to) {
        .bool => .{ .bool = f != 0 },
        .int => switch (v) {
            .uint => |u| .{ .int = @bitCast(u) },
            else => if (std.math.isFinite(f) and @abs(f) < 2147483648.0) .{ .int = @intFromFloat(f) } else null,
        },
        .uint => switch (v) {
            .int => |i| .{ .uint = @bitCast(i) },
            else => if (std.math.isFinite(f) and f >= 0 and f < 4294967296.0) .{ .uint = @intFromFloat(f) } else null,
        },
        .float, .half => .{ .float = @floatCast(f) },
    };
}

fn foldBinary(op: Ir.BinaryOp, l: Ir.Const, r: Ir.Const) ?Ir.Const {
    switch (l) {
        .int => |a| {
            if (r != .int) {
                if ((op == .shl or op == .shr) and r == .uint) return foldBinary(op, l, .{ .int = @bitCast(r.uint) });
                return null;
            }
            const b = r.int;
            return switch (op) {
                .add => .{ .int = a +% b },
                .sub => .{ .int = a -% b },
                .mul => .{ .int = a *% b },
                .div => if (b == 0 or (a == std.math.minInt(i32) and b == -1)) null else .{ .int = @divTrunc(a, b) },
                .rem => if (b <= 0 or a < 0) null else .{ .int = @rem(a, b) },
                .shl => if (b < 0 or b > 31) null else .{ .int = a << @intCast(b) },
                .shr => if (b < 0 or b > 31) null else .{ .int = a >> @intCast(b) },
                .bit_and => .{ .int = a & b },
                .bit_or => .{ .int = a | b },
                .bit_xor => .{ .int = a ^ b },
                .eq => .{ .bool = a == b },
                .ne => .{ .bool = a != b },
                .lt => .{ .bool = a < b },
                .gt => .{ .bool = a > b },
                .le => .{ .bool = a <= b },
                .ge => .{ .bool = a >= b },
                else => null,
            };
        },
        .uint => |a| {
            if (r != .uint) {
                if ((op == .shl or op == .shr) and r == .int) return foldBinary(op, l, .{ .uint = @bitCast(r.int) });
                return null;
            }
            const b = r.uint;
            return switch (op) {
                .add => .{ .uint = a +% b },
                .sub => .{ .uint = a -% b },
                .mul => .{ .uint = a *% b },
                .div => if (b == 0) null else .{ .uint = a / b },
                .rem => if (b == 0) null else .{ .uint = a % b },
                .shl => if (b > 31) null else .{ .uint = a << @intCast(b) },
                .shr => if (b > 31) null else .{ .uint = a >> @intCast(b) },
                .bit_and => .{ .uint = a & b },
                .bit_or => .{ .uint = a | b },
                .bit_xor => .{ .uint = a ^ b },
                .eq => .{ .bool = a == b },
                .ne => .{ .bool = a != b },
                .lt => .{ .bool = a < b },
                .gt => .{ .bool = a > b },
                .le => .{ .bool = a <= b },
                .ge => .{ .bool = a >= b },
                else => null,
            };
        },
        .float => |a| {
            if (r != .float) return null;
            const b = r.float;
            return switch (op) {
                .add => .{ .float = a + b },
                .sub => .{ .float = a - b },
                .mul => .{ .float = a * b },
                .div => .{ .float = a / b },
                .eq => .{ .bool = a == b },
                .ne => .{ .bool = a != b },
                .lt => .{ .bool = a < b },
                .gt => .{ .bool = a > b },
                .le => .{ .bool = a <= b },
                .ge => .{ .bool = a >= b },
                else => null,
            };
        },
        .bool => |a| {
            if (r != .bool) return null;
            const b = r.bool;
            return switch (op) {
                .log_and => .{ .bool = a and b },
                .log_or => .{ .bool = a or b },
                .log_xor => .{ .bool = a != b },
                .eq => .{ .bool = a == b },
                .ne => .{ .bool = a != b },
                else => null,
            };
        },
    }
}

// ---------------------------------------------------------------- 4. recursion

fn checkRecursion(c: *Checker) Error!void {
    // colours: 0 unvisited, 1 on the path, 2 done
    var colour = try c.a.alloc([]u8, c.mods.len);
    for (c.mods, 0..) |m, i| {
        colour[i] = try c.a.alloc(u8, m.funcs.items.len);
        @memset(colour[i], 0);
    }
    var path: std.ArrayList(Ir.Ref) = .empty;
    for (c.mods, 0..) |m, i| for (0..m.funcs.items.len) |k| {
        if (colour[i][k] == 0) try c.visit(colour, &path, .{ .module = @intCast(i), .index = @intCast(k) });
    };
}

fn visit(c: *Checker, colour: [][]u8, path: *std.ArrayList(Ir.Ref), r: Ir.Ref) Error!void {
    colour[r.module][r.index] = 1;
    try path.append(c.a, r);
    const f = c.mods[r.module].funcs.items[r.index].f;
    for (f.calls) |callee| {
        switch (colour[callee.module][callee.index]) {
            0 => try c.visit(colour, path, callee),
            1 => {
                // the cycle is the path from callee to here
                const start = for (path.items, 0..) |p, i| {
                    if (p.module == callee.module and p.index == callee.index) break i;
                } else 0;
                var names: std.Io.Writer.Allocating = .init(c.a);
                for (path.items[start..]) |p| {
                    names.writer.print("`{s}` calls ", .{c.mods[p.module].funcs.items[p.index].f.name}) catch return error.OutOfMemory;
                }
                names.writer.print("`{s}`", .{c.mods[callee.module].funcs.items[callee.index].f.name}) catch return error.OutOfMemory;
                const cf = c.mods[callee.module].funcs.items[callee.index].f;
                try c.report(callee.module, cf.tok, .recursion, "recursion: {s}", .{names.written()});
            },
            else => {},
        }
    }
    _ = path.pop();
    colour[r.module][r.index] = 2;
}

// ---------------------------------------------------------------- the modules

fn finishModules(c: *Checker) Error!void {
    var out = try c.a.alloc(Ir.Module, c.mods.len);
    for (c.mods, 0..) |*m, i| {
        const globals = try c.a.alloc(Ir.Global, m.globals.items.len);
        for (m.globals.items, globals) |g, *o| o.* = g.g;
        const funcs = try c.a.alloc(Ir.Function, m.funcs.items.len);
        for (m.funcs.items, funcs) |f, *o| o.* = f.f;
        const aliases = try c.a.alloc(Ir.Alias, m.aliases.items.len);
        for (m.aliases.items, aliases) |al, *o| o.* = .{ .name = m.text(m.node(al.node).data.alias.name), .value = al.value, .tok = m.node(al.node).data.alias.name };
        const structs = try c.a.alloc(Type, m.structs.items.len);
        const struct_toks = try c.a.alloc(u32, m.structs.items.len);
        for (m.structs.items, structs, struct_toks) |sd, *o, *t| {
            o.* = sd.type;
            t.* = m.node(sd.node).data.struct_decl.name;
        }
        const blocks = try c.a.alloc(Ir.Block, m.blocks.items.len);
        for (m.blocks.items, blocks) |b, *o| {
            const offsets = try c.a.alloc(u32, b.members.len);
            var off: u32 = 0;
            for (b.members, offsets) |g, *po| {
                const l = types.std140(&c.s.pool, m.globals.items[g].g.type);
                off = std.mem.alignForward(u32, off, l.alignment);
                po.* = off;
                off += l.size;
            }
            const bd = m.node(b.node).data.uniform_block;
            o.* = .{ .name = m.text(bd.name), .members = b.members, .offsets = offsets, .size = std.mem.alignForward(u32, off, 16), .tok = bd.name };
        }
        out[i] = .{
            .name = m.name,
            .src = m.src,
            .globals = globals,
            .functions = funcs,
            .aliases = aliases,
            .blocks = blocks,
            .structs = structs,
            .struct_toks = struct_toks,
            .exprs = m.exprs.items,
            .stmts = m.stmts.items,
            .extra = m.extra.items,
        };
    }
    c.s.modules = out;
}

// ---------------------------------------------------------------- 5. programs

const ProgDecl = struct {
    module: u32,
    node: Ast.Index,
    state: State = .todo,
    /// an ancestor is missing or the family is a cycle (reported once, where found)
    broken: bool = false,
    /// resolved: parent's items, then its own
    vertex: ?Item = null,
    fragment: ?Item = null,
    links: std.ArrayList(Item) = .empty,
    specs: std.ArrayList(SpecItem) = .empty,
};

/// A module named in a program, and where (for messages).
const Item = struct { module: u32, path: []const u8, where: u32, decl_module: u32 };
const SpecItem = struct { name: []const u8, value: Ast.Index, tok: u32, decl_module: u32 };

fn linkPrograms(c: *Checker) Error!void {
    var decls: std.ArrayList(ProgDecl) = .empty;
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    for (c.mods, 0..) |m, mi| for (m.programs.items) |p| {
        const d = m.node(p).data.program;
        const pname = m.text(d.name);
        const gop = try by_name.getOrPut(c.a, pname);
        if (gop.found_existing) {
            try c.report(@intCast(mi), d.name, .duplicate_declaration, "program `{s}` is declared twice", .{pname});
            continue;
        }
        gop.value_ptr.* = @intCast(decls.items.len);
        try decls.append(c.a, .{ .module = @intCast(mi), .node = p });
    };
    var programs: std.ArrayList(Ir.Program) = .empty;
    for (decls.items, 0..) |_, i| {
        try c.resolveProgram(decls.items, &by_name, @intCast(i));
        const pd = &decls.items[i];
        const m = &c.mods[pd.module];
        const d = m.node(pd.node).data.program;
        var prog: Ir.Program = .{
            .name = m.text(d.name),
            .module = pd.module,
            .tok = d.name,
            .is_template = d.is_template,
            .vertex = null,
            .fragment = null,
            .specs = &.{},
        };
        if (!d.is_template and pd.state == .done and !pd.broken) {
            if (pd.vertex == null or pd.fragment == null) {
                try c.report(pd.module, d.name, .bad_program, "program `{s}` needs a `vertex` and a `fragment` module", .{prog.name});
            } else {
                prog.vertex = try c.buildStage(pd, &prog, .vertex, pd.vertex.?);
                prog.fragment = try c.buildStage(pd, &prog, .fragment, pd.fragment.?);
                prog.specs = try c.specValues(pd, prog);
            }
        }
        try programs.append(c.a, prog);
    }
    c.s.programs = programs.items;
}

fn resolveProgram(c: *Checker, decls: []ProgDecl, by_name: *std.StringHashMapUnmanaged(u32), i: u32) Error!void {
    const pd = &decls[i];
    const m = &c.mods[pd.module];
    const d = m.node(pd.node).data.program;
    switch (pd.state) {
        .done => return,
        .busy => {
            try c.report(pd.module, d.name, .bad_program, "program `{s}` is its own ancestor", .{m.text(d.name)});
            pd.broken = true;
            return;
        },
        .todo => {},
    }
    pd.state = .busy;
    if (d.parent != 0) {
        const pname = m.text(d.parent);
        if (by_name.get(pname)) |pi| {
            try c.resolveProgram(decls, by_name, pi);
            const parent = &decls[pi];
            if (parent.broken or parent.state != .done) {
                decls[i].broken = true;
                decls[i].state = .done;
                return;
            }
            const self = &decls[i];
            self.vertex = parent.vertex;
            self.fragment = parent.fragment;
            try self.links.appendSlice(c.a, parent.links.items);
            try self.specs.appendSlice(c.a, parent.specs.items);
        } else {
            try c.report(pd.module, d.parent, .bad_program, "no program `{s}`", .{pname});
            decls[i].broken = true;
        }
    }
    const self = &decls[i];
    for (m.nodeList(d.items)) |it| {
        const pi = m.node(@fromBackingInt(@intCast(it))).data.program_item;
        switch (pi.kind) {
            .spec => {
                const sname = m.text(pi.name);
                const item: SpecItem = .{ .name = sname, .value = pi.value, .tok = pi.name, .decl_module = self.module };
                var replaced = false;
                for (self.specs.items) |*sp| if (std.mem.eql(u8, sp.name, sname)) {
                    sp.* = item;
                    replaced = true;
                };
                if (!replaced) try self.specs.append(c.a, item);
            },
            .vertex, .fragment, .link => {
                const path = stripQuotes(m.text(pi.name));
                const target_m = c.s.findModule(path) orelse {
                    try c.report(self.module, pi.name, .unknown_module, "no module `{s}` in this session", .{path});
                    continue;
                };
                const item: Item = .{ .module = target_m, .path = path, .where = pi.name, .decl_module = self.module };
                switch (pi.kind) {
                    .vertex => self.vertex = item,
                    .fragment => self.fragment = item,
                    else => try self.links.append(c.a, item),
                }
            },
        }
    }
    self.state = .done;
}

/// Adds `mi` and everything it imports to `set` (once each).
fn addWithImports(c: *Checker, set: *std.ArrayList(u32), mi: u32) Error!void {
    for (set.items) |x| if (x == mi) return;
    try set.append(c.a, mi);
    for (c.mods[mi].imports.items) |imp| if (imp.module != std.math.maxInt(u32)) try c.addWithImports(set, imp.module);
}

fn buildStage(c: *Checker, pd: *const ProgDecl, prog: *const Ir.Program, stage: Ir.Stage, entry: Item) Error!?Ir.StageInfo {
    var mods: std.ArrayList(u32) = .empty;
    try c.addWithImports(&mods, entry.module);
    for (pd.links.items) |l| try c.addWithImports(&mods, l.module);
    try c.addWithImports(&mods, pd.module);

    // main, in the entry module
    const em = &c.mods[entry.module];
    const main: Ir.Ref = blk: {
        if (em.funcs_by_name.get("main")) |l| for (l.items) |f| {
            const fd = em.funcs.items[f];
            if (fd.params.len == 0 and fd.f.body != .none) break :blk .{ .module = entry.module, .index = f };
        };
        try c.report(entry.decl_module, entry.where, .missing_main, "module `{s}` has no `void main()` for the {s} stage of `{s}`", .{ entry.path, @tagName(stage), prog.name });
        return null;
    };

    // what main reaches, with every extern filled
    var order: std.ArrayList(Ir.Ref) = .empty;
    var externs: std.ArrayList(Ir.Extern) = .empty;
    var state: std.AutoHashMapUnmanaged(Ir.Ref, State) = .empty;
    var uses: Ir.Uses = .{};
    var why: std.AutoHashMapUnmanaged(Ir.Ref, Ir.Ref) = .empty; // what a function's first caller was
    var ok = true;
    try c.reach(&mods, main, &order, &externs, &state, &uses, &why, pd, prog, stage, &ok);

    // what the stage may use
    const fragment_only = Ir.Uses{ .discard = true, .derivatives = true, .frag_coord = true, .front_facing = true, .point_coord = true };
    const vertex_only = Ir.Uses{ .position = true, .point_size = true, .vertex_id = true, .instance_id = true };
    const wrong: u16 = @as(u16, @bitCast(uses)) & @as(u16, @bitCast(if (stage == .vertex) fragment_only else vertex_only));
    if (wrong != 0) {
        for (use_names) |un| {
            if (wrong & @as(u16, @bitCast(un[0])) != 0)
                try c.report(pd.module, prog.tok, .wrong_stage, "the {s} stage of `{s}` uses {s}, which only a {s} stage has", .{ @tagName(stage), prog.name, un[1], if (stage == .vertex) "fragment" else "vertex" });
        }
    }
    if (!ok) return null;
    return .{
        .entry = entry.module,
        .main = main,
        .modules = mods.items,
        .externs = externs.items,
        .functions = order.items,
        .uses = uses,
    };
}

const use_names = [_]struct { Ir.Uses, []const u8 }{
    .{ .{ .discard = true }, "`discard`" },
    .{ .{ .derivatives = true }, "derivatives" },
    .{ .{ .frag_coord = true }, "`gl_FragCoord`" },
    .{ .{ .front_facing = true }, "`gl_FrontFacing`" },
    .{ .{ .point_coord = true }, "`gl_PointCoord`" },
    .{ .{ .position = true }, "`gl_Position`" },
    .{ .{ .point_size = true }, "`gl_PointSize`" },
    .{ .{ .vertex_id = true }, "`gl_VertexID`" },
    .{ .{ .instance_id = true }, "`gl_InstanceID`" },
};

fn reach(
    c: *Checker,
    mods: *std.ArrayList(u32),
    r: Ir.Ref,
    order: *std.ArrayList(Ir.Ref),
    externs: anytype,
    state: *std.AutoHashMapUnmanaged(Ir.Ref, State),
    uses: *Ir.Uses,
    why: *std.AutoHashMapUnmanaged(Ir.Ref, Ir.Ref),
    pd: *const ProgDecl,
    prog: *const Ir.Program,
    stage: Ir.Stage,
    ok: *bool,
) Error!void {
    if (state.get(r)) |st| {
        if (st == .busy) {
            // a cycle through an extern (direct cycles were reported already)
            const f = c.mods[r.module].funcs.items[r.index].f;
            try c.report(pd.module, prog.tok, .recursion, "the {s} stage of `{s}` recurses through `{s}`", .{ @tagName(stage), prog.name, f.name });
            ok.* = false;
        }
        return;
    }
    try state.put(c.a, r, .busy);
    const f = c.mods[r.module].funcs.items[r.index].f;
    uses.* = uses.merge(f.uses);
    for (f.calls) |callee| {
        var to = callee;
        const cf = c.mods[callee.module].funcs.items[callee.index];
        if (cf.f.is_extern) {
            // the one definition in the stage's modules
            var fill: ?Ir.Ref = null;
            var count: u32 = 0;
            for (mods.items) |mi| {
                if (c.mods[mi].funcs_by_name.get(cf.f.name)) |l| for (l.items) |k| {
                    const cand = c.mods[mi].funcs.items[k];
                    if (cand.f.is_extern or cand.f.body == .none) continue;
                    if (!sameParams(cand.params, cf.params) or cand.ret != cf.ret) continue;
                    if (fill == null) fill = .{ .module = mi, .index = k };
                    count += 1;
                };
            }
            if (count != 1) {
                try c.report(pd.module, prog.tok, .unresolved_extern, "the {s} stage of `{s}`: {s} module defines `extern {s}{s}`", .{ @tagName(stage), prog.name, if (count == 0) "no" else "more than one", cf.f.name, c.paramList(cf.params) });
                ok.* = false;
                continue;
            }
            var seen = false;
            for (externs.items) |e| if (e.hole.module == callee.module and e.hole.index == callee.index) {
                seen = true;
            };
            if (!seen) try externs.append(c.a, .{ .hole = callee, .fill = fill.? });
            to = fill.?;
        }
        if (!why.contains(to)) try why.put(c.a, to, r);
        try c.reach(mods, to, order, externs, state, uses, why, pd, prog, stage, ok);
    }
    // what its globals' aliases use was merged when it was checked
    try state.put(c.a, r, .done);
    try order.append(c.a, r);
}

fn specValues(c: *Checker, pd: *const ProgDecl, prog: Ir.Program) Error![]const Ir.SpecValue {
    var out: std.ArrayList(Ir.SpecValue) = .empty;
    for (pd.specs.items) |sp| {
        // the spec constant, in either stage's modules
        var found: ?Ir.Ref = null;
        for ([_]?Ir.StageInfo{ prog.vertex, prog.fragment }) |st| if (st) |stage| for (stage.modules) |mi| {
            if (c.mods[mi].scope.get(sp.name)) |sym| if (sym == .global) {
                const g = c.mods[mi].globals.items[sym.global];
                if (g.state == .done and g.g.kind == .spec) found = .{ .module = mi, .index = sym.global };
            };
        };
        const spec = found orelse {
            try c.report(sp.decl_module, sp.tok, .unknown_spec, "no spec constant `{s}` in the modules of `{s}`", .{ sp.name, prog.name });
            continue;
        };
        var x = c.moduleCtx(sp.decl_module);
        const e = try c.expr(&x, sp.value);
        const t = c.mods[sp.decl_module].expr(e).type;
        const want = c.mods[spec.module].globals.items[spec.index].g.type;
        if (!c.same(t, want)) {
            try c.report(sp.decl_module, sp.tok, .type_mismatch, "`{s}` is a `{s}`; this is a `{s}`", .{ sp.name, c.tn(want), c.tn(t) });
            continue;
        }
        const v = c.evalConst(sp.decl_module, e) orelse {
            if (t != .invalid) try c.report(sp.decl_module, sp.tok, .not_constant, "a spec value is a constant", .{});
            continue;
        };
        try out.append(c.a, .{ .spec = spec, .value = v });
    }
    return out.items;
}
