//! The built-in functions and variables. Functions are written once with generic types
//! (`genType`), the way the GLSL specification lists them, and expanded at compile time
//! into concrete overloads: BULG has no implicit conversions, so resolving a call is
//! finding the overload whose parameters are exactly the argument types.

const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;
const Scalar = types.Scalar;

pub const Stage = enum(u2) { any, vertex, fragment };

pub const Kind = enum(u8) {
    /// a function of its arguments only
    pure,
    /// `dFdx`, `dFdy`, `fwidth`: fragment only, and they need neighbouring invocations
    derivative,
    /// reads a texture
    texture,
};

pub const Function = struct {
    name: []const u8,
    ret: Type,
    params: []const Type,
    /// bit i: parameter i is `out`
    out_mask: u8 = 0,
    kind: Kind = .pure,
    /// index of the generic signature this came from (overloads of one row share it)
    row: u16,
};

// ---------------------------------------------------------------- the generic table

/// A parameter or return type in a generic signature.
const P = union(enum) {
    /// a vector of the family's scalar, of the row's length (`genType`)
    g,
    /// the family's scalar
    s,
    /// a square matrix of the family's scalar, of the row's length
    m,
    /// a vector of this scalar, of the row's length (`genBType`, `genIType`, ...)
    vec: Scalar,
    t: Type,
};

const floats: []const Scalar = &.{ .float, .half };
const ints: []const Scalar = &.{.int};
const uints: []const Scalar = &.{.uint};
const bools: []const Scalar = &.{.bool};
const numbers: []const Scalar = &.{ .float, .half, .int, .uint };

const all_lens: []const u8 = &.{ 1, 2, 3, 4 };
const vec_lens: []const u8 = &.{ 2, 3, 4 };
const mat_lens: []const u8 = &.{ 2, 3, 4 };

const Row = struct {
    name: []const u8,
    ret: P,
    params: []const P,
    fam: []const Scalar = floats,
    lens: []const u8 = all_lens,
    out_mask: u8 = 0,
    kind: Kind = .pure,
};

fn r(name: []const u8, ret: P, params: []const P) Row {
    return .{ .name = name, .ret = ret, .params = params };
}

fn with(row: Row, comptime field: []const u8, value: anytype) Row {
    var x = row;
    @field(x, field) = value;
    return x;
}

const g: P = .g;
const s: P = .s;
const m: P = .m;
const bv: P = .{ .vec = .bool };
const iv: P = .{ .vec = .int };
const uv: P = .{ .vec = .uint };
const fv: P = .{ .vec = .float };
fn t(x: Type) P {
    return .{ .t = x };
}

