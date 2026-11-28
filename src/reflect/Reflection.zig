//! What a host needs to know about a program to run it: its uniform blocks (with std140
//! offsets and defaults), loose uniforms, samplers and the slots they take, params and
//! spec constants with their metadata, vertex inputs, varyings, fragment outputs, what
//! each stage uses, and the files it was made from. Everything describes the texts the
//! emitters write for the program's variant: what a stage does not reach is not listed.

const std = @import("std");
const Session = @import("../Session.zig");
const Ir = @import("../ir/Ir.zig");
const eval = @import("../ir/eval.zig");
const reach = @import("../ir/reach.zig");
const types = @import("../sema/types.zig");
const Type = types.Type;

pub const Error = error{ OutOfMemory, NotChecked };

/// Which stages a thing is used in.
pub const Stages = packed struct(u8) {
    vertex: bool = false,
    fragment: bool = false,
    _: u6 = 0,
};

pub const Arg = union(enum) {
    value: Ir.Const,
    /// a string's contents (without the quotes)
    string: []const u8,
    /// a bare word (`exp` in `curve(exp)`)
    word: []const u8,
};

pub const Meta = struct {
    key: []const u8,
    args: []const Arg,
};

pub const Member = struct {
    name: []const u8,
    type: Type,
    offset: u32,
    size: u32,
    /// the default's components, if the member has one
    default: ?[]const Ir.Const,
};

pub const Block = struct {
    name: []const u8,
    /// the module that declares it: programs that share a block share this
    module: []const u8,
    size: u32,
    members: []const Member,
    stages: Stages,
};

pub const Uniform = struct {
    name: []const u8,
    type: Type,
    stages: Stages,
    meta: []const Meta,
};

pub const Sampler = struct {
    name: []const u8,
    /// its texture unit: samplers are numbered from 0 in the order the program's texts
    /// declare them, vertex stage first
    slot: u32,
    stages: Stages,
};

pub const Param = struct {
    name: []const u8,
    type: Type,
    default: []const Ir.Const,
    meta: []const Meta,
    stages: Stages,
};

pub const Spec = struct {
    name: []const u8,
    type: Type,
    /// this variant's value
    value: Ir.Const,
    default: Ir.Const,
    meta: []const Meta,
};

pub const Attribute = struct {
    name: []const u8,
    type: Type,
    location: ?u32,
    flat: bool,
};

pub const Reflection = struct {
    name: []const u8,
    blocks: []const Block,
    /// `bulg_Params`: the loose uniforms and params of both stages, as one std140 block
    /// (null: the program has none). Its `module` is the program's name.
    params_block: ?Block,
    uniforms: []const Uniform,
    samplers: []const Sampler,
    params: []const Param,
    specs: []const Spec,
    /// vertex inputs
    inputs: []const Attribute,
    /// what the vertex stage passes to the fragment stage (the vertex's `out`s that the
    /// fragment stage reads)
    varyings: []const Attribute,
    /// fragment outputs
    outputs: []const Attribute,
    vertex_uses: Ir.Uses,
    fragment_uses: Ir.Uses,
    /// the paths of the sources the program was made from
    files: []const []const u8,
};

