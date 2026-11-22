//! Types: the built-in ones at fixed indices, structs and arrays interned in a pool, so that
//! two types are equal exactly when their indices are.

const std = @import("std");

pub const Scalar = enum(u8) {
    bool,
    int,
    uint,
    float,
    /// 16-bit float where the target has it; `float` on GL in v0
    half,

    pub fn isFloat(s: Scalar) bool {
        return s == .float or s == .half;
    }
    pub fn isInt(s: Scalar) bool {
        return s == .int or s == .uint;
    }
    pub fn isNumeric(s: Scalar) bool {
        return s != .bool;
    }
};

/// The built-in types first, at fixed indices; structs and arrays after, from the pool.
pub const Type = enum(u32) {
    void,
    bool,
    int,
    uint,
    float,
    half,
    bvec2,
    bvec3,
    bvec4,
    ivec2,
    ivec3,
    ivec4,
    uvec2,
    uvec3,
    uvec4,
    vec2,
    vec3,
    vec4,
    hvec2,
    hvec3,
    hvec4,
    mat2,
    mat3,
    mat4,
    hmat2,
    hmat3,
    hmat4,
    sampler2D,
    /// the type of an expression that failed to check: it matches anything, so that one
    /// error does not cause others
    invalid,
    _,

    pub const first_pooled: u32 = @backingInt(Type.invalid) + 1;

    pub fn scalar(s: Scalar) Type {
        return switch (s) {
            .bool => .bool,
            .int => .int,
            .uint => .uint,
            .float => .float,
            .half => .half,
        };
    }

    /// `vecN` of `s` (`s` itself for n == 1)
    pub fn vector(s: Scalar, n: u8) Type {
        std.debug.assert(n >= 1 and n <= 4);
        if (n == 1) return scalar(s);
        const base: Type = switch (s) {
            .bool => .bvec2,
            .int => .ivec2,
            .uint => .uvec2,
            .float => .vec2,
            .half => .hvec2,
        };
        return @fromBackingInt(@intCast(@backingInt(base) + n - 2));
    }

    pub fn matrix(s: Scalar, n: u8) Type {
        std.debug.assert(n >= 2 and n <= 4 and s.isFloat());
        const base: Type = if (s == .half) .hmat2 else .mat2;
        return @fromBackingInt(@intCast(@backingInt(base) + n - 2));
    }

    pub fn isBuiltin(t: Type) bool {
        return @backingInt(t) < first_pooled;
    }

    /// The element scalar of a scalar, vector or matrix type.
    pub fn scalarOf(t: Type) ?Scalar {
        return switch (t) {
            .bool, .bvec2, .bvec3, .bvec4 => .bool,
            .int, .ivec2, .ivec3, .ivec4 => .int,
            .uint, .uvec2, .uvec3, .uvec4 => .uint,
            .float, .vec2, .vec3, .vec4, .mat2, .mat3, .mat4 => .float,
            .half, .hvec2, .hvec3, .hvec4, .hmat2, .hmat3, .hmat4 => .half,
            else => null,
        };
    }

    /// Components of a scalar (1) or vector (2-4); null for anything else.
    pub fn vectorLen(t: Type) ?u8 {
        return switch (t) {
            .bool, .int, .uint, .float, .half => 1,
            .bvec2, .ivec2, .uvec2, .vec2, .hvec2 => 2,
            .bvec3, .ivec3, .uvec3, .vec3, .hvec3 => 3,
            .bvec4, .ivec4, .uvec4, .vec4, .hvec4 => 4,
            else => null,
        };
    }

    /// Columns (= rows) of a matrix; null for anything else.
    pub fn matrixLen(t: Type) ?u8 {
        return switch (t) {
            .mat2, .hmat2 => 2,
            .mat3, .hmat3 => 3,
            .mat4, .hmat4 => 4,
            else => null,
        };
    }

    pub fn isScalar(t: Type) bool {
        return t.vectorLen() == 1;
    }

    /// Scalars, vectors and matrices: the types arithmetic applies to.
    pub fn isNumeric(t: Type) bool {
        const s = t.scalarOf() orelse return false;
        return s.isNumeric();
    }

    /// The number of scalars in a scalar, vector or matrix (for constructors).
    pub fn components(t: Type) ?u8 {
        if (t.vectorLen()) |n| return n;
        if (t.matrixLen()) |n| return n * n;
        return null;
    }

    /// The type of `m[i]` for a matrix (a column) or of one component of a vector.
    pub fn indexed(t: Type) ?Type {
        if (t.matrixLen()) |n| return vector(t.scalarOf().?, n);
        if (t.vectorLen()) |n| if (n > 1) return scalar(t.scalarOf().?);
        return null;
    }

    /// The name of a built-in type, as written.
    pub fn builtinName(t: Type) ?[]const u8 {
        if (!t.isBuiltin() or t == .invalid) return null;
        return @tagName(t);
    }
};