/// GLSL ES 3.00, chapter 8, less what v0 leaves out (non-square matrices, samplers other
/// than `sampler2D`, `textureGrad`, `textureOffset`, `textureProj`).
const rows = [_]Row{
    // 8.1 angles and trigonometry
    r("radians", g, &.{g}),
    r("degrees", g, &.{g}),
    r("sin", g, &.{g}),
    r("cos", g, &.{g}),
    r("tan", g, &.{g}),
    r("asin", g, &.{g}),
    r("acos", g, &.{g}),
    r("atan", g, &.{ g, g }),
    r("atan", g, &.{g}),
    r("sinh", g, &.{g}),
    r("cosh", g, &.{g}),
    r("tanh", g, &.{g}),
    r("asinh", g, &.{g}),
    r("acosh", g, &.{g}),
    r("atanh", g, &.{g}),
    // 8.2 exponential
    r("pow", g, &.{ g, g }),
    r("exp", g, &.{g}),
    r("log", g, &.{g}),
    r("exp2", g, &.{g}),
    r("log2", g, &.{g}),
    r("sqrt", g, &.{g}),
    r("inversesqrt", g, &.{g}),
    // 8.3 common
    with(r("abs", g, &.{g}), "fam", &[_]Scalar{ .float, .half, .int }),
    with(r("sign", g, &.{g}), "fam", &[_]Scalar{ .float, .half, .int }),
    r("floor", g, &.{g}),
    r("trunc", g, &.{g}),
    r("round", g, &.{g}),
    r("roundEven", g, &.{g}),
    r("ceil", g, &.{g}),
    r("fract", g, &.{g}),
    r("mod", g, &.{ g, s }),
    r("mod", g, &.{ g, g }),
    with(r("modf", g, &.{ g, g }), "out_mask", 0b10),
    with(r("min", g, &.{ g, g }), "fam", numbers),
    with(r("min", g, &.{ g, s }), "fam", numbers),
    with(r("max", g, &.{ g, g }), "fam", numbers),
    with(r("max", g, &.{ g, s }), "fam", numbers),
    with(r("clamp", g, &.{ g, g, g }), "fam", numbers),
    with(r("clamp", g, &.{ g, s, s }), "fam", numbers),
    r("mix", g, &.{ g, g, g }),
    r("mix", g, &.{ g, g, s }),
    r("mix", g, &.{ g, g, bv }),
    r("step", g, &.{ g, g }),
    r("step", g, &.{ s, g }),
    r("smoothstep", g, &.{ g, g, g }),
    r("smoothstep", g, &.{ s, s, g }),
    r("isnan", bv, &.{g}),
    r("isinf", bv, &.{g}),
    with(r("floatBitsToInt", iv, &.{g}), "fam", &[_]Scalar{.float}),
    with(r("floatBitsToUint", uv, &.{g}), "fam", &[_]Scalar{.float}),
    with(r("intBitsToFloat", fv, &.{iv}), "fam", &[_]Scalar{.float}),
    with(r("uintBitsToFloat", fv, &.{uv}), "fam", &[_]Scalar{.float}),
    // 8.4 packing
    with(r("packSnorm2x16", t(.uint), &.{t(.vec2)}), "lens", &[_]u8{1}),
    with(r("unpackSnorm2x16", t(.vec2), &.{t(.uint)}), "lens", &[_]u8{1}),
    with(r("packUnorm2x16", t(.uint), &.{t(.vec2)}), "lens", &[_]u8{1}),
    with(r("unpackUnorm2x16", t(.vec2), &.{t(.uint)}), "lens", &[_]u8{1}),
    with(r("packHalf2x16", t(.uint), &.{t(.vec2)}), "lens", &[_]u8{1}),
    with(r("unpackHalf2x16", t(.vec2), &.{t(.uint)}), "lens", &[_]u8{1}),
    // 8.5 geometry
    r("length", s, &.{g}),
    r("distance", s, &.{ g, g }),
    r("dot", s, &.{ g, g }),
    with(r("cross", g, &.{ g, g }), "lens", &[_]u8{3}),
    r("normalize", g, &.{g}),
    r("faceforward", g, &.{ g, g, g }),
    r("reflect", g, &.{ g, g }),
    r("refract", g, &.{ g, g, s }),
    // 8.6 matrices (square only in v0)
    with(r("matrixCompMult", m, &.{ m, m }), "lens", mat_lens),
    with(r("outerProduct", m, &.{ g, g }), "lens", mat_lens),
    with(r("transpose", m, &.{m}), "lens", mat_lens),
    with(r("determinant", s, &.{m}), "lens", mat_lens),
    with(r("inverse", m, &.{m}), "lens", mat_lens),
    // 8.7 vector relations
    with(with(r("lessThan", bv, &.{ g, g }), "fam", numbers), "lens", vec_lens),
    with(with(r("lessThanEqual", bv, &.{ g, g }), "fam", numbers), "lens", vec_lens),
    with(with(r("greaterThan", bv, &.{ g, g }), "fam", numbers), "lens", vec_lens),
    with(with(r("greaterThanEqual", bv, &.{ g, g }), "fam", numbers), "lens", vec_lens),
    with(with(r("equal", bv, &.{ g, g }), "fam", &[_]Scalar{ .float, .half, .int, .uint, .bool }), "lens", vec_lens),
    with(with(r("notEqual", bv, &.{ g, g }), "fam", &[_]Scalar{ .float, .half, .int, .uint, .bool }), "lens", vec_lens),
    with(with(r("any", t(.bool), &.{g}), "fam", bools), "lens", vec_lens),
    with(with(r("all", t(.bool), &.{g}), "fam", bools), "lens", vec_lens),
    with(with(r("not", g, &.{g}), "fam", bools), "lens", vec_lens),
    // 8.8 textures (sampler2D only)
    with(with(r("textureSize", t(.ivec2), &.{ t(.sampler2D), t(.int) }), "lens", &[_]u8{1}), "kind", .texture),
    with(with(r("texture", t(.vec4), &.{ t(.sampler2D), t(.vec2) }), "lens", &[_]u8{1}), "kind", .texture),
    with(with(r("texture", t(.vec4), &.{ t(.sampler2D), t(.vec2), t(.float) }), "lens", &[_]u8{1}), "kind", .texture),
    with(with(r("textureLod", t(.vec4), &.{ t(.sampler2D), t(.vec2), t(.float) }), "lens", &[_]u8{1}), "kind", .texture),
    with(with(r("texelFetch", t(.vec4), &.{ t(.sampler2D), t(.ivec2), t(.int) }), "lens", &[_]u8{1}), "kind", .texture),
    // 8.9 fragment processing
    with(r("dFdx", g, &.{g}), "kind", .derivative),
    with(r("dFdy", g, &.{g}), "kind", .derivative),
    with(r("fwidth", g, &.{g}), "kind", .derivative),
};

fn resolve(p: P, fam: Scalar, n: u8) Type {
    return switch (p) {
        .g => Type.vector(fam, n),
        .s => Type.scalar(fam),
        .m => Type.matrix(fam, n),
        .vec => |sc| Type.vector(sc, n),
        .t => |x| x,
    };
}

