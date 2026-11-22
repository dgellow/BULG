//! Values of constant scalar expressions in the IR, with a variant's spec values: what the
//! specialisation pass folds `if (FADE)` with. (The interpreter, later, evaluates all of
//! the IR; this is the scalar part the passes need now.)

const std = @import("std");
const Ir = @import("Ir.zig");
const types = @import("../sema/types.zig");

pub const Specs = struct {
    values: []const Ir.SpecValue,

    pub fn get(s: Specs, r: Ir.Ref) ?Ir.Const {
        for (s.values) |v| if (v.spec.module == r.module and v.spec.index == r.index) return v.value;
        return null;
    }
};

/// The value of `e` in module `mi`, or null when it is not a constant Glint can compute.
/// A spec constant has the variant's value (or its default).
pub fn constant(modules: []const Ir.Module, mi: u32, e: Ir.ExprId, specs: Specs) ?Ir.Const {
    if (e == .none) return null;
    const m = &modules[mi];
    const ex = m.expr(e);
    if (ex.type == .invalid) return null;
    return switch (ex.data) {
        .literal => |v| v,
        .global => |r| blk: {
            const g = modules[r.module].globals[r.index];
            switch (g.kind) {
                .spec => break :blk specs.get(r) orelse constant(modules, r.module, g.init, specs),
                .@"const" => break :blk constant(modules, r.module, g.init, specs),
                else => break :blk null,
            }
        },
        .alias => |r| constant(modules, r.module, modules[r.module].aliases[r.index].value, specs),
        .array_length => |d| .{ .int = @intCast(d.len) },
        .unary => |d| blk: {
            const v = constant(modules, mi, d.operand, specs) orelse break :blk null;
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
            const l = constant(modules, mi, d.lhs, specs) orelse break :blk null;
            const r = constant(modules, mi, d.rhs, specs) orelse break :blk null;
            break :blk binary(d.op, l, r);
        },
        .ternary => |d| blk: {
            const c = constant(modules, mi, d.cond, specs) orelse break :blk null;
            if (c != .bool) break :blk null;
            break :blk constant(modules, mi, if (c.bool) d.then else d.@"else", specs);
        },
        .construct => |l| blk: {
            if (!ex.type.isScalar() or l.len != 1) break :blk null;
            const v = constant(modules, mi, @fromBackingInt(@intCast(m.list(l)[0])), specs) orelse break :blk null;
            break :blk convert(v, ex.type.scalarOf().?);
        },
        else => null,
    };
}

pub fn convert(v: Ir.Const, to: types.Scalar) ?Ir.Const {
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

/// `l op r` for two scalars, GLSL's way: integers wrap, a shift past the width or a
/// division by zero is not folded.
pub fn binary(op: Ir.BinaryOp, l: Ir.Const, r: Ir.Const) ?Ir.Const {
    switch (l) {
        .int => |a| {
            if (r != .int) {
                if ((op == .shl or op == .shr) and r == .uint) return binary(op, l, .{ .int = @bitCast(r.uint) });
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
                if ((op == .shl or op == .shr) and r == .int) return binary(op, l, .{ .uint = @bitCast(r.int) });
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

test "integer folding wraps and refuses what GLSL leaves undefined" {
    try std.testing.expect(binary(.add, .{ .int = std.math.maxInt(i32) }, .{ .int = 1 }).?.eql(.{ .int = std.math.minInt(i32) }));
    try std.testing.expectEqual(@as(?Ir.Const, null), binary(.div, .{ .int = 1 }, .{ .int = 0 }));
    try std.testing.expectEqual(@as(?Ir.Const, null), binary(.shl, .{ .uint = 1 }, .{ .uint = 32 }));
    try std.testing.expect(binary(.shr, .{ .uint = 0x80000000 }, .{ .int = 31 }).?.eql(.{ .uint = 1 }));
    try std.testing.expect(convert(.{ .uint = 0xffffffff }, .int).?.eql(.{ .int = -1 }));
}

/// The components of a constant scalar, vector or matrix expression (columns of a matrix
/// one after the other), or null when it is not one Glint can compute. `out` holds up to
/// 16; the result is a slice of it.
pub fn components(modules: []const Ir.Module, mi: u32, e: Ir.ExprId, specs: Specs, out: *[16]Ir.Const) ?[]Ir.Const {
    if (e == .none) return null;
    const m = &modules[mi];
    const ex = m.expr(e);
    const t = ex.type;
    const n = t.components() orelse return null;
    if (t.isScalar()) {
        out[0] = constant(modules, mi, e, specs) orelse return null;
        return out[0..1];
    }
    switch (ex.data) {
        .global => |r| {
            const g = modules[r.module].globals[r.index];
            if (g.kind != .@"const") return null;
            return components(modules, r.module, g.init, specs, out);
        },
        .alias => |r| return components(modules, r.module, modules[r.module].aliases[r.index].value, specs, out),
        .construct => |l| {
            const s = t.scalarOf().?;
            const args = m.list(l);
            // one scalar: every component, or a matrix's diagonal
            if (args.len == 1 and m.expr(@fromBackingInt(@intCast(args[0]))).type.isScalar()) {
                const v = convert(constant(modules, mi, @fromBackingInt(@intCast(args[0])), specs) orelse return null, s) orelse return null;
                if (t.matrixLen()) |k| {
                    const zero = convert(.{ .int = 0 }, s).?;
                    for (0..k) |c| for (0..k) |row| {
                        out[c * k + row] = if (c == row) v else zero;
                    };
                } else for (0..n) |i| {
                    out[i] = v;
                }
                return out[0..n];
            }
            if (t.matrixLen() != null and args.len == 1) return null; // a resize: not now
            var have: usize = 0;
            for (args) |a| {
                var sub: [16]Ir.Const = undefined;
                const part = components(modules, mi, @fromBackingInt(@intCast(a)), specs, &sub) orelse return null;
                for (part) |v| {
                    if (have == n) break;
                    out[have] = convert(v, s) orelse return null;
                    have += 1;
                }
            }
            return if (have == n) out[0..n] else null;
        },
        .unary => |d| {
            if (d.op != .neg and d.op != .plus) return null;
            const part = components(modules, mi, d.operand, specs, out) orelse return null;
            if (d.op == .neg) for (part) |*v| {
                v.* = switch (v.*) {
                    .int => |i| .{ .int = -%i },
                    .uint => |u| .{ .uint = 0 -% u },
                    .float => |f| .{ .float = -f },
                    .bool => return null,
                };
            };
            return part;
        },
        else => return null,
    }
}