/// Built-in types by name.
pub const builtin_names = std.StaticStringMap(Type).initComptime(blk: {
    @setEvalBranchQuota(10_000);
    const n = @backingInt(Type.sampler2D) + 1;
    var kv: [n]struct { []const u8, Type } = undefined;
    for (0..n) |i| {
        const t: Type = @fromBackingInt(@intCast(i));
        kv[i] = .{ @tagName(t), t };
    }
    break :blk kv;
});

pub const Field = struct {
    name: []const u8,
    type: Type,
};

pub const Struct = struct {
    name: []const u8,
    fields: []const Field,
    /// where it was declared, for messages (an opaque value the checker chooses)
    decl: u32,
};

pub const Info = union(enum) {
    builtin: Type,
    @"struct": Struct,
    array: struct { elem: Type, len: u32 },
};

/// Struct and array types. Structs are distinct by declaration (two structs with the same
/// fields are different types); arrays are interned by element and length.
pub const Pool = struct {
    items: std.ArrayList(Info) = .empty,

    pub fn deinit(p: *Pool, gpa: std.mem.Allocator) void {
        p.items.deinit(gpa);
    }

    pub fn info(p: *const Pool, t: Type) Info {
        if (t.isBuiltin()) return .{ .builtin = t };
        return p.items.items[@backingInt(t) - Type.first_pooled];
    }

    /// A new struct type. `fields` must outlive the pool (the checker keeps them in its
    /// arena).
    pub fn addStruct(p: *Pool, gpa: std.mem.Allocator, s: Struct) error{OutOfMemory}!Type {
        try p.items.append(gpa, .{ .@"struct" = s });
        return @fromBackingInt(@intCast(Type.first_pooled + p.items.items.len - 1));
    }

    pub fn array(p: *Pool, gpa: std.mem.Allocator, elem: Type, len: u32) error{OutOfMemory}!Type {
        for (p.items.items, 0..) |it, i| switch (it) {
            .array => |a| if (a.elem == elem and a.len == len) return @fromBackingInt(@intCast(Type.first_pooled + i)),
            else => {},
        };
        try p.items.append(gpa, .{ .array = .{ .elem = elem, .len = len } });
        return @fromBackingInt(@intCast(Type.first_pooled + p.items.items.len - 1));
    }

    pub fn arrayOf(p: *const Pool, t: Type) ?@FieldType(Info, "array") {
        return switch (p.info(t)) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn structOf(p: *const Pool, t: Type) ?Struct {
        return switch (p.info(t)) {
            .@"struct" => |s| s,
            else => null,
        };
    }

    /// Whether values of `t` may be compared with `==`, assigned and passed: everything
    /// but samplers and aggregates holding them.
    pub fn isPlain(p: *const Pool, t: Type) bool {
        return switch (p.info(t)) {
            .builtin => |b| b != .sampler2D and b != .void,
            .array => |a| p.isPlain(a.elem),
            .@"struct" => |s| for (s.fields) |f| {
                if (!p.isPlain(f.type)) break false;
            } else true,
        };
    }

    /// `vec3`, `float[9]`, `Hit`, for messages.
    pub fn format(p: *const Pool, t: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p.info(t)) {
            .builtin => |b| try w.writeAll(if (b == .invalid) "(invalid)" else @tagName(b)),
            .@"struct" => |s| try w.writeAll(s.name),
            .array => |a| {
                try p.format(a.elem, w);
                try w.print("[{d}]", .{a.len});
            },
        }
    }

    /// The name of `t` in `buf`, for messages.
    pub fn name(p: *const Pool, t: Type, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        p.format(t, &w) catch return "(type)";
        return w.buffered();
    }
};

/// std140 alignment and size of a type in a uniform block, in bytes.
pub const Layout = struct { size: u32, alignment: u32 };