fn countOverloads() usize {
    var c: usize = 0;
    for (rows) |row| c += row.fam.len * row.lens.len;
    return c;
}

/// Every overload, grouped by name in the order of `rows`.
pub const functions: [countOverloads()]Function = blk: {
    @setEvalBranchQuota(200_000);
    var out: [countOverloads()]Function = undefined;
    var i = 0;
    for (rows, 0..) |row, ri| {
        for (row.fam) |fam| for (row.lens) |n| {
            var params: [row.params.len]Type = undefined;
            for (row.params, 0..) |p, k| params[k] = resolve(p, fam, n);
            const final = params;
            out[i] = .{ .name = row.name, .ret = resolve(row.ret, fam, n), .params = &final, .out_mask = row.out_mask, .kind = row.kind, .row = ri };
            i += 1;
        };
    }
    break :blk out;
};

const Range = struct { start: u16, len: u16 };

/// The overloads of each name, as a range of `functions`.
const by_name = std.StaticStringMap(Range).initComptime(blk: {
    @setEvalBranchQuota(200_000);
    var kv: []const struct { []const u8, Range } = &.{};
    var i = 0;
    while (i < functions.len) {
        const name = functions[i].name;
        var j = i;
        while (j < functions.len and std.mem.eql(u8, functions[j].name, name)) j += 1;
        // the rows of one name are next to each other
        for (kv) |e| if (std.mem.eql(u8, e[0], name)) @compileError("rows of `" ++ name ++ "` are not together");
        kv = kv ++ .{.{ name, Range{ .start = i, .len = j - i } }};
        i = j;
    }
    break :blk kv;
});

/// The overloads named `name`, empty if it is no built-in function.
pub fn overloads(name: []const u8) []const Function {
    const rg = by_name.get(name) orelse return &.{};
    return functions[rg.start..][0..rg.len];
}

/// The overload whose parameters are exactly `args`.
pub fn find(name: []const u8, args: []const Type) ?*const Function {
    for (overloads(name)) |*f| {
        if (f.params.len != args.len) continue;
        for (f.params, args) |p, a| {
            if (p != a) break;
        } else return f;
    }
    return null;
}

// ---------------------------------------------------------------- variables

pub const Variable = struct {
    name: []const u8,
    type: Type,
    stage: Stage,
    writable: bool,
};

pub const variables = [_]Variable{
    .{ .name = "gl_FragCoord", .type = .vec4, .stage = .fragment, .writable = false },
    .{ .name = "gl_FrontFacing", .type = .bool, .stage = .fragment, .writable = false },
    .{ .name = "gl_PointCoord", .type = .vec2, .stage = .fragment, .writable = false },
    .{ .name = "gl_Position", .type = .vec4, .stage = .vertex, .writable = true },
    .{ .name = "gl_PointSize", .type = .float, .stage = .vertex, .writable = true },
    .{ .name = "gl_VertexID", .type = .int, .stage = .vertex, .writable = false },
    .{ .name = "gl_InstanceID", .type = .int, .stage = .vertex, .writable = false },
};

pub fn variable(name: []const u8) ?u8 {
    for (variables, 0..) |v, i| if (std.mem.eql(u8, v.name, name)) return @intCast(i);
    return null;
}

test "overloads are found by exact argument types" {
    try std.testing.expectEqual(Type.vec3, find("mix", &.{ .vec3, .vec3, .float }).?.ret);
    try std.testing.expectEqual(Type.vec3, find("mix", &.{ .vec3, .vec3, .vec3 }).?.ret);
    try std.testing.expectEqual(Type.float, find("dot", &.{ .vec4, .vec4 }).?.ret);
    try std.testing.expectEqual(Type.ivec3, find("max", &.{ .ivec3, .int }).?.ret);
    try std.testing.expectEqual(Type.bvec2, find("lessThan", &.{ .uvec2, .uvec2 }).?.ret);
    try std.testing.expectEqual(Type.vec4, find("texelFetch", &.{ .sampler2D, .ivec2, .int }).?.ret);
    try std.testing.expectEqual(Type.mat3, find("transpose", &.{.mat3}).?.ret);
    try std.testing.expectEqual(Type.uvec2, find("floatBitsToUint", &.{.vec2}).?.ret);
    try std.testing.expectEqual(@as(u8, 0b10), find("modf", &.{ .vec2, .vec2 }).?.out_mask);
    // no conversions
    try std.testing.expectEqual(@as(?*const Function, null), find("sin", &.{.int}));
    try std.testing.expectEqual(@as(?*const Function, null), find("mix", &.{ .vec3, .vec3, .int }));
    try std.testing.expectEqual(@as(?*const Function, null), find("cross", &.{ .vec2, .vec2 }));
    try std.testing.expectEqual(@as(usize, 0), overloads("map").len);
}