/// The reflection of `prog`, in `a` (an arena: it is freed as one).
pub fn reflect(s: *const Session, prog: *const Ir.Program, a: std.mem.Allocator) Error!Reflection {
    if (!s.programChecked(prog)) return error.NotChecked;
    const vr = try reach.stage(s, prog, prog.vertex.?, a);
    const fr = try reach.stage(s, prog, prog.fragment.?, a);
    var b: Builder = .{ .s = s, .a = a, .prog = prog };
    try b.add(vr, .{ .vertex = true });
    try b.add(fr, .{ .fragment = true });

    var files: std.ArrayList([]const u8) = .empty;
    for ([_]Ir.StageInfo{ prog.vertex.?, prog.fragment.? }) |st| for (st.modules) |mi| {
        const path = s.source(s.modules[mi].src).path;
        for (files.items) |f| {
            if (std.mem.eql(u8, f, path)) break;
        } else try files.append(a, path);
    };
    const decl_path = s.source(s.modules[prog.module].src).path;
    for (files.items) |f| {
        if (std.mem.eql(u8, f, decl_path)) break;
    } else try files.append(a, decl_path);

    // the varyings: the vertex stage's outputs the fragment stage reads
    var varyings: std.ArrayList(Attribute) = .empty;
    for (b.frag_ins.items) |fin| {
        for (b.vert_outs.items) |vout| if (std.mem.eql(u8, vout.name, fin.name)) {
            try varyings.append(a, fin);
            break;
        };
    }
    // bulg_Params, as the emitters declare it
    const loose = try reach.looseUniforms(s, prog, a);
    var params_block: ?Block = null;
    if (loose.len > 0) {
        const l = try reach.std140Offsets(s, loose, a);
        const members = try a.alloc(Member, loose.len);
        var stages: Stages = .{};
        for (loose, l.offsets, members) |r, off, *mem| {
            const g = s.modules[r.module].globals[r.index];
            mem.* = .{
                .name = g.name,
                .type = g.type,
                .offset = off,
                .size = types.std140(&s.pool, g.type).size,
                .default = if (g.init != .none) try b.value(r.module, g.init) else null,
            };
            for (b.uniforms.items) |u| if (std.mem.eql(u8, u.name, g.name)) {
                stages = merge(stages, u.stages);
            };
            for (b.params.items) |p| if (std.mem.eql(u8, p.name, g.name)) {
                stages = merge(stages, p.stages);
            };
        }
        params_block = .{ .name = "bulg_Params", .module = prog.name, .size = l.size, .members = members, .stages = stages };
    }
    return .{
        .name = prog.name,
        .blocks = b.blocks.items,
        .params_block = params_block,
        .uniforms = b.uniforms.items,
        .samplers = b.samplers.items,
        .params = b.params.items,
        .specs = try specs(s, prog, a),
        .inputs = b.vert_ins.items,
        .varyings = varyings.items,
        .outputs = b.frag_outs.items,
        .vertex_uses = prog.vertex.?.uses,
        .fragment_uses = prog.fragment.?.uses,
        .files = files.items,
    };
}

const Builder = struct {
    s: *const Session,
    a: std.mem.Allocator,
    prog: *const Ir.Program,
    blocks: std.ArrayList(Block) = .empty,
    block_refs: std.ArrayList(struct { u32, u32 }) = .empty,
    uniforms: std.ArrayList(Uniform) = .empty,
    samplers: std.ArrayList(Sampler) = .empty,
    params: std.ArrayList(Param) = .empty,
    vert_ins: std.ArrayList(Attribute) = .empty,
    vert_outs: std.ArrayList(Attribute) = .empty,
    frag_ins: std.ArrayList(Attribute) = .empty,
    frag_outs: std.ArrayList(Attribute) = .empty,

    fn add(b: *Builder, r: reach.Reach, stage: Stages) Error!void {
        // in the order the emitted text declares them (samplers take slots in it)
        const order = try sortedDecls(b.s, r, b.a);
        for (order) |d| switch (d) {
            .block => |x| try b.block(x.module, x.index, stage),
            .global => |ref| try b.global(ref, stage),
            else => {},
        };
    }

    fn block(b: *Builder, mi: u32, k: u32, stage: Stages) Error!void {
        for (b.block_refs.items, b.blocks.items) |br, *bl| if (br[0] == mi and br[1] == k) {
            bl.stages = merge(bl.stages, stage);
            return;
        };
        const m = &b.s.modules[mi];
        const ib = m.blocks[k];
        const members = try b.a.alloc(Member, ib.members.len);
        for (ib.members, ib.offsets, members) |g, off, *mem| {
            const gl = m.globals[g];
            mem.* = .{
                .name = gl.name,
                .type = gl.type,
                .offset = off,
                .size = types.std140(&b.s.pool, gl.type).size,
                .default = if (gl.init != .none) try b.value(mi, gl.init) else null,
            };
        }
        try b.block_refs.append(b.a, .{ mi, k });
        try b.blocks.append(b.a, .{ .name = ib.name, .module = m.name, .size = ib.size, .members = members, .stages = stage });
    }

    fn global(b: *Builder, ref: Ir.Ref, stage: Stages) Error!void {
        const g = b.s.modules[ref.module].globals[ref.index];
        const attr: Attribute = .{ .name = g.name, .type = g.type, .location = g.location, .flat = g.flat };
        switch (g.kind) {
            .uniform => {
                if (g.type == .sampler2D) {
                    for (b.samplers.items) |*sm| if (std.mem.eql(u8, sm.name, g.name)) {
                        sm.stages = merge(sm.stages, stage);
                        return;
                    };
                    try b.samplers.append(b.a, .{ .name = g.name, .slot = @intCast(b.samplers.items.len), .stages = stage });
                    return;
                }
                for (b.uniforms.items) |*u| if (std.mem.eql(u8, u.name, g.name)) {
                    u.stages = merge(u.stages, stage);
                    return;
                };
                try b.uniforms.append(b.a, .{ .name = g.name, .type = g.type, .stages = stage, .meta = try b.metas(ref.module, g.meta) });
            },
            .param => {
                for (b.params.items) |*p| if (std.mem.eql(u8, p.name, g.name)) {
                    p.stages = merge(p.stages, stage);
                    return;
                };
                try b.params.append(b.a, .{ .name = g.name, .type = g.type, .default = (try b.value(ref.module, g.init)) orelse &.{}, .meta = try b.metas(ref.module, g.meta), .stages = stage });
            },
            .in => try (if (stage.vertex) &b.vert_ins else &b.frag_ins).append(b.a, attr),
            .out => try (if (stage.vertex) &b.vert_outs else &b.frag_outs).append(b.a, attr),
            .@"const", .mutable, .spec => {},
        }
    }

    fn value(b: *Builder, mi: u32, e: Ir.ExprId) Error!?[]const Ir.Const {
        var buf: [16]Ir.Const = undefined;
        const v = eval.components(b.s.modules, mi, e, .{ .values = b.prog.specs }, &buf) orelse return null;
        return try b.a.dupe(Ir.Const, v);
    }

    fn metas(b: *Builder, mi: u32, ms: []const Ir.Meta) Error![]const Meta {
        return metaList(b.s, mi, ms, b.prog.specs, b.a);
    }
};