pub fn std140(p: *const Pool, t: Type) Layout {
    switch (p.info(t)) {
        .builtin => |b| {
            if (b.matrixLen()) |n| {
                // n columns, each a vec4-aligned vector
                return .{ .size = 16 * @as(u32, n), .alignment = 16 };
            }
            const n = b.vectorLen() orelse return .{ .size = 0, .alignment = 1 };
            // bool, int, uint, float and half are 4 bytes in std140 (half has no 16-bit
            // block layout in GL)
            return switch (n) {
                1 => .{ .size = 4, .alignment = 4 },
                2 => .{ .size = 8, .alignment = 8 },
                3 => .{ .size = 12, .alignment = 16 },
                else => .{ .size = 16, .alignment = 16 },
            };
        },
        .array => |a| {
            // every element rounded up to a vec4
            const e = std140(p, a.elem);
            const stride = std.mem.alignForward(u32, e.size, 16);
            return .{ .size = stride * a.len, .alignment = 16 };
        },
        .@"struct" => |s| {
            var off: u32 = 0;
            for (s.fields) |f| {
                const l = std140(p, f.type);
                off = std.mem.alignForward(u32, off, l.alignment) + l.size;
            }
            return .{ .size = std.mem.alignForward(u32, off, 16), .alignment = 16 };
        },
    }
}

test "built-in types by name, and their shapes" {
    try std.testing.expectEqual(Type.vec3, builtin_names.get("vec3").?);
    try std.testing.expectEqual(Type.hmat4, builtin_names.get("hmat4").?);
    try std.testing.expectEqual(@as(?Type, null), builtin_names.get("invalid"));
    try std.testing.expectEqual(Type.uvec3, Type.vector(.uint, 3));
    try std.testing.expectEqual(Type.float, Type.vector(.float, 1));
    try std.testing.expectEqual(Type.mat3, Type.matrix(.float, 3));
    try std.testing.expectEqual(Type.vec3, Type.mat3.indexed().?);
    try std.testing.expectEqual(@as(?u8, 16), Type.mat4.components());
    for (0..@backingInt(Type.sampler2D) + 1) |i| {
        const t: Type = @fromBackingInt(@intCast(i));
        if (t.scalarOf()) |s| {
            if (t.vectorLen()) |n| try std.testing.expectEqual(t, Type.vector(s, n));
            if (t.matrixLen()) |n| try std.testing.expectEqual(t, Type.matrix(s, n));
        }
    }
}

test "arrays are interned, structs are not" {
    const gpa = std.testing.allocator;
    var p: Pool = .{};
    defer p.deinit(gpa);
    const a = try p.array(gpa, .float, 9);
    try std.testing.expectEqual(a, try p.array(gpa, .float, 9));
    try std.testing.expect(a != try p.array(gpa, .float, 8));
    const fields = [_]Field{.{ .name = "d", .type = .float }};
    const s1 = try p.addStruct(gpa, .{ .name = "Hit", .fields = &fields, .decl = 0 });
    const s2 = try p.addStruct(gpa, .{ .name = "Hit", .fields = &fields, .decl = 1 });
    try std.testing.expect(s1 != s2);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("float[9]", p.name(a, &buf));
}

test "std140 sizes and alignments" {
    const gpa = std.testing.allocator;
    var p: Pool = .{};
    defer p.deinit(gpa);
    try std.testing.expectEqual(Layout{ .size = 12, .alignment = 16 }, std140(&p, .vec3));
    try std.testing.expectEqual(Layout{ .size = 64, .alignment = 16 }, std140(&p, .mat4));
    try std.testing.expectEqual(Layout{ .size = 48, .alignment = 16 }, std140(&p, .mat3));
    try std.testing.expectEqual(Layout{ .size = 128, .alignment = 16 }, std140(&p, try p.array(gpa, .vec4, 8)));
    // float[3]: each element padded to 16 bytes
    try std.testing.expectEqual(Layout{ .size = 48, .alignment = 16 }, std140(&p, try p.array(gpa, .float, 3)));
    const fields = [_]Field{ .{ .name = "a", .type = .float }, .{ .name = "b", .type = .vec3 } };
    const s = try p.addStruct(gpa, .{ .name = "S", .fields = &fields, .decl = 0 });
    try std.testing.expectEqual(Layout{ .size = 32, .alignment = 16 }, std140(&p, s));
}