fn merge(a: Stages, b: Stages) Stages {
    return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
}

fn metaList(s: *const Session, mi: u32, ms: []const Ir.Meta, spec_values: []const Ir.SpecValue, a: std.mem.Allocator) Error![]const Meta {
    const out = try a.alloc(Meta, ms.len);
    const m = &s.modules[mi];
    for (ms, out) |me, *o| {
        const ids = m.list(me.args);
        const args = try a.alloc(Arg, ids.len);
        for (ids, args) |id, *arg| {
            const ex = m.expr(@fromBackingInt(@intCast(id)));
            if (ex.data == .string) {
                const text = s.asts.items[mi].tokenText(ex.tok);
                arg.* = if (text.len > 0 and text[0] == '"') .{ .string = text[1 .. text.len - 1] } else .{ .word = text };
            } else {
                arg.* = if (eval.constant(s.modules, mi, @fromBackingInt(@intCast(id)), .{ .values = spec_values })) |v| .{ .value = v } else .{ .word = "?" };
            }
        }
        o.* = .{ .key = me.key, .args = args };
    }
    return out;
}

fn specs(s: *const Session, prog: *const Ir.Program, a: std.mem.Allocator) Error![]const Spec {
    var out: std.ArrayList(Spec) = .empty;
    const sv: eval.Specs = .{ .values = prog.specs };
    for ([_]Ir.StageInfo{ prog.vertex.?, prog.fragment.? }) |st| for (st.modules) |mi| {
        for (s.modules[mi].globals, 0..) |g, k| {
            if (g.kind != .spec) continue;
            for (out.items) |o| {
                if (std.mem.eql(u8, o.name, g.name)) break;
            } else {
                const def = eval.constant(s.modules, mi, g.init, .{ .values = &.{} }) orelse continue;
                const ref: Ir.Ref = .{ .module = mi, .index = @intCast(k) };
                try out.append(a, .{
                    .name = g.name,
                    .type = g.type,
                    .value = sv.get(ref) orelse def,
                    .default = def,
                    .meta = try metaList(s, mi, g.meta, prog.specs, a),
                });
            }
        }
    };
    return out.items;
}

/// The declarations of a stage in the order its text declares them.
fn sortedDecls(s: *const Session, r: reach.Reach, a: std.mem.Allocator) Error![]const reach.Decl {
    return reach.ordered(s, r, a);
}
